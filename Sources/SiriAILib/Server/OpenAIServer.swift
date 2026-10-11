import Foundation
import os

/// A minimal OpenAI-compatible HTTP server, spoken over localhost sockets.
///
/// Skip-heavier-frameworks note: SwiftNIO/Hummingbird would be overkill for a
/// loopback-only endpoint with modest payload sizes; raw sockets keep the
/// dependency tree empty so the binary stays cacheable and brew-shippable.
/// Endpoints:
///   GET  /health                → {"status":"ok"}
///   GET  /v1/models             → OpenAI models list shape
///   POST /v1/chat/completions   → OpenAI chat completions, streaming + buffered
public struct OpenAIServer: Sendable {
    public let port: Int
    public let engine: LLMEngine
    /// When false, `engine` is used for every request (tests / explicit
    /// engine injection). When true (the `serve` command), requests are routed
    /// by the model name in each completion.
    public var routingEnabled: Bool = true

    public init(port: Int, engine: LLMEngine, routingEnabled: Bool = true) {
        self.port = port
        self.engine = engine
        self.routingEnabled = routingEnabled
    }

    public func run() async throws {
        let listenerFD = try Self.makeListener(port: port)
        TerminalOutput.line("Serving Apple Intelligence on http://127.0.0.1:\(port) (OpenAI-compatible). Ctrl-C to stop.")
        await acceptLoop(listenerFD: listenerFD, maxConnections: nil)
    }

    /// The accept loop, bounded so tests can exercise it and exit.
    /// `maxConnections == nil` means unbounded (the serve command's behavior).
    func acceptLoop(listenerFD: Int32, maxConnections: Int?) async {
        var served = 0
        var consecutiveAcceptFailures = 0
        while maxConnections == nil || served < maxConnections! {
            let clientFD = accept(listenerFD, nil, nil)
            guard clientFD >= 0 else {
                // A transient failure (EINTR, momentary EMFILE) should not take
                // the loop down, but a persistently broken listener (fd closed,
                // EBADF) must not spin the CPU in silence either. Log every
                // failure; abort after repeated ones — run() surfaces the exit.
                consecutiveAcceptFailures += 1
                try? await Task.sleep(nanoseconds: 10_000_000)   // 10ms backoff
                let errnoDescription = String(cString: strerror(errno))
                TerminalOutput.error(
                    "accept() failed (\(consecutiveAcceptFailures) consecutive): \(errnoDescription)")
                if consecutiveAcceptFailures >= 25 {
                    TerminalOutput.error("Giving up after repeated accept() failures; listener is likely broken.")
                    break
                }
                continue
            }
            consecutiveAcceptFailures = 0
            served += 1
            // Bound how long a connected client may stall us: without this, a
            // client that connects and sends nothing (or half a header) pins a
            // task + socket forever. SO_RCVTIMEO makes recv() fail with
            // EAGAIN/EWOULDBLOCK after the deadline; readRequest then breaks on
            // n <= 0 and handleConnection returns — the graceful-close path
            // cleans up. Applies per-recv, so a slow-but-flowing request is
            // still fine (each chunk resets the window).
            Self.setReceiveTimeout(seconds: 30, on: clientFD)
            // One task per connection; server is loopback-only so this is fine.
            Task.detached {
                do {
                    try await Self.handleConnection(fd: clientFD, server: self)
                } catch {
                    TerminalOutput.error("Connection error: \(error)")
                }
                // Graceful close: half-close our write side so the client can
                // finish reading, then drain until the peer disconnects.
                shutdown(clientFD, SHUT_WR)
                var drain = [UInt8](repeating: 0, count: 1024)
                while recv(clientFD, &drain, drain.count, 0) > 0 {}
                close(clientFD)
            }
        }
    }

    // MARK: - Listener setup

    /// Test hook: create a listening socket on `port` (0 = ephemeral).
    func listenerForTesting() throws -> Int32 {
        try Self.makeListener(port: port)
    }

    private static func makeListener(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        // socket() failure yields -1; using it downstream would produce a
        // misleading "Could not bind port" instead of the real cause (EMFILE,
        // ENOBUFS, ...).
        guard fd >= 0 else {
            throw EngineError.backend("Could not create listener socket: \(String(cString: strerror(errno)))")
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw EngineError.backend("Could not bind port \(port) — is another server listening? (\(String(cString: strerror(errno))))")
        }
        guard listen(fd, 16) == 0 else {
            throw EngineError.backend("Could not listen on port \(port) (\(String(cString: strerror(errno))).")
        }
        return fd
    }

    /// Marks fd's receive timeout via SO_RCVTIMEO (seconds). Best-effort: a
    /// failed setsockopt just means the old "client may stall a connection
    /// forever" behavior persists; logged so it isn't invisible.
    internal static func setReceiveTimeout(seconds: Int, on fd: Int32) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        let result = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        if result != 0 {
            TerminalOutput.error("setsockopt SO_RCVTIMEO failed: \(String(cString: strerror(errno)))")
        }
    }

    // MARK: - Connection handling

    static func handleConnection(fd: Int32, server: OpenAIServer) async throws {
        let raw = try readRequest(fd: fd)
        guard let request = raw else { return }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            try await writeResponse(
                fd: fd,
                status: "200 OK",
                body: #"{"status":"ok"}"#,
                contentType: "application/json"
            )
        case ("GET", "/v1/models"):
            try await writeResponse(fd: fd, status: "200 OK", body: Self.modelsListJSON(), contentType: "application/json")
        case ("POST", "/v1/chat/completions"):
            do {
                try await Self.handleChatCompletions(fd: fd, request: request, server: server)
            } catch let error as EngineError {
                // Known backend failures get their mapped status + typed envelope.
                try? await writeResponse(
                    fd: fd,
                    status: Self.httpStatus(for: error),
                    body: Self.errorEnvelope(
                        message: error.errorDescription ?? String(describing: error),
                        type: Self.errorType(for: error)
                    ),
                    contentType: "application/json"
                )
            } catch {
                // Unknown failures keep the generic 500, without leaking raw
                // Swift error dumps into the client response.
                try? await writeResponse(
                    fd: fd,
                    status: "500 Internal Server Error",
                    body: Self.errorEnvelope(message: "Internal backend error.", type: "internal_error"),
                    contentType: "application/json"
                )
            }
        default:
            try await writeResponse(
                fd: fd,
                status: "404 Not Found",
                body: #"{"error":{"message":"not found"}}"#,
                contentType: "application/json"
            )
        }
    }

    private static func handleChatCompletions(fd: Int32, request: HTTPRequest, server: OpenAIServer) async throws {
        guard let completion = try? JSONDecoder().decode(ChatCompletionRequest.self, from: Data(request.body.utf8)) else {
            try await writeResponse(
                fd: fd,
                status: "400 Bad Request",
                body: #"{"error":{"message":"invalid request body"}}"#,
                contentType: "application/json"
            )
            return
        }

        let systemMessage = completion.messages.first { $0.role == "system" }?.content
        let conversation = completion.messages.filter { $0.role != "system" }
        let prompt = conversation.last?.content ?? ""
        let history = conversation.dropLast().suffix(6)   // tiny window: model context limit

        // Route on the requested model: "siri-ai" talks to the real Siri AI
        // app via Accessibility; the default (and "apple-intelligence") selects
        // the FoundationModels engine. An explicitly injected engine (tests)
        // takes precedence.
        let selected = server.routingEnabled ? Self.engine(for: completion.model) : server.engine

        let contextBlock = history
            .map { "\($0.role == "user" ? "User" : "Assistant"): \($0.content)" }
            .joined(separator: "\n")
        let fullPrompt = contextBlock.isEmpty ? prompt : "\(contextBlock)\nUser: \(prompt)"

        // System 1 routing (non-streaming, apple backend only per plan): a
        // fast typed verdict decides whether to attach a file-tool layer,
        // giving HTTP clients parity with `ask --tools`. Skipped for injected
        // test engines (StubEngine lacks tool wiring); streaming requests and
        // the siri-ai backend keep the plain path (per plan: no decision
        // through Siri AX, and no added latency in the streaming hot path).
        //
        // A user decision spec (see DecisionSpec) FULLY REPLACES the built-in
        // verdict here too: resolved per request (cheap stats exists-checks;
        // the serve process lives across retries/generation), honored only
        // for apple-backend requests, and mapping onto tool attachment via
        // the spec's own rules. No spec → built-in behavior, unchanged.
        var toolLayer: ToolLayer?
        var specOutcomes: DecisionRuleEvaluator.Result?
        if !(completion.stream ?? false),
           server.routingEnabled,
           selected is AppIntelligenceEngine {
            if let spec = Self.resolvedDecisionSpec() {
                specOutcomes = await FastDecisions.routeCustom(
                    query: prompt,
                    backend: .apple,
                    spec: spec,
                    timeoutSeconds: FastDecisions.decisionTimeoutSeconds
                )
                if specOutcomes!.useTools {
                    toolLayer = await MainActor.run {
                        ToolLayer(root: nil, allowEdits: false, confirmEdits: false)
                    }
                }
            } else {
                let decision = await FastDecisions.route(query: prompt, backend: .apple)
                if decision.needsTools {
                    toolLayer = await MainActor.run {
                        ToolLayer(root: nil, allowEdits: false, confirmEdits: false)
                    }
                }
            }
        }

        let engineRequest = EngineRequest(
            system: systemMessage,
            prompt: fullPrompt,
            temperature: completion.temperature,
            maxTokens: nil,
            toolLayer: toolLayer,
            stream: completion.stream ?? false
        )

        let id = "chatcmpl-\(UUID().uuidString.prefix(8))"
        let created = Int(Date().timeIntervalSince1970)

        if completion.stream ?? false {
            try await writeResponse(
                fd: fd,
                status: "200 OK",
                body: "",
                contentType: "text/event-stream",
                extraHeader: "Transfer-Encoding: chunked"
            )
            // SSE headers are on the wire — after this point a failure must be
            // reported inside the stream (as an SSE error event), never as a
            // second HTTP response, which would corrupt the stream.
            do {
                let stream = selected.stream(engineRequest)
                var index = 0
                for try await delta in stream {
                    for chunk in Self.streamingChunks(
                        id: id, created: created, delta: delta, index: index, model: completion.model
                    ) {
                        try await writeChunked(fd: fd, text: chunk)
                    }
                    index += 1
                }
                let final = Self.sseChunk(id: id, created: created, delta: "", index: index, model: completion.model, finish: "stop")
                try await writeChunked(fd: fd, text: final)
                try await writeChunked(fd: fd, text: "0\r\n\r\n", raw: true)
            } catch let error as EngineError {
                let errorEvent = Self.sseErrorChunk(
                    message: error.errorDescription ?? String(describing: error),
                    type: Self.errorType(for: error)
                )
                try? await writeChunked(fd: fd, text: errorEvent)
                try await writeChunked(fd: fd, text: "0\r\n\r\n", raw: true)
            } catch {
                try? await writeChunked(
                    fd: fd, text: Self.sseErrorChunk(message: "Internal backend error.", type: "internal_error"))
                try await writeChunked(fd: fd, text: "0\r\n\r\n", raw: true)
            }
        } else {
            let response = try await selected.respond(engineRequest)
            let body = Self.completionJSON(
                id: id,
                created: created,
                content: response.text,
                model: completion.model
            )
            try await writeResponse(fd: fd, status: "200 OK", body: body, contentType: "application/json")
        }
    }

    /// Test hook: overrides the model→engine mapping (nil in production) so
    /// routing can be verified over real sockets without touching live
    /// backends. Swap-in returns a restore closure, mirroring setApprovalGate.
    ///
    /// Note the default branch of the routing table constructs REAL engines
    /// (AppIntelligenceEngine/SiriAXEngine), so an override that wants to stub
    /// the default must return a stub for every resolve() branch — returning
    /// nil falls through to a live backend.
    ///
    /// Implementation: a lock-guarded stack of installer closures. Suites
    /// run in parallel (each `.serialized` only within itself), and a naive
    /// capture-at-install restore writes back a stale value that clobbers
    /// ANOTHER suite's active override — the CI signature where a server
    /// test received a foreign stub reply. LIFO+lock makes push/pop
    /// order-independent, and the final rebuild always reflects the whole
    /// live stack: each `$model` tries the topmost installer whose mapping
    /// answers non-nil for that model.
    @discardableResult
    static func setRoutingOverride(
        _ impl: @escaping @Sendable (String) -> LLMEngine?
    ) -> @Sendable () -> Void {
        routingStack.withLock { $0.append(impl) }
        routingOverride = rebuiltOverride()
        return { [routingStack] in
            let stillActive: Bool = routingStack.withLock { stack -> Bool in
                _ = stack.popLast()
                return !stack.isEmpty
            }
            routingOverride = stillActive ? rebuiltOverride() : nil
        }
    }

    /// Rebuilds the active override closure by chaining the stack from the
    /// base up: the LAST entry installed is the one that gets asked first —
    /// a suite's own mapping can always favor itself by answering non-nil
    /// for its models — and earlier entries act as fallbacks beneath it.
    private static func rebuiltOverride() -> @Sendable (String) -> (any LLMEngine)? {
        let stack = routingStack.withLock { $0 }
        return { [stack] model in
            for impl in stack.reversed() {
                if let engine = impl(model) { return engine }
            }
            return nil
        }
    }

    /// Model-KEYED override install — the concurrency-safe variant. Only the
    /// models the caller supplies are routed to its engine; every other model
    /// falls through to the rest of the stack (production default last).
    ///
    /// Concurrency: claims are exclusive. If ANY of the requested models is
    /// already claimed by an active install (a parallel suite testing the
    /// same model name), the install WAITS (bounded to 60s so a wedged peer
    /// fails loudly instead of hanging CI forever) until the models free up.
    /// The restore releases precisely the caller's claims and wakes waiters.
    @discardableResult
    static func setKeyedRoutingOverride(
        _ enginesByModel: [String: LLMEngine]
    ) -> @Sendable () -> Void {
        let mapping = Dictionary(uniqueKeysWithValues:
            enginesByModel.map { (key: $0.key.lowercased(), value: $0.value) })
        let wanted = Set(mapping.keys)

        routingClaims.lock()
        let deadline = Date().addingTimeInterval(60)
        while !wanted.isDisjoint(with: routingClaims.active) {
            if !routingClaims.cond.wait(until: deadline) { break }
        }
        precondition(wanted.isDisjoint(with: routingClaims.active),
                     "setKeyedRoutingOverride: models \(wanted.intersection(routingClaims.active)) still claimed after 60s — a parallel suite never restored its override")
        // Closures aren't Equatable — rendezvous via a fresh UUID tag: the
        // restore probes the stack with this tag to find and remove exactly
        // this installer (the tag key is never a real model name).
        let token = UUID()
        let tag = "__tag-\(token)"
        let impl: @Sendable (String) -> (any LLMEngine)? = { model in
            routingClaims.lock(); defer { routingClaims.unlock() }
            if model == tag { return wanted.first.flatMap { mapping[$0] } }
            return wanted.contains(model.lowercased()) ? mapping[model.lowercased()] : nil
        }
        routingClaims.installers[token] = impl
        routingClaims.active.formUnion(wanted)
        routingClaims.unlock()
        routingStack.withLock { $0.append(impl) }
        routingOverride = rebuiltOverride()

        return { [routingStack] in
            routingClaims.lock()
            routingClaims.installers[token] = nil
            routingClaims.active.subtract(wanted)
            routingClaims.cond.broadcast()
            routingClaims.unlock()
            routingStack.withLock { stack in
                stack.removeAll { installer in installer(tag) != nil }
            }
            routingOverride = routingStack.withLock { $0.isEmpty } ? nil : rebuiltOverride()
        }
    }

    /// Exclusive model-claim registry for setKeyedRoutingOverride. One lock
    /// guards the active-claim set, the installer table, and the condition
    /// variable that wakes blocked installs after a restore.
    private static let routingClaims = ClaimsBox()
    private final class ClaimsBox: @unchecked Sendable {
        let cond = NSCondition()
        var active: Set<String> = []
        var installers: [UUID: @Sendable (String) -> (any LLMEngine)?] = [:]
        func lock() { cond.lock() }
        func unlock() { cond.unlock() }
    }

    /// The override stack. Guarded by its own lock (an unfair lock is fine
    /// at test-invocation rates).
    private static let routingStack: OSAllocatedUnfairLock<[(@Sendable (String) -> (any LLMEngine)?)]> =
        OSAllocatedUnfairLock(initialState: [])

    /// Composed snapshot of the stack, kept in sync by setRoutingOverride/restore.
    /// Plain var (not lock-hidden) because both writers already hold routingStack's
    /// lock discipline in order; readers only ever see a fully rebuilt value.
    nonisolated(unsafe) private static var routingOverride: (@Sendable (String) -> (any LLMEngine)?)?

    /// Model name → backend. "siri-ai" selects the Siri Accessibility engine;
    /// the default (and "apple-intelligence") selects the FoundationModels engine.
    static func engine(for model: String) -> LLMEngine {
        if let routingOverride, let engine = routingOverride(model) { return engine }
        return defaultEngine(for: model)
    }

    /// Per-request decision-spec resolution for the serve path. Default looks
    /// for `<serve>/../.siri-ai/decisions.spec` from the process CWD (the serve
    /// command has no --repo; the spec owner sets the working directory they
    /// launch `siri-ai serve` from). Nil → built-in verdict, unchanged.
    ///
    /// Test hook: overrides resolution so spec-driven routing can be verified
    /// over real sockets with stub engines — mirrors `routingOverride`.
    nonisolated(unsafe) static var specResolutionOverride: (@Sendable () -> DecisionSpec?)?

    @discardableResult
    static func setDecisionSpecResolver(
        _ impl: @escaping @Sendable () -> DecisionSpec?,
        applyImmediately: Bool
    ) -> @Sendable () -> Void {
        let previous = specResolutionOverride
        specResolutionOverride = impl
        if applyImmediately { _ = impl() }   // warm-up parity for prod timing
        return { specResolutionOverride = previous }
    }

    /// The resolver the request path consults; production path ignores
    /// unsupported-scheme specs just like the CLI (parse failure → warning
    /// stderr, built-in verdict — never a hard error mid-request).
    static func resolvedDecisionSpec() -> DecisionSpec? {
        if let specResolutionOverride { return specResolutionOverride() }
        return Self.decisionSpecFromWorkingDirectory()
    }

    /// Production resolution: `<cwd>/.siri-ai/decisions.spec` when present.
    /// A parse failure logs one stderr warning and returns nil (built-in
    /// routing) — the server must not 500 every request because of a bad
    /// spec, unlike the CLI where the operator is present to fix it.
    static func decisionSpecFromWorkingDirectory() -> DecisionSpec? {
        let cwd = FileManager.default.currentDirectoryPath
        let candidate = cwd + "/" + DecisionSpec.discoveryPath
        guard FileManager.default.fileExists(atPath: candidate) else { return nil }
        do {
            return try DecisionSpec.load(path: candidate)
        } catch {
            TerminalOutput.error("[serve] decision spec \(candidate) failed to parse: \(error.localizedDescription) — using built-in routing verdict")
            return nil
        }
    }

    private static func defaultEngine(for model: String) -> LLMEngine {
        switch resolve(model: model) {
        case .siri: return SiriAXEngine()
        case .apple: return AppIntelligenceEngine()
        }
    }

    // MARK: - Model registry (single source of truth)

    /// The models this server exposes, and everything the routing table and
    /// /v1/models derive from. Adding a backend here updates BOTH the models
    /// list and request routing — no second place to forget.
    enum ServerModel: String, CaseIterable, Sendable {
        /// On-device FoundationModels backend (the default for any name that
        /// isn't recognized as another model).
        case apple = "apple-intelligence"
        /// Real Siri AI app driven via the macOS Accessibility API.
        case siri = "siri-ai"

        /// Additional request names that resolve to this model. OpenAI-style
        /// namespaced ids ("org/model") are tolerated for backward compat.
        var aliases: [String] {
            switch self {
            case .apple: return ["apple", "apple-intelligence"]
            case .siri: return ["siri", "siri-ai", "openai/siri-ai"]
            }
        }

        /// The `owned_by` field in /v1/models output.
        var ownedBy: String {
            switch self {
            case .apple: return "local"
            case .siri: return "apple"
            }
        }
    }

    /// Map a request's model string to a registry entry. Every name outside
    /// the registry ALIASES resolves to `.apple` — the documented default.
    /// Matching is case-insensitive, like the pre-registry switch.
    static func resolve(model: String) -> ServerModel {
        let requested = model.lowercased()
        for entry in ServerModel.allCases where entry.aliases.contains(requested) {
            return entry
        }
        return .apple
    }

    /// /v1/models body, generated from the registry so the advertised list
    /// and request routing can never disagree.
    static func modelsListJSON() -> String {
        let models = ServerModel.allCases
            .map { "{\"id\":\"\($0.rawValue)\",\"object\":\"model\",\"owned_by\":\"\($0.ownedBy)\"}" }
            .joined(separator: ", ")
        return "{" + ["\"object\":\"list\"", "\"data\":[\(models)]"].joined(separator: ",") + "}"
    }

    // MARK: - OpenAI wire formats

    static func sseChunk(id: String, created: Int, delta: String, index: Int, model: String, finish: String? = nil) -> String {
        let finishJSON: String
        if let finish {
            finishJSON = "\"\(finish)\""
        } else {
            finishJSON = "null"
        }
        let payload = """
        {"id":"\(id)","object":"chat.completion.chunk","created":\(created),"model":"\(model)","choices":[{"index":\(index),"delta":{"content":\(Self.jsonString(delta))},"finish_reason":\(finishJSON)}]}
        """
        return "data: \(payload)\n\n"
    }

    /// One engine delta → zero or more SSE chunks, translating engine-internal
    /// markers into client-visible events.
    ///
    /// The Siri AX backend emits "\u{000B}" + snapshot when Siri re-renders
    /// earlier text (the AX tree replaced rather than extended). A raw vertical
    /// tab in `delta.content` is valid JSON here ( jsonString escapes it) but
    /// means nothing to OpenAI SDK clients, so instead the rewrite is surfaced
    /// as a fresh assistant message: a `finish_reason: "length"` boundary (the
    /// OpenAI convention for "this output is not the final continuation")
    /// followed by the replacement snapshot as content of a new choice index.
    /// Clients that accumulate every delta and drop their buffer on any
    /// non-empty rewrite event reproduce the final answer exactly.
    static func streamingChunks(
        id: String, created: Int, delta: String, index: Int, model: String
    ) -> [String] {
        guard delta.hasPrefix("\u{000B}") else {
            return [sseChunk(id: id, created: created, delta: delta, index: index, model: model)]
        }
        let rewritten = String(delta.dropFirst())
        var chunks: [String] = []
        // Close the previous (now-obsolete) rendering first.
        chunks.append(sseChunk(id: id, created: created, delta: "", index: index, model: model, finish: "length"))
        if !rewritten.isEmpty {
            chunks.append(sseChunk(id: id, created: created, delta: rewritten, index: index + 1, model: model))
        }
        return chunks
    }

    /// SSE event reporting a mid-stream backend failure. Sent INSTEAD of a
    /// second HTTP response once the 200 + SSE headers are already on the wire
    /// (a second status line would corrupt the stream for strict clients).
    static func sseErrorChunk(message: String, type: String = "backend_error") -> String {
        let payload = "{\"error\":{\"message\":\(Self.jsonString(message)),\"type\":\"\(type)\"}}"
        return "data: \(payload)\n\n"
    }

    // MARK: - Error status mapping

    /// HTTP status for a known backend failure. EngineError carries intent:
    /// unavailable = capability missing (nothing the client can fix) → 503;
    /// timeout = the work may or may not be done → 504; backend = bad request
    /// parameters the client CAN fix (bad repo path) or a genuine engine fault
    /// → 400/500. Unknown errors keep the generic 500.
    static func httpStatus(for error: EngineError) -> String {
        switch error {
        case .unavailable: return "503 Service Unavailable"
        case .timeout: return "504 Gateway Timeout"
        case .backend: return "500 Internal Server Error"
        }
    }

    /// OpenAI-style `error.type` for a known backend failure.
    static func errorType(for error: EngineError) -> String {
        switch error {
        case .unavailable: return "engine_unavailable"
        case .timeout: return "engine_timeout"
        case .backend: return "backend_error"
        }
    }

    /// OpenAI-style bearer error envelope.
    static func errorEnvelope(message: String, type: String) -> String {
        "{\"error\":{\"message\":\(Self.jsonString(message)),\"type\":\"\(type)\"}}"
    }

    static func completionJSON(id: String, created: Int, content: String, model: String) -> String {
        """
        {"id":"\(id)","object":"chat.completion","created":\(created),"model":"\(model)","choices":[{"index":0,"message":{"role":"assistant","content":\(Self.jsonString(content))},"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}
        """
    }

    /// Escape a Swift string for use inside a JSON document.
    ///
    /// Beyond the classic escapes, ALL control characters (< 0x20) are \u-escaped.
    /// This matters for the Siri AX backend, whose re-render marker is a raw
    /// vertical tab (\u{000B}): a strict JSON parser rejects the unescaped form.
    static func jsonString(_ input: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(input.count + 8)
        for scalar in input.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            case let s where s.value < 0x20:
                escaped += "\\u" + String(format: "%04x", arguments: [s.value])
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    struct ChatCompletionRequest: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let stream: Bool?
        let temperature: Double?
    }

    // MARK: - Raw HTTP plumbing

    struct HTTPRequest {
        let method: String
        let path: String
        let body: String
    }

    private static func readRequest(fd: Int32) throws -> HTTPRequest? {
        var buffer = [UInt8]()
        buffer.reserveCapacity(8192)
        var chunk = [UInt8](repeating: 0, count: 4096)
        var headerParsed = false
        var contentLength = 0

        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if !headerParsed, let headerEnd = buffer.firstRange(of: Array("\r\n\r\n".utf8)) {
                headerParsed = true
                let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                contentLength = Self.contentLength(from: headerText)
            }
            if headerParsed, buffer.count >= (contentLength + headerBodyStart(buffer)) {
                break
            }
            if buffer.count > 1_048_576 { break }  // 1 MB safety cap
        }
        return Self.parseHTTPRequest(from: buffer)
    }

    /// Pure parser: raw bytes → HTTPRequest. Separate from socket reads so
    /// malformed and edge-case requests can be unit-tested directly.
    static func parseHTTPRequest(from buffer: [UInt8]) -> HTTPRequest? {
        guard let headerEnd = buffer.firstRange(of: Array("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
        guard requestLine.count >= 2 else { return nil }
        let body = String(decoding: buffer[headerEnd.upperBound...], as: UTF8.self)
        return HTTPRequest(
            method: requestLine[0],
            path: requestLine[1].split(separator: "?").first.map(String.init) ?? requestLine[1],
            body: body
        )
    }

    /// Internal for @testable coverage of header parsing edge cases.
    static func contentLength(from headerText: String) -> Int {
        for line in headerText.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1]) ?? 0
            }
        }
        return 0
    }

    private static func headerBodyStart(_ buffer: [UInt8]) -> Int {
        buffer.firstRange(of: Array("\r\n\r\n".utf8))?.upperBound ?? 0
    }

    private static func writeResponse(
        fd: Int32,
        status: String,
        body: String,
        contentType: String,
        extraHeader: String? = nil
    ) async throws {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.utf8.count)\r\n"
        if let extraHeader {
            header += extraHeader + "\r\n"
        }
        header += "\r\n"
        var packet = Array((header + body).utf8)
        try sendAll(fd: fd, bytes: &packet)
    }

    private static func writeChunked(fd: Int32, text: String, raw: Bool = false) async throws {
        var payload: [UInt8]
        if raw {
            payload = Array(text.utf8)
        } else {
            let hex = String(text.utf8.count, radix: 16, uppercase: false)
            payload = Array("\(hex)\r\n\(text)\r\n".utf8)
        }
        try sendAll(fd: fd, bytes: &payload)
    }

    private static func sendAll(fd: Int32, bytes: inout [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBufferPointer { buffer in
                send(fd, buffer.baseAddress! + offset, bytes.count - offset, 0)
            }
            if sent <= 0 {
                throw EngineError.backend("Socket send failed.")
            }
            offset += sent
        }
    }
}
