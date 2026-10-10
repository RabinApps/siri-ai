import Foundation
import SiriAILib

// MARK: - siri-ai example app
//
// A minimal, dependency-free demo of the `siri-ai` library surface —
// runnable twins for the snippets in docs/guide/examples.md:
//
//   stream   — plain streaming ask (Apple Intelligence on-device)
//   answer   — repo-grounded streaming answer (RepoScanner + ContextBuilder)
//   agentic  — let the model pick files via list/read/search tools
//   chat     — multi-turn ChatMessage transcript loop
//   decide   — FastDecisions typed "System 1" routing verdict
//   backend  — swap engines via the Backend enum + availability reports
//   status   — engine availability probe
//
// Run from the package root:
//   swift run Example stream "Explain async/await in two sentences"
//   swift run Example answer --repo . "Where is the OpenAI server implemented?"
//   swift run Example agentic --repo . "Which engine streams deltas the fastest?"
//   swift run Example chat "What is a task group?"
//   swift run Example decide "fix the retry loop"

@main
struct ExampleApp {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first else {
            print(usage)
            exit(1)
        }
        do {
            switch mode {
            case "stream":
                try await runStream(query: args.dropFirst().joined(separator: " "))
            case "answer":
                try await runAnswer(args: Array(args.dropFirst()))
            case "agentic":
                try await runAgentic(args: Array(args.dropFirst()))
            case "chat":
                try await runChat(args: Array(args.dropFirst()))
            case "decide":
                try await runDecide(query: args.dropFirst().joined(separator: " "))
            case "backend":
                try await runBackend(args: Array(args.dropFirst()))
            case "status":
                await runStatus()
            default:
                print(usage)
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data("example: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: stream — plain streaming

    static func runStream(query: String) async throws {
        let engine = AppIntelligenceEngine()
        let request = EngineRequest(
            system: "You are a concise assistant.",
            prompt: query
        )
        var streamed = 0
        for try await delta in engine.stream(request) {
            print(delta, terminator: "")
            fflush(stdout)
            streamed += 1
        }
        print("\n[\(streamed) deltas]")
    }

    // MARK: answer — repo-grounded context stuffing

    static func runAnswer(args: [String]) async throws {
        let parsed = parseRepoArgs(args)
        let root = parsed.repo ?? FileManager.default.currentDirectoryPath
        let question = parsed.query
        guard !question.isEmpty else {
            FileHandle.standardError.write(Data("usage: answer --repo <path> \"question\"\n".utf8))
            exit(1)
        }

        // 1. Discover candidate files.
        let files = try RepoScanner(root: root).scan()

        // 2. Token-budget a subset for the on-device model's window.
        let window = AppIntelligenceEngine.modelContextSize()
        let context = ContextBuilder(modelContextSize: window).build(files: files, question: question)

        FileHandle.standardError.write(
            Data("[context] \(context.includedFiles.joined(separator: ", "))\n".utf8))

        // 3. Stream the grounded answer.
        let prompt = """
        ### Context from repository at \(root):
        \(context.contextText)

        ### Question:
        \(question)

        Answer concisely, citing file paths.
        """
        let engine = AppIntelligenceEngine()
        let request = EngineRequest(
            system: "You are a precise, concise coding assistant.",
            prompt: prompt
        )
        for try await delta in engine.stream(request) {
            print(delta, terminator: "")
            fflush(stdout)
        }
        print()
    }

    // MARK: agentic — model-driven tool use

    static func runAgentic(args: [String]) async throws {
        let parsed = parseRepoArgs(args)
        let root = parsed.repo ?? FileManager.default.currentDirectoryPath
        let question = parsed.query
        guard !question.isEmpty else {
            FileHandle.standardError.write(Data("usage: agentic --repo <path> \"question\"\n".utf8))
            exit(1)
        }

        // ToolLayer is a @MainActor type: construct (and read its transcript)
        // on the main actor. allowEdits: false → read-only tools only.
        let layer = await MainActor.run {
            ToolLayer(root: root, allowEdits: false, confirmEdits: false)
        }
        let engine = AppIntelligenceEngine()
        let request = EngineRequest(
            system: """
            You are a coding assistant helping with the repository at \(root).
            Use the provided tools (list_files, read_file, search_files) to inspect
            code before answering. Cite file paths in your answer.
            """,
            prompt: question,
            toolLayer: layer
        )
        let response = try await engine.respond(request)

        let used = await layer.invokedTools
        if !used.isEmpty {
            FileHandle.standardError.write(
                Data("[tools] \(used.joined(separator: ", "))\n".utf8))
        }
        print(response.text)
    }

    // MARK: chat — multi-turn transcript loop (mirrors the cookbook's
    // "Multi-turn chat" snippet: ChatMessage history folded into one prompt)

    static func runChat(args: [String]) async throws {
        var history: [ChatMessage] = [.system("You are a terse assistant.")]
        // Tiny interactive loop; `swift run Example chat` with no args
        // falls back to a canned two-turn demo so it's runnable everywhere.
        let questions = args.isEmpty
            ? ["What is a task group?", "Compare it to nested async lets."]
            : args
        let engine = AppIntelligenceEngine()
        for question in questions {
            history.append(.user(question))
            print("\u{001b}[1m>\u{001b}[0m \(question)")

            let prompt = history
                .map { "\($0.role): \($0.content)" }
                .joined(separator: "\n")
            let reply = try await engine.respond(EngineRequest(
                system: history.first?.content, prompt: prompt
            ))
            history.append(.assistant(reply.text))
            print(reply.text)
        }
        print("\n[\(history.count - 1) turns in transcript]")
    }

    // MARK: decide — the System 1 typed routing verdict (cookbook:
    // "Fast typed decisions" — FastDecisions.route with fallback contract)

    static func runDecide(query: String) async throws {
        let q = query.isEmpty ? "fix the retry loop in the server" : query
        let decision = await FastDecisions.route(query: q, backend: .apple)
        print("query:       \(q)")
        print("needsTools:  \(decision.needsTools)")
        print("needsContext:\(decision.needsContext)")
        print("isEdit:      \(decision.isEditRequest)")
    }

    // MARK: backend — swap engines via the Backend enum (cookbook:
    // "Choosing a backend with the enum")

    static func runBackend(args: [String]) async throws {
        let selection: Backend = (args.first == "siri") ? .siri : .apple
        // Same protocol, drop-in swap — availability gates usefully here.
        let engine: LLMEngine = (selection == .siri) ? SiriAXEngine() : AppIntelligenceEngine()
        let report = await engine.availability
        print("backend: \(report.backend.rawValue) (requested: \(selection.rawValue))")
        print(report.ready ? "ready" : "unavailable: \(report.detail)")
    }

    // MARK: status — availability probe

    static func runStatus() async {
        print(HostInfo.summary)
        let apple = await AppIntelligenceEngine().availability
        print("apple:  \(apple.ready ? "OK" : "UNAVAILABLE") — \(apple.detail)")
    }

    // MARK: tiny arg parsing (--repo <path>, rest = query)

    struct ParsedArgs {
        var repo: String?
        var query: String
    }

    static func parseRepoArgs(_ args: [String]) -> ParsedArgs {
        var repo: String?
        var rest: [String] = []
        var iter = args.makeIterator()
        while let arg = iter.next() {
            if arg == "--repo" {
                repo = iter.next()
            } else if arg.hasPrefix("--repo=") {
                repo = String(arg.dropFirst("--repo=".count))
            } else {
                rest.append(arg)
            }
        }
        return ParsedArgs(repo: repo?.replaceTilde, query: rest.joined(separator: " "))
    }

    static let usage = """
    siri-ai example app

    USAGE: Example <mode> [--repo <path>] "question"

    MODES:
      stream   "…"   Stream a plain answer delta by delta.
      answer   --repo <path> "…"   Repo-grounded streaming answer.
      agentic  --repo <path> "…"   Model drives file tools (read-only).
      chat     [q1 q2 …]   Multi-turn ChatMessage transcript loop.
      decide   "…"   Print the FastDecisions routing verdict.
      backend  [apple|siri]   Swap engines via the Backend enum.
      status         Print backend availability.
    """
}
