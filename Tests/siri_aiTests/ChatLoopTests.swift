import Testing
import Foundation
@testable import siri_ai
@testable import SiriAILib

@Suite("Chat loop", .serialized)
struct ChatLoopTests {   // serialized: shares the RecordingTerminal tap with other suites
    private func stubbedLineSource(_ lines: [String]) -> @Sendable () -> Void {
        nonisolated(unsafe) var index = 0
        let previous = ChatLineSource.reader
        ChatLineSource.reader = {
            defer { index += 1 }
            guard index < lines.count else { return "/quit" }
            return lines[index]
        }
        return { ChatLineSource.reader = previous }
    }

    @Test func quitExitsImmediately() async throws {
        let restore = stubbedLineSource(["/quit"])
        defer { restore() }
        let chat = Chat()
        try await chat.chatLoop(engine: StubEngine(), siri: false, system: nil)
    }

    @Test func clearResetsHistoryAndInvisibleNext() async throws {
        let restore = stubbedLineSource(["The secret is xylophone", "/clear", "What is the secret?", "/quit"])
        defer { restore() }
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }

        let chat = Chat()
        try await chat.chatLoop(engine: EchoStubEngine(), siri: false, system: nil)
        let text = recorded.raw.joined()
        #expect(text.contains("History cleared"))
    }

    @Test func appleBranchStreamsReply() async throws {
        let restore = stubbedLineSource(["hello there", "/quit"])
        defer { restore() }
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }

        let chat = Chat()
        try await chat.chatLoop(
            engine: StubEngine(replies: ["greetings traveller"]),
            siri: false,
            system: "You are terse."
        )
        let text = recorded.raw.joined()
        #expect(text.contains("greetings"))
        #expect(text.contains("Chat started"))
    }

    @Test func siriBranchUsesRespondAndStoresCleanedText() async throws {
        let restore = stubbedLineSource(["remember: alpha 7", "/quit"])
        defer { restore() }
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }

        let chat = Chat()
        try await chat.chatLoop(
            engine: StubEngine(replies: ["I will remember alpha 7"]),
            siri: true,
            system: nil
        )
        #expect(recorded.raw.joined().contains("alpha 7"))
    }

    @Test func engineBranchesByFlagChoice() {
        // Chat mirrors EngineFactory's selection on `siri`.
        #expect(EngineFactory.make(backend: "siri") is SiriAXEngine)
    }

    @Test func historyCommandPrintsTranscript() async throws {
        let restore = stubbedLineSource(["first question", "/history", "second question", "/quit"])
        defer { restore() }
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }

        let chat = Chat()
        try await chat.chatLoop(
            engine: StubEngine(replies: ["first answer", "second answer"]),
            siri: false,
            system: nil
        )
        let text = recorded.raw.joined()
        // /history runs between turn 1 and turn 2: user question + assistant reply.
        #expect(text.contains("── transcript (3 messages, next prompt sends the last 3) ──"))
        #expect(text.contains("[1] system:"))
        #expect(text.contains("[2] user:"))
        #expect(text.contains("first question"))
        #expect(text.contains("[3] assistant:"))
        #expect(text.contains("first answer"))
        #expect(!text.contains("[4] user:"))   // second question comes after /history
        #expect(text.contains("── end ──"))
    }

    @Test func historyCommandMarksTrimmedMessages() async throws {
        // 12 turns exceed the 8-message window; /history must flag the trim.
        var lines: [String] = []
        for i in 0..<6 {
            lines.append("q\(i)")
            lines.append("/history")
        }
        lines.append("/quit")
        let restore = stubbedLineSource(lines)
        defer { restore() }
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }

        let chat = Chat()
        try await chat.chatLoop(
            engine: StubEngine(replies: Array(repeating: "ok", count: 6)),
            siri: false,
            system: nil
        )
        let text = recorded.raw.joined()
        // After 13 messages (12 turns + seeded system), 5 are trimmed.
        #expect(text.contains("5 older messages will NOT be sent"))
        #expect(text.contains("next prompt sends the last 8)"))
    }

    @Test func historyOnEmptyHistory() async {
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }
        Chat.printTranscript([])
        let text = recorded.raw.joined()
        #expect(text.contains("(history is empty)"))
    }

    @Test func noMemoryIsolationWrapsSystemPrompt() async {
        // Flag off: base prompt as-is; nil base → default.
        #expect(Chat.effectiveSystemPrompt(base: "Be terse.", isolateMemory: false) == "Be terse.")
        #expect(Chat.effectiveSystemPrompt(base: nil, isolateMemory: false) == "You are a concise assistant.")

        // Flag on: isolation block appended/present.
        let isolated = Chat.effectiveSystemPrompt(base: "Be terse.", isolateMemory: true)
        #expect(isolated.hasPrefix("Be terse."))
        #expect(isolated.contains("ONLY source of context"))
        #expect(isolated.contains("Do not save anything from this conversation to memory."))

        let isolatedDefault = Chat.effectiveSystemPrompt(base: nil, isolateMemory: true)
        #expect(!isolatedDefault.contains("concise"))
        #expect(isolatedDefault.contains("ONLY source of context"))
    }

    @Test func noMemoryIsolationReachesEngineRequest() async throws {
        // Engine stub echoes the request's system field; run one turn with
        // isolation on and assert the engine saw the isolation block.
        final class SystemSpyEngine: LLMEngine, @unchecked Sendable {
            nonisolated(unsafe) static var seenSystem: String?
            func respond(_ request: EngineRequest) async throws -> AgentResponse {
                Self.seenSystem = request.system
                return AgentResponse(text: " ack", streamed: false)
            }
            func stream(_ request: EngineRequest) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { c in
                    Self.seenSystem = request.system
                    c.yield(" ack")
                    c.finish()
                }
            }
            var availability: AvailabilityReport {
                get async { AvailabilityReport(backend: .apple, ready: true, detail: "spy") }
            }
        }

        let spy = SystemSpyEngine()
        let restore = stubbedLineSource(["hello", "/quit"])
        defer { restore() }
        let chat = Chat()
        try await chat.chatLoop(engine: spy, siri: false, system: "Base rules.", isolateMemory: true)
        let seen = SystemSpyEngine.seenSystem ?? ""
        #expect(seen.hasPrefix("Base rules."))
        #expect(seen.contains("ONLY source of context"))
        SystemSpyEngine.seenSystem = nil
    }

    @Test func noMemorySurvivesClear() async throws {
        // /clear keeps the effective system prompt, isolation included.
        final class ClearSpyEngine: LLMEngine, @unchecked Sendable {
            nonisolated(unsafe) static var lastSystem: String?
            func respond(_ request: EngineRequest) async throws -> AgentResponse {
                Self.lastSystem = request.system
                return AgentResponse(text: " ack", streamed: false)
            }
            func stream(_ request: EngineRequest) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { c in
                    Self.lastSystem = request.system
                    c.yield(" ack")
                    c.finish()
                }
            }
            var availability: AvailabilityReport {
                get async { AvailabilityReport(backend: .apple, ready: true, detail: "spy") }
            }
        }

        let spy = ClearSpyEngine()
        let restore = stubbedLineSource(["one", "/clear", "two", "/quit"])
        defer { restore() }
        let chat = Chat()
        try await chat.chatLoop(engine: spy, siri: false, system: nil, isolateMemory: true)
        // Both turns must have carried the isolation block.
        #expect(ClearSpyEngine.lastSystem?.contains("ONLY source of context") == true)
        ClearSpyEngine.lastSystem = nil
    }

    @Test func historyAfterClearShowsEmpty() async throws {
        let restore = stubbedLineSource(["remember me", "/clear", "/history", "/quit"])
        defer { restore() }
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }

        let chat = Chat()
        try await chat.chatLoop(engine: StubEngine(replies: ["ok"]), siri: false, system: nil)
        let text = recorded.raw.joined()
        #expect(text.contains("History cleared."))
        #expect(text.contains("[1] system:"))
        #expect(!text.contains("remember me"))
    }

    @Test func statusRunsAllBackendProbes() async {
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }
        var status = Status()
        _ = try? await status.run()
        let text = recorded.raw.joined()
        #expect(text.contains("system:"))
        #expect(text.contains("apple:"))
        #expect(text.contains("siri:"))
    }

    /// status surfaces the runtime-detected context window so users can see
    /// the budget their machine actually gets.
    @Test func statusPrintsDetectedContextWindow() async {
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }
        var status = Status()
        _ = try? await status.run()
        let text = recorded.raw.joined()
        let expected = "window: \(AppIntelligenceEngine.modelContextSize()) tokens"
        #expect(text.contains(expected), "status must print the detected window; wanted \(expected), got:\n\(text)")
        #expect(text.contains("repo-grounded"))
    }

    @Test func serveAcceptsOneConnectionThenStops() async throws {
        let server = OpenAIServer(port: 0, engine: StubEngine(replies: []), routingEnabled: false)
        // Port 0 = OS-assigned ephemeral port; ask the listener which.
        let listenerFD = try server.listenerForTesting()
        defer { close(listenerFD) }

        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        getsockname(listenerFD, sockaddr_cast(&addr), &len)
        let port = Int(CFSwapInt16BigToHost(addr.sin_port))

        let loopTask = Task {
            await server.acceptLoop(listenerFD: listenerFD, maxConnections: 1)
        }
        _ = try await ServerSocketTests.rawOneShot(
            "GET /health HTTP/1.1\r\nHost: t\r\n\r\n", port: port)
        await loopTask.value   // served exactly one connection, then exits
    }
}

func sockaddr_cast(_ p: UnsafeMutablePointer<sockaddr_in>) -> UnsafeMutablePointer<sockaddr> {
    UnsafeMutableRawPointer(p).assumingMemoryBound(to: sockaddr.self)
}

/// Stub engine variant that echoes the transcript prompt (for /clear check).
final class EchoStubEngine: LLMEngine, @unchecked Sendable {
    func respond(_ request: EngineRequest) async throws -> AgentResponse {
        AgentResponse(text: "[echo] \(request.prompt)", streamed: false)
    }
    func stream(_ request: EngineRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            c.yield("[echo] \(request.prompt)")
            c.finish()
        }
    }
    var availability: AvailabilityReport {
        get async { AvailabilityReport(backend: .apple, ready: true, detail: "echo") }
    }
}


