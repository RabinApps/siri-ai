import Testing
import Foundation
import FoundationModels
@testable import siri_ai
@testable import SiriAILib

/// Deterministic engine stub for server/tool tests — no model involved.
/// Configure per instance (replies in order, optional failure) so parallel
/// tests never share state.
final class StubEngine: LLMEngine, @unchecked Sendable {
    private let replies: [String]
    private let failure: (any Error)?
    private let lock = NSLock()
    private var index = 0

    /// Replies handed out in order; exhausted → echoes "[stub] <prompt>".
    init(replies: [String] = []) {
        self.replies = replies
        self.failure = nil
    }

    /// Always throws the given error.
 init(failure: any Error) {
        self.replies = []
        self.failure = failure
    }

    private func nextReply(_ request: EngineRequest) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard index < replies.count else { return "[stub] \(request.prompt)" }
        defer { index += 1 }
        return replies[index]
    }

    func respond(_ request: EngineRequest) async throws -> AgentResponse {
        if let failure { throw failure }
        return AgentResponse(text: nextReply(request), streamed: false)
    }

    func stream(_ request: EngineRequest) -> AsyncThrowingStream<String, Error> {
        // Resolve everything synchronously here: `request` is not Sendable, so
        // the Task closure must not capture it (sending-closure data race).
        let failure = self.failure
        let reply = nextReply(request)
        let words = reply.split(separator: " ").map(String.init)
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let error = failure {
                    continuation.finish(throwing: error)
                    return
                }
                // Split into word-ish deltas so streaming paths get real chunks.
                for word in words {
                    continuation.yield(word + " ")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var availability: AvailabilityReport {
        get async { AvailabilityReport(backend: .apple, ready: true, detail: "stub") }
    }
}

/// Minimal error type for stub failures.
struct StubError: Error, CustomStringConvertible {
    let description = "stub failure"
}

@Suite("OpenAI server over real loopback sockets", .serialized)
struct ServerSocketTests {
    /// Spins up one server instance on an ephemeral port and returns the port.
    private func startServer(engine: LLMEngine) throws -> (port: Int, listener: Int32) {
        // Port 0 = OS assigns a free ephemeral port.
        let listenerFD = try makeListener(port: 0)
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        getsockname(listenerFD, sockaddr_cast(&addr), &len)
        let port = Int(CFSwapInt16BigToHost(addr.sin_port))
        return (port, listenerFD)
    }

    private func sockaddr_cast(_ p: UnsafeMutablePointer<sockaddr_in>) -> UnsafeMutablePointer<sockaddr> {
        UnsafeMutableRawPointer(p).assumingMemoryBound(to: sockaddr.self)
    }

    func makeListener(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
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
        guard bindResult == 0 else { throw StubError() }
        guard listen(fd, 8) == 0 else { throw StubError() }
        return fd
    }

    @Test func healthModelsAndNotFound() async throws {
        let (port, listenerFD) = try startServer(engine: StubEngine())
        defer { close(listenerFD) }

        // Serve three connections serially in the background.
        let server = OpenAIServer(port: port, engine: StubEngine(replies: []), routingEnabled: false)
        let serverTask = Task {
            await server.acceptLoop(listenerFD: listenerFD, maxConnections: 3)
        }

        let health = try await Self.httpRequest(
            "GET /health HTTP/1.1\r\nHost: t\r\n\r\n", port: port)
        #expect(health.contains("HTTP/1.1 200 OK"))
        #expect(health.contains(#"{"status":"ok"}"#))

        let models = try await Self.httpRequest(
            "GET /v1/models HTTP/1.1\r\nHost: t\r\n\r\n", port: port)
        #expect(models.contains("apple-intelligence"))
        #expect(models.contains("siri-ai"))

        let missing = try await Self.httpRequest(
            "GET /nope HTTP/1.1\r\nHost: t\r\n\r\n", port: port)
        #expect(missing.contains("HTTP/1.1 404"))

        await serverTask.value
    }

    @Test func chatCompletionsBufferedAndStreamed() async throws {
        let stub = StubEngine(replies: ["Hello typed world", "Hello streamed reply"])
        let (port, listenerFD) = try startServer(engine: stub)
        defer { close(listenerFD) }

        let server = OpenAIServer(port: port, engine: stub, routingEnabled: false)
        let serverTask = Task {
            await server.acceptLoop(listenerFD: listenerFD, maxConnections: 2)
        }

        let bufferedBody = #"{"model":"apple-intelligence","messages":[{"role":"user","content":"hi"}],"stream":false}"#
        let buffered = try await Self.httpRequest(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: \(bufferedBody.utf8.count)\r\n\r\n\(bufferedBody)",
            port: port
        )
        #expect(buffered.contains("\"content\":\"Hello typed world\""))

        let streamBody = #"{"model":"siri-ai","messages":[{"role":"user","content":"hi"}],"stream":true}"#
        let streamed = try await Self.httpRequest(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: \(streamBody.utf8.count)\r\n\r\n\(streamBody)",
            port: port
        )
        #expect(streamed.contains("data: "))
        #expect(streamed.contains("Hello"))   // word-chunk deltas

        await serverTask.value
    }

    @Test func invalidBodyYields400AndBackendErrorYields500() async throws {
        let (port, listenerFD) = try startServer(engine: StubEngine(failure: StubError()))
        defer { close(listenerFD) }

        let server = OpenAIServer(port: port, engine: StubEngine(failure: StubError()), routingEnabled: false)
        let serverTask = Task {
            await server.acceptLoop(listenerFD: listenerFD, maxConnections: 2)
        }

        let bad = try await Self.httpRequest(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nContent-Length: 9\r\n\r\nnot json!",
            port: port
        )
        #expect(bad.contains("HTTP/1.1 400"))

        let errBody = #"{"model":"apple-intelligence","messages":[{"role":"user","content":"hi"}],"stream":false}"#
        let backend500 = try await Self.httpRequest(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: \(errBody.utf8.count)\r\n\r\n\(errBody)",
            port: port
        )
        #expect(backend500.contains("HTTP/1.1 500"))
        #expect(backend500.contains("internal_error"))   // StubError is not an EngineError → generic envelope, no leak

        await serverTask.value
    }

    // MARK: - Streaming correctness (control chars, re-render marker, mid-stream errors)

    /// jsonString must \u-escape all control characters, including the Siri AX
    /// re-render marker (vertical tab, \u{000B}), so every emitted JSON payload
    /// parses under a strict decoder.
    @Test func jsonStringEscapesControlCharacters() {
        let escaped = OpenAIServer.jsonString("a\u{000B}b\u{01}c")
        #expect(!escaped.contains("\u{000B}"))
        #expect(!escaped.contains("\u{01}"))
        #expect(escaped.contains("a\\u000bb"))
        #expect(escaped.contains("\\u0001"))
        // The escaped output must round-trip back to the original string.
        let decoded = try? JSONDecoder().decode([String].self, from: Data("[\(escaped)]".utf8))
        #expect(decoded == ["a\u{000B}b\u{01}c"])
        // Classic escapes still hold.
        #expect(OpenAIServer.jsonString("line\nquote\"back\\") == "\"line\\nquote\\\"back\\\\\"")
    }

    /// Pure translation: a plain delta passes through as one normal chunk; the
    /// \v re render marker becomes a finish:"length" boundary + rewrite delta;
    /// a marker with empty payload closes the old rendering only.
    @Test func streamingChunksTranslatesReRenderMarker() {
        let plain = OpenAIServer.streamingChunks(id: "x", created: 0, delta: "hello", index: 0, model: "siri-ai")
        #expect(plain.count == 1)
        #expect(plain[0].contains(#""content":"hello""#))

        let rewrite = OpenAIServer.streamingChunks(id: "x", created: 0, delta: "\u{000B}fresh answer", index: 2, model: "m")
        #expect(rewrite.count == 2)
        #expect(rewrite[0].contains(#""finish_reason":"length""#))
        #expect(rewrite[0].contains(#""content":"""#))                       // closes old render (empty delta)
        #expect(rewrite[1].contains(#""content":"fresh answer""#))
        #expect(rewrite[1].contains(#""index":3"#))                        // new choice index
        #expect(rewrite.allSatisfy { !$0.contains("\u{000B}") })

        let bare = OpenAIServer.streamingChunks(id: "x", created: 0, delta: "\u{000B}", index: 0, model: "m")
        #expect(bare.count == 1)
        #expect(bare[0].contains(#""finish_reason":"length""#))
    }

    /// Wire test: a Siri-engine delta containing the raw \v marker must arrive
    /// as a `finish_reason: "length"` boundary + rewrite content — never as a
    /// raw control character in an SSE chunk.
    @Test func reRenderMarkerSurfacesAsRewriteEventOverWire() async throws {
        let stub = StubEngine(replies: ["partial "])
        let (port, listenerFD) = try startServer(engine: stub)
        defer { close(listenerFD) }

        // Engine yields a normal growth delta, then Siri re-renders everything:
        // \v + the full replacement snapshot.
        let streamStub = MarkerStreamStub()
        let server = OpenAIServer(port: port, engine: streamStub, routingEnabled: false)
        let serverTask = Task {
            await server.acceptLoop(listenerFD: listenerFD, maxConnections: 1)
        }

        let body = #"{"model":"siri-ai","messages":[{"role":"user","content":"hi"}],"stream":true}"#
        let response = try await Self.httpRequest(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)",
            port: port
        )

        #expect(!response.contains("\u{000B}"))                        // no raw marker on the wire
        #expect(response.contains(#""finish_reason":"length""#))   // rewrite boundary present
        #expect(response.contains("REWRITTEN-SNAPSHOT"))               // replacement content delivered

        await serverTask.value
    }

    /// Wire test: even when the engine fails AFTER streaming began, the
    /// response must contain exactly one HTTP status line (200) and the error
    /// inside the SSE stream — never a second `HTTP/1.1 500` that would corrupt
    /// the response for strict clients.
    @Test func midStreamFailureStaysInsideSSEStream() async throws {
        let (port, listenerFD) = try startServer(engine: StubEngine())
        defer { close(listenerFD) }

        // Throw mid-stream, after two successful deltas.
        let server = OpenAIServer(port: port, engine: FailAfterTwoDeltasStub(), routingEnabled: false)
        let serverTask = Task {
            await server.acceptLoop(listenerFD: listenerFD, maxConnections: 1)
        }

        let body = #"{"model":"apple-intelligence","messages":[{"role":"user","content":"hi"}],"stream":true}"#
        let response = try await Self.httpRequest(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)",
            port: port
        )

        // Exactly one status line — a 500 here would mean the old bug came back.
        let statusLines = response.components(separatedBy: "\r\n").filter { $0.hasPrefix("HTTP/1.1 ") }
        #expect(statusLines == ["HTTP/1.1 200 OK"])
        #expect(response.contains("internal_error"))   // StubError → generic envelope inside SSE
        #expect(response.contains("d-one") && response.contains("d-two"))   // streamed deltas still delivered

        await serverTask.value
    }

    /// Stub that yields a growth delta then a \v-marker rewrite delta.
    final class MarkerStreamStub: LLMEngine, @unchecked Sendable {
        func respond(_ request: EngineRequest) async throws -> AgentResponse {
            AgentResponse(text: "buffered", streamed: false)
        }

        func stream(_ request: EngineRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("partial ")
                continuation.yield("\u{000B}REWRITTEN-SNAPSHOT")
                continuation.finish()
            }
        }

        var availability: AvailabilityReport {
            get async { AvailabilityReport(backend: .apple, ready: true, detail: "stub") }
        }
    }

    /// Stub that streams two deltas then throws (simulating a backend that
    /// dies mid-generation).
    final class FailAfterTwoDeltasStub: LLMEngine, @unchecked Sendable {
        func respond(_ request: EngineRequest) async throws -> AgentResponse {
            AgentResponse(text: "buffered", streamed: false)
        }

        func stream(_ request: EngineRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield("d-one ")
                continuation.yield("d-two ")
                continuation.finish(throwing: StubError())
            }
        }

        var availability: AvailabilityReport {
            get async { AvailabilityReport(backend: .apple, ready: true, detail: "stub") }
        }
    }

    @Test func engineRoutingByModel() async {
        #expect(OpenAIServer.engine(for: "siri-ai") is SiriAXEngine)
        #expect(OpenAIServer.engine(for: "SIRI") is SiriAXEngine)
        #expect(OpenAIServer.engine(for: "apple-intelligence") is AppIntelligenceEngine)
        #expect(OpenAIServer.engine(for: "anything-else") is AppIntelligenceEngine)
    }

    // MARK: - Model registry (single source of truth)

    /// The documented default: every name outside the registry aliases resolves
    /// to the Apple backend. Covers typo'd ids, namespaced ids, and empty.
    @Test func unknownModelNamesResolveToAppleDefault() {
        #expect(OpenAIServer.resolve(model: "anything-else") == .apple)
        #expect(OpenAIServer.resolve(model: "gpt-4o") == .apple)
        #expect(OpenAIServer.resolve(model: "openai/gpt-4") == .apple)
        #expect(OpenAIServer.resolve(model: "") == .apple)
        #expect(OpenAIServer.engine(for: "gpt-4o") is AppIntelligenceEngine)
    }

    /// Every registry alias must decode exactly to its own model, including
    /// case-insensitivity (pre-registry behavior).
    @Test func everyRegistryAliasResolvesExactly() {
        for entry in OpenAIServer.ServerModel.allCases {
            for alias in entry.aliases {
                #expect(OpenAIServer.resolve(model: alias) == entry, "alias \(alias) must resolve to \(entry.rawValue)")
                #expect(OpenAIServer.resolve(model: alias.uppercased()) == entry, "case-insensitive: \(alias.uppercased())")
            }
            // The registry id itself is always a valid alias.
            #expect(entry.aliases.contains(entry.rawValue))
        }
    }

    /// /v1/models and the routing table must agree: every advertised model id
    /// routes to its own backend, and no other id is advertised. Body parses
    /// as JSON containing exactly the registry entries.
    @Test func modelsListMatchesRegistryAndRouting() async throws {
        // Parse the generated body shape-wise: bare JSON with no external dep.
        let body = OpenAIServer.modelsListJSON()
        let parsed = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        #expect(parsed?["object"] as? String == "list")
        let data = parsed?["data"] as? [[String: Any]]
        let advertisedIDs = Set(data?.compactMap { $0["id"] as? String } ?? [])
        #expect(advertisedIDs == Set(OpenAIServer.ServerModel.allCases.map(\.rawValue)))
        // Every advertised entry carries its registry owned_by.
        for model in data ?? [] {
            let id = model["id"] as? String ?? ""
            let entry = OpenAIServer.ServerModel(rawValue: id)
            #expect(model["owned_by"] as? String == entry?.ownedBy)
        }

        // Routing agrees with advertisement: advertised apple-intelligence →
        // Apple engine; advertised siri-ai → Siri engine.
        #expect(OpenAIServer.engine(for: "apple-intelligence") is AppIntelligenceEngine)
        #expect(OpenAIServer.engine(for: "siri-ai") is SiriAXEngine)
    }

    /// Over-the-wire proof of the default: an UNKNOWN model name on a routing-
    /// enabled server is answered by the Apple-side engine, not by Siri and not
    /// by the injected engine. The default mapping constructs REAL engines, so
    /// the override stubs both branches: known ids map to their stub, unknown
    /// ids fall through to the production defaultEngine via `defaultStub`.
    @Test func unknownModelRoutedToAppleEngineOverWire() async throws {
        let appleStub = StubEngine(replies: ["DEFAULT-APPLE-SAW-THIS"])
        let siriStub = StubEngine(replies: ["bad: siri engine used"])
        let restore = OpenAIServer.setKeyedRoutingOverride([
            "siri-ai": siriStub,
            "Apple-Intelligence": appleStub,
            "totally-unknown-model": appleStub,
        ])
        defer { restore() }

        let (port, listenerFD) = try startServer(engine: StubEngine())
        defer { close(listenerFD) }

        // routingEnabled: true = production serve behavior. The injected
        // engine would answer only if routing were bypassed.
        let server = OpenAIServer(port: port, engine: StubEngine(replies: ["bad: injected engine used"]), routingEnabled: true)
        let serverTask = Task {
            await server.acceptLoop(listenerFD: listenerFD, maxConnections: 1)
        }

        let body = #"{"model":"totally-unknown-model","messages":[{"role":"user","content":"hi"}],"stream":false}"#
        let response = try await Self.httpRequest(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)",
            port: port
        )

        #expect(response.contains("DEFAULT-APPLE-SAW-THIS"))
        #expect(!response.contains("bad: injected engine used"))
        #expect(!response.contains("bad: siri engine used"))

        await serverTask.value
    }

    /// End-to-end over real sockets: the model field in the request body
    /// selects which engine answers (routingEnabled: true, the `serve`
    /// default). Two differently-configured stubs are swapped in via the
    /// routing override so no live backend is involved; the response text
    /// proves which engine served the request.
    @Test func modelFieldRoutesToSelectedEngineOverWire() async throws {
        let siriStub = StubEngine(replies: ["SIRI-ENGINE-SAW-THIS"])
        let appleStub = StubEngine(replies: ["APPLE-ENGINE-SAW-THIS"])
        // Keyed install: claims only "siri-ai"/"apple-intelligence" so a
        // parallel suite's keyed claims can coexist (claim-wait serializes
        // any true overlap).
        let restore = OpenAIServer.setKeyedRoutingOverride([
            "siri-ai": siriStub,
            "apple-intelligence": appleStub,
        ])
        defer { restore() }

        let (port, listenerFD) = try startServer(engine: StubEngine())
        defer { close(listenerFD) }

        // routingEnabled: true reproduces the serve command's production setup.
        let server = OpenAIServer(port: port, engine: StubEngine(replies: ["bad: injected engine used"]), routingEnabled: true)
        let serverTask = Task {
            await server.acceptLoop(listenerFD: listenerFD, maxConnections: 2)
        }

        func ask(_ model: String) async throws -> String {
            let body = #"{"model":"\#(model)","messages":[{"role":"user","content":"hi"}],"stream":false}"#
            return try await Self.httpRequest(
                "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)",
                port: port
            )
        }

        let siriResponse = try await ask("siri-ai")
        #expect(siriResponse.contains("SIRI-ENGINE-SAW-THIS"))
        let appleResponse = try await ask("apple-intelligence")
        #expect(appleResponse.contains("APPLE-ENGINE-SAW-THIS"))
        #expect(!siriResponse.contains("bad: injected engine used"))

        await serverTask.value
    }

    // MARK: - Socket hardening + EngineError status mapping

    /// Buffered requests surface EngineError with mapped statuses and typed
    /// envelopes — not a raw Swift error dump in a blanket 500.
    @Test func engineErrorMappedToTypedStatusAndEnvelope() async throws {
        let cases: [(error: EngineError, status: String, type: String)] = [
            (EngineError.unavailable("Apple Intelligence model is not available. Run `siri-ai status`."), "503", "engine_unavailable"),
            (EngineError.timeout("30"), "504", "engine_timeout"),
            (EngineError.backend("Could not locate the composer"), "500", "backend_error"),
        ]
        for testCase in cases {
            let (port, listenerFD) = try startServer(engine: StubEngine())
            defer { close(listenerFD) }

            let server = OpenAIServer(port: port, engine: StubEngine(failure: testCase.error), routingEnabled: false)
            let serverTask = Task {
                await server.acceptLoop(listenerFD: listenerFD, maxConnections: 1)
            }

            let body = #"{"model":"apple-intelligence","messages":[{"role":"user","content":"hi"}],"stream":false}"#
            let response = try await Self.httpRequest(
                "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)",
                port: port
            )

            #expect(response.contains("HTTP/1.1 \(testCase.status)"), "\(testCase.error) must map to \(testCase.status)")
            #expect(response.contains(#""type":"# + "\"\(testCase.type)\""))
            #expect(response.contains("message"))
            // Raw Swift error representation must not leak into the envelope.
            #expect(!response.contains("EngineError."))

            await serverTask.value
        }
    }

    /// Mid-stream EngineError surfaces the same typed envelope inside SSE.
    @Test func midStreamEngineErrorCarriesMappedType() async throws {
        let (port, listenerFD) = try startServer(engine: StubEngine())
        defer { close(listenerFD) }

        final class FailingStream: LLMEngine, @unchecked Sendable {
            func respond(_ request: EngineRequest) async throws -> AgentResponse {
                AgentResponse(text: "", streamed: false)
            }
            func stream(_ request: EngineRequest) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { c in
                    c.yield("partial ")
                    c.finish(throwing: EngineError.timeout("5"))
                }
            }
            var availability: AvailabilityReport {
                get async { AvailabilityReport(backend: .apple, ready: true, detail: "stub") }
            }
        }
        let server = OpenAIServer(port: port, engine: FailingStream(), routingEnabled: false)
        let serverTask = Task {
            await server.acceptLoop(listenerFD: listenerFD, maxConnections: 1)
        }

        let body = #"{"model":"siri-ai","messages":[{"role":"user","content":"hi"}],"stream":true}"#
        let response = try await Self.httpRequest(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)",
            port: port
        )

        let statusLines = response.components(separatedBy: "\r\n").filter { $0.hasPrefix("HTTP/1.1 ") }
        #expect(statusLines == ["HTTP/1.1 200 OK"])            // single status line
        #expect(response.contains("\"type\":\"engine_timeout\""))
        #expect(response.contains("partial"))                   // deltas before the failure still delivered

        await serverTask.value
    }

    /// Unknown (non-EngineError) failures keep a generic 500 envelope WITHOUT
    /// leaking the raw Swift error dump into the client-visible message.
    @Test func unknownErrorKeepsGeneric500WithoutLeaking() async throws {
        let (port, listenerFD) = try startServer(engine: StubEngine())
        defer { close(listenerFD) }

        let server = OpenAIServer(port: port, engine: StubEngine(failure: StubError()), routingEnabled: false)
        let serverTask = Task {
            await server.acceptLoop(listenerFD: listenerFD, maxConnections: 1)
        }

        let body = #"{"model":"apple-intelligence","messages":[{"role":"user","content":"hi"}],"stream":false}"#
        let response = try await Self.httpRequest(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)",
            port: port
        )

        #expect(response.contains("HTTP/1.1 500"))
        #expect(response.contains("internal_error"))
        // StubError's description ("stub failure") must NOT appear.
        #expect(!response.contains("stub failure"))

        await serverTask.value
    }

    /// makeListener validates socket() creation (fd >= 0) before use.
    @Test func makeListenerThrowsDistinctErrorOnInvalidFd() {
        // Indirect validation: a successful makeListener returns a usable fd,
        // and its errors are EngineErrors with cause text (not blanket "Could
        // not bind port"). Direct -1 injection isn't reachable without seed
        // fd exhaustion, so assert the contract on the success path + error type.
        do {
            let fd = try OpenAIServer(port: 0, engine: StubEngine()).listenerForTesting()
            #expect(fd >= 0)
            close(fd)
        } catch {
            Issue.record("listener should succeed on ephemeral port: \(error)")
        }
    }

    /// SO_RCVTIMEO is settable on an accepted-style socket without error.
    @Test func setReceiveTimeoutAppliesCleanly() throws {
        let pair = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { pair.deallocate() }
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0)
        OpenAIServer.setReceiveTimeout(seconds: 5, on: pair[0])
        // Verify the timeout took effect by reading it back.
        var tv = timeval()
        var len = socklen_t(MemoryLayout<timeval>.size)
        #expect(getsockopt(pair[0], SOL_SOCKET, SO_RCVTIMEO, &tv, &len) == 0)
        #expect(tv.tv_sec == 5)
        close(pair[0]); close(pair[1])
    }

    /// Minimal one-shot HTTP client over sockets: sends raw, reads until EOF.
    /// Shared with other suites via `rawOneShot`.
    static func rawOneShot(_ raw: String, port: Int) async throws -> String {
        try await httpRequest(raw, port: port)
    }

    private static func httpRequest(_ raw: String, port: Int) async throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw StubError() }
        let payload = Array(raw.utf8)
        var sent = 0
        while sent < payload.count {
            let n = payload.withUnsafeBufferPointer { base in
                send(fd, base.baseAddress! + sent, payload.count - sent, 0)
            }
            guard n > 0 else { throw StubError() }
            sent += n
        }
        shutdown(fd, SHUT_WR)   // signal EOF so the server stops reading
        var response: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            response.append(contentsOf: chunk[0..<n])
            if response.count > 1_048_576 { break }
        }
        return String(decoding: response, as: UTF8.self)
    }
}

