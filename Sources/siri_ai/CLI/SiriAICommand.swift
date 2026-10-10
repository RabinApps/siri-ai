import Foundation
import ArgumentParser
import SiriAILib

@main
struct SiriAICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "siri-ai",
        abstract: "Apple Intelligence and Siri AI from your terminal.",
        version: "0.1.0",
        subcommands: [Ask.self, Chat.self, Serve.self, Status.self, PermissionCommand.self],
        defaultSubcommand: Ask.self
    )
}

// MARK: - ask

/// Minimal lock-guarded boolean shared between the deadline task and the
/// collector path (no atomics dependency needed).
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); defer { lock.unlock() }; value = true }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct Ask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Ask Apple Intelligence (or Siri) a question, optionally about code in a repository."
    )

    @Argument(help: "Question or instruction. Reads from stdin if piped and omitted.")
    var query: String?

    @Option(name: .shortAndLong, help: "Repository root to ground the answer in (uses cwd if omitted).")
    var repo: String?

    @Flag(name: .long, help: "Show the model the files it asks for, via tool calls.")
    var tools: Bool = false

    @Flag(name: .long, help: "Allow the model to propose file edits (with y/N confirmation; implies --tools).")
    var edit: Bool = false

    @Option(name: .shortAndLong, help: "Backend: 'apple' (default) or 'siri' for the Siri AI app.")
    var backend: String = "apple"

    @Option(name: .shortAndLong, help: "Sampling temperature, 0.0-2.0.")
    var temperature: Double?

    @Option(name: .shortAndLong, help: "Maximum response tokens.")
    var maxTokens: Int?

    @Flag(help: "Disable streaming; buffer the full answer before printing.")
    var noStream: Bool = false

    @Flag(help: "Skip the fast typed pre-decision pass (query routing + edit gate) and use CLI flags/heuristics only.")
    var noFastDecisions: Bool = false

    @Option(name: .long, help: "Path to a .decision-spec file: a user-defined decision schema that fully replaces the built-in routing verdict.")
    var decisions: String?

    @Option(name: .long, help: "Wall-clock deadline in seconds for the model answer; exits 124 with an error message when exceeded. Guards against an engine wedge that cooperative cancellation cannot break.")
    var maxSeconds: Double?

    mutating func run() async throws {
        var q = query ?? ""
        if q.isEmpty && StdinHelper.hasPipedInput() {
            q = StdinHelper.readPipedInput()
        }
        guard !q.isEmpty else {
            TerminalOutput.error("Error: no query given (pass one as an argument or pipe via stdin).")
            throw ExitCode.failure
        }

        let engine = EngineFactory.make(backend: backend)
        FastDecisions.isEnabled = !noFastDecisions
        let effectiveTools = tools || edit

        if effectiveTools || repo != nil {
            try await runWithRepoContext(
                engine: engine, query: q,
                decisionBackend: EngineFactory.parse(backend))
        } else {
            try await runPlain(engine: engine, query: q)
        }
    }

    /// Internal for @testable coverage via injected engine/config.
    func runPlain(engine: LLMEngine, query: String) async throws {
        let request = EngineRequest(
            system: nil,
            prompt: query,
            temperature: temperature,
            maxTokens: maxTokens,
            toolLayer: nil,
            stream: !noStream
        )
        if let seconds = maxSeconds {
            // Deadline path: bail out of a wedged engine call — modeled on
            // the live tool-loop hang (>7 min, no fault surfaced). Exits
            // 124 (the GNU timeout convention) so scripts can distinguish
            // "engine wedged" from a normal failure. The deadline wrapper
            // lives in SiriAILib (shared with the live tests).
            do {
                if noStream {
                    let response = try await withInferenceDeadline(seconds, { () async throws -> AgentResponse in
                        try await engine.respond(request)
                    })
                    TerminalOutput.line(response.text)
                } else {
                    let stream = engine.stream(request)
                    // The deadline covers the wait-to-first-delta only: once
                    // a delta arrives the model is genuinely producing and a
                    // late finish is legitimate (long answers). A deadline
                    // expiry with zero deltas is the bail-out.
                    let collector = Task {
                        var iterator = stream.makeAsyncIterator()
                        var text = ""
                        while let delta = try await iterator.next() {
                            text += delta
                        }
                        return text
                    }
                    let expired = AtomicFlag()
                    let deadlineTask = Task {
                        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                        expired.set()
                        collector.cancel()
                    }
                    let text: String
                    do {
                        text = try await collector.value
                    } catch {
                        deadlineTask.cancel()
                        if expired.get() {
                            TerminalOutput.error("Timed out after \(Int(seconds))s with no answer (engine wedged?).")
                            throw ExitCode(124)
                        }
                        throw error
                    }
                    deadlineTask.cancel()
                    TerminalOutput.line(text)
                }
            } catch let exit as ExitCode {
                throw exit
            } catch let engineError as EngineError {
                if case .timeout = engineError {
                    TerminalOutput.error("Timed out after \(Int(seconds))s (engine wedged?).")
                    throw ExitCode(124)
                }
                throw engineError
            }
            return
        }
        if noStream {
            let response = try await engine.respond(request)
            TerminalOutput.line(response.text)
        } else {
            for try await delta in engine.stream(request) {
                TerminalOutput.raw(delta)
            }
            TerminalOutput.line("")
        }
    }

    /// Internal for @testable coverage via injected engine/config.
    /// `cannedDecision` pins the System-1 verdict: nil (production) computes
    /// it live — heuristic when `--no-fast-decisions`, model-with-fallback
    /// otherwise. A non-nil value comes from the test-suite ONLY; it bypasses
    /// the model call AND the heuristic so table-driven CLI-path tests are
    /// fully deterministic without leaning on the kill switch. The edit
    /// pre-gate is likewise skipped (canned isEditRequest is final).
    func runWithRepoContext(
        engine: LLMEngine,
        query: String,
        decisionBackend: Backend = .apple,
        cannedDecision: FastDecision? = nil
    ) async throws {
        let root = (repo ?? FileManager.default.currentDirectoryPath).replaceTilde
        let scanner = RepoScanner(root: root)
        let files = try scanner.scan()
        if files.isEmpty {
            TerminalOutput.error("No candidate files found under \(root); falling back to plain query.")
            try await runPlain(engine: engine, query: query)
            return
        }

        // System 1: fast typed routing verdict (with heuristic fallback). CLI
        // flags are explicit user intent and only ever widen the decision —
        // the classifier never narrows what the user asked for.
        // --no-fast-decisions forces the deterministic heuristic verdict so
        // scripted/branch-sensitive behavior is stable.
        // --decisions / repo-discovered .siri-ai/decisions.spec FULLY REPLACE
        // the built-in verdict: the model fills the user schema and the
        // spec's own rules map values onto routing outcomes.
        let spec = try loadDecisionSpec(repoRoot: root)
        let effectiveTools: Bool
        var effectiveEdit: Bool
        if let spec {
            let routed = await FastDecisions.routeCustom(
                query: query, backend: decisionBackend, spec: spec,
                timeoutSeconds: FastDecisions.decisionTimeoutSeconds
            )
            effectiveTools = routed.useTools
            effectiveEdit = routed.applyEdit
        } else if noFastDecisions {
            // Deterministic heuristic path (--no-fast-decisions). The `siri`
            // backend short-circuits route() to its synchronous heuristic
            // fallback — no model call. (route's fallback contract makes it
            // the same verdict FastDecisionFallback.decide would produce.)
            let heuristic = await FastDecisions.route(query: query, backend: .siri)
            effectiveTools = tools || heuristic.needsTools
            effectiveEdit = edit || heuristic.isEditRequest
        } else {
            let decision = if let cannedDecision {
                cannedDecision
            } else {
                await FastDecisions.route(query: query, backend: decisionBackend)
            }
            effectiveTools = tools || decision.needsTools
            effectiveEdit = edit || decision.isEditRequest
        }

        // Edit pre-gate: when edit mode would engage purely on the model's
        // say-so (no explicit --edit), confirm with the cheap EditGate verdict
        // so a y/N prompt is never raised for clearly non-edit queries.
        // Skipped under a canned decision — the test pins the final verdict.
        // A user decision spec replaces the gate: its rules are the gate.
        if spec == nil, cannedDecision == nil, effectiveEdit, !edit {
            effectiveEdit = await FastDecisions.editGate(query: query)
        }

        let prompt: String
        let system: String
        if effectiveTools {
            // Agentic: give the model file tools and let it fetch what it needs.
            // With --edit, the propose_edit tool is appended so the model can
            // propose file changes; each waits on a y/N confirm at the terminal.
            let layer = await MainActor.run {
                ToolLayer(root: root, allowEdits: effectiveEdit, confirmEdits: true)
            }
            system = effectiveEdit ? """
            You are a coding assistant with edit powers for the repository at \(root).
            Use the tools (list_files, read_file, search_files) to inspect code.
            To change code, call propose_edit with either a find/replacement pair
            (preferred: minimal, surgical) or full new_content. Every proposal is
            shown as a diff and waits for explicit user confirmation before it is
            applied. Never claim an edit succeeded unless the tool confirms it.
            Cite file paths in your answer.
            """ : """
            You are a coding assistant helping with the repository at \(root).
            Use the provided tools (list_files, read_file, search_files) to inspect
            code before answering. Cite file paths in your answer.
            """
            let request = EngineRequest(
                system: system, prompt: query, temperature: temperature,
                maxTokens: maxTokens, toolLayer: layer, stream: false
            )
            let response = try await engine.respond(request)
            let used = await layer.invokedTools
            if !used.isEmpty {
                TerminalOutput.error("Tools used: \(used.joined(separator: ", "))")
            }
            TerminalOutput.line(response.text)
            return
        }
        // Pre-selected context path: stuff relevant files into the prompt.
        let context = ContextBuilder(modelContextSize: modelContextSize()).build(files: files, question: query)
        if !context.includedFiles.isEmpty {
            TerminalOutput.error("Context: \(context.includedFiles.joined(separator: ", "))")
        }
        prompt = """
        ### Context from repository at \(root):
        \(context.contextText)

        ### Question:
        \(query)

        Answer concisely, citing file paths.
        """
        system = "You are a precise, concise coding assistant."
        let request = EngineRequest(
            system: system, prompt: prompt, temperature: temperature,
            maxTokens: maxTokens, toolLayer: nil, stream: !noStream
        )
        if noStream {
            let response = try await engine.respond(request)
            TerminalOutput.line(response.text)
        } else {
            for try await delta in engine.stream(request) {
                TerminalOutput.raw(delta)
            }
            TerminalOutput.line("")
        }
    }

    private func modelContextSize() -> Int {
        // Delegate to the engine: the framework reports the real window on
        // macOS 27 (8,192 on current hardware); 4,096 on macOS 26 or when the
        // model is unavailable.
        AppIntelligenceEngine.modelContextSize()
    }

    /// Resolve the effective decision spec: explicit `--decisions <path>` wins;
    /// otherwise auto-discover `<repo>/.siri-ai/decisions.spec`. Throws a
    /// user-facing error (and exits) only for a spec that exists but fails to
    /// parse — a broken spec should never silently change routing behavior.
    func loadDecisionSpec(repoRoot: String) throws -> DecisionSpec? {
        if let explicit = decisions {
            do {
                return try DecisionSpec.load(path: explicit)
            } catch {
                TerminalOutput.error("Could not load decision spec \(explicit): \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }
        if let discovered = DecisionSpec.discover(repoRoot: repoRoot) {
            TerminalOutput.error("Decision spec: \(repoRoot)/\(DecisionSpec.discoveryPath)")
            return discovered
        }
        return nil
    }
}

// MARK: - chat

/// Injectable stdin-line reader so the chat loop is testable.
enum ChatLineSource {
    nonisolated(unsafe) static var reader: (@Sendable () async -> String?)?

    static func read() async -> String? {
        if let reader { return await reader() }
        return readLine()
    }
}

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Interactive multi-turn chat with automatic context trimming."
    )

    @Option(name: .shortAndLong, help: "System prompt to use for the session.")
    var system: String?

    @Flag(name: .long, help: "Use the Siri AI app instead of Apple Intelligence.")
    var siri: Bool = false

    @Flag(name: .long, help: "Siri backend only: ignore Siri's own on-device memory; context comes from this session's transcript alone.")
    var noMemory: Bool = false

    mutating func run() async throws {
        let engine: LLMEngine = siri ? SiriAXEngine() : AppIntelligenceEngine()
        try await chatLoop(engine: engine, siri: siri, system: system, isolateMemory: noMemory)
    }

    /// The interactive loop, separated for testability (injected engine).
    /// Reads lines from `lineSource` (default: stdin).
    ///
    /// `isolateMemory` (the --no-memory flag) prepends a transcript-only
    /// instruction so the Siri backend does not reach into its personal
    /// knowledge graph / stored notes for context.
    func chatLoop(engine: LLMEngine, siri: Bool, system: String?, isolateMemory: Bool = false) async throws {
        let effectiveSystem = Self.effectiveSystemPrompt(base: system, isolateMemory: isolateMemory)
        var history: [ChatMessage] = []
        history.append(.system(effectiveSystem))
        var turn = 0                 // completed user→assistant exchanges
        var lastLatency: Double?     // ms, last completed turn
        TerminalOutput.line("Chat started. /quit to exit, /clear to reset, /history to inspect the transcript.")
        while true {
            TerminalOutput.raw(Self.promptLine(turn: turn, lastLatencyMs: lastLatency))
            guard let line = await ChatLineSource.read(), !line.isEmpty else { continue }
            switch line {
            case "/quit", "/exit":
                return
            case "/clear":
                history.removeAll()
                history.append(.system(effectiveSystem))   // keep session instructions
                TerminalOutput.line("History cleared.")
                continue
            case "/history":
                Self.printTranscript(history)
                continue
            default:
                break
            }
            history.append(.user(line))
            turn += 1
            let turnStart = ContinuousClock.now
            let prompt = Self.transcriptPrompt(history)
            let request = EngineRequest(
                system: effectiveSystem,
                prompt: prompt,
                temperature: nil,
                maxTokens: nil,
                toolLayer: nil,
                stream: true
            )
            // Siri AX: use the settled final answer (cleaned once) both for
            // display and history; streaming would bake mid-generation chrome
            // into the transcript and compound it across turns.
            if siri {
                let response = try await engine.respond(request)
                lastLatency = Self.milliseconds(ContinuousClock.now - turnStart)
                TerminalOutput.line(response.text)
                history.append(.assistant(response.text))
            } else {
                var reply = ""
                for try await delta in engine.stream(request) {
                    TerminalOutput.raw(delta)
                    reply += delta
                }
                lastLatency = Self.milliseconds(ContinuousClock.now - turnStart)
                TerminalOutput.line("")
                history.append(.assistant(reply))
            }
        }
    }

    /// The interactive prompt line: current turn counter (turns completed so
    /// far) plus the last turn's latency once at least one exchange finished.
    static func promptLine(turn: Int, lastLatencyMs: Double?) -> String {
        if let ms = lastLatencyMs {
            return "[turn \(turn) · last \(Int(ms.rounded()))ms] > "
        }
        return "[turn \(turn)] > "
    }

    /// Wall-clock milliseconds for a Duration (per-turn latency).
    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    /// Builds the session system prompt. With `isolateMemory` (the
    /// --no-memory flag), instructs the Siri backend to treat this session's
    /// transcript as the only context source — no recollection from its
    /// personal knowledge graph, stored notes, or previous conversations.
    static func effectiveSystemPrompt(base: String?, isolateMemory: Bool) -> String {
        let isolationBlock = """
        Context rules for this conversation:
        - Treat the transcript below as your ONLY source of context.
        - Do not recall anything from your personal memory, saved notes, past
          conversations, or the user's profile. If a fact is not in the
          transcript, say so rather than recalling it.
        - Do not save anything from this conversation to memory.
        """
        switch (base, isolateMemory) {
        case (.some(let b), true):
            return b + "\n\n" + isolationBlock
        case (.some(let b), false):
            return b
        case (nil, true):
            return isolationBlock
        case (nil, false):
            return "You are a concise assistant."
        }
    }

    /// The multi-turn prompt: transcript roles + contents, last 8 turns.
    /// Internal so tests can pin the exact formatting the engines see.
    static func transcriptPrompt(_ history: [ChatMessage]) -> String {
        history
            .suffix(8)
            .map { "\($0.role): \($0.content)" }
            .joined(separator: "\n")
    }

    /// /history command: prints everything stored so far — what the *next*
    /// prompt will include (last 8) and what's trimmed away — so context
    /// carry can be debugged by eye.
    static func printTranscript(_ history: [ChatMessage]) {
        if history.isEmpty {
            TerminalOutput.line("(history is empty)")
            return
        }
        let total = history.count
        let trimmedAway = max(0, total - 8)
        TerminalOutput.line("── transcript (\(total) message\(total == 1 ? "" : "s"), next prompt sends the last \(min(total, 8))) ──")
        for (index, message) in history.enumerated() {
            let marker = index >= trimmedAway ? " " : "·"  // · = trimmed from the next prompt
            TerminalOutput.line("\(marker) [\(index + 1)] \(message.role):")
            for contentLine in message.content.split(separator: "\n", omittingEmptySubsequences: true) {
                TerminalOutput.line("\(marker)     \(contentLine)")
            }
        }
        if trimmedAway > 0 {
            TerminalOutput.line("   (· = \(trimmedAway) older message\(trimmedAway == 1 ? "" : "s") will NOT be sent with the next prompt)")
        }
        TerminalOutput.line("── end ──")
    }
}

// MARK: - serve

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a local OpenAI-compatible HTTP server backed by Apple Intelligence."
    )

    @Option(name: .shortAndLong, help: "Port to listen on.")
    var port: Int = 11_434

    mutating func run() async throws {
        let server = OpenAIServer(port: port, engine: AppIntelligenceEngine())
        try await server.run()
    }
}

// MARK: - status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Diagnose engine availability and permissions."
    )

    mutating func run() async throws {
        TerminalOutput.line("system: \(HostInfo.summary)")
        let apple = await AppIntelligenceEngine().availability
        TerminalOutput.line("apple:  \(apple.ready ? "OK" : "UNAVAILABLE") — \(apple.detail)")
        // Repo-grounded answers are budgeted against this window
        // (ContextBuilder); show the machine's real value, not a hardcoded
        // spec — macOS 26 reports 4,096, macOS 27/newer hardware 8,192.
        let window = AppIntelligenceEngine.modelContextSize()
        TerminalOutput.line("window: \(window) tokens for repo-grounded context")
        let siri = await SiriAXEngine().availability
        TerminalOutput.line("siri:   \(siri.ready ? "OK" : "UNAVAILABLE") — \(siri.detail)")
        if apple.ready || siri.ready {
            TerminalOutput.line("")
            TerminalOutput.line("All good. Try: siri-ai ask \"explain this repo\" --repo .")
        }
    }
}

// MARK: - factory

enum EngineFactory {
    static func make(backend: String) -> LLMEngine {
        switch parse(backend) {
        case .siri: return SiriAXEngine()
        case .apple: return AppIntelligenceEngine()
        }
    }

    /// Permissive CLI string → typed `Backend`. Unknown names default to
    /// `.apple` (matches the server's model routing and old behavior).
    static func parse(_ raw: String) -> Backend {
        switch raw.lowercased() {
        case "siri", "siriai": return .siri
        default: return .apple
        }
    }
}
