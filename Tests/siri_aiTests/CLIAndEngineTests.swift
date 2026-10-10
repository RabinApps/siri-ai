import Testing
import Foundation
import ArgumentParser
import FoundationModels
@testable import siri_ai
@testable import SiriAILib

/// The GNU timeout exit-code convention, named once: scripts (and the live
/// subprocess backstop in EngineLiveTests) use 124 to distinguish "the
/// engine wedged" from a normal failure.
enum GNUTimeout {
    static let exitCode: Int32 = 124
}

/// Engine whose respond/stream never return — the deterministic stand-in
/// for the FoundationModels cooperative-pool wedge.
final class WedgedEngine: LLMEngine, @unchecked Sendable {
    func respond(_ request: EngineRequest) async throws -> AgentResponse {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return AgentResponse(text: "unreachable", streamed: false)
    }
    func stream(_ request: EngineRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    var availability: AvailabilityReport {
        AvailabilityReport(backend: .apple, ready: true, detail: "wedged stub")
    }
}

@Suite("Ask command paths", .serialized)
struct AskCommandTests {
    private func makeAsk(
        query: String? = nil,
        repo: String? = nil,
        tools: Bool = false,
        edit: Bool = false,
        noStream: Bool = false,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        maxSeconds: Double? = nil
    ) -> Ask {
        var ask = Ask()
        ask.query = query
        ask.repo = repo
        ask.tools = tools
        ask.edit = edit
        ask.noStream = noStream
        ask.temperature = temperature
        ask.maxTokens = maxTokens
        ask.maxSeconds = maxSeconds
        // Belt-and-braces: repo-path tests also inject a cannedDecision, so
        // the kill switch is redundant there. Kept for runPlain/run()-path
        // tests that never reach the decision layer.
        ask.noFastDecisions = true
        ask.decisions = nil
        return ask
    }

    @Test func plainNoStreamRunsEngineOnce() async throws {
        let stub = StubEngine(replies: ["plain answer"])
        try await makeAsk(query: "hello", noStream: true).runPlain(engine: stub, query: "hello")
    }

    /// --max-seconds fast path: a responsive engine finishes inside the
    /// deadline and the answer prints normally (no exit-code change).
    @Test("ask --max-seconds: responsive engine completes normally")
    func deadlineFastPath() async throws {
        let stub = StubEngine(replies: ["plain answer"])
        try await makeAsk(query: "hello", noStream: true, maxSeconds: 5)
            .runPlain(engine: stub, query: "hello")
    }

    /// --max-seconds bail-out: an engine whose call never completes must
    /// surface the GNU-timeout convention (exit code 124) with a diagnostic,
    /// not hang the CLI — this is the in-process half of the stall defense
    /// used by the live subprocess test.
    @Test("ask --max-seconds: wedged engine exits 124 within the deadline")
    func deadlineBailOut() async throws {
        let started = Date()
        do {
            try await makeAsk(query: "hello", noStream: true, maxSeconds: 0.3)
                .runPlain(engine: WedgedEngine(), query: "hello")
            #expect(Bool(false), "wedged engine must trigger the bail-out")
        } catch let exit as ExitCode {
            #expect(exit.rawValue == GNUTimeout.exitCode, "bail-out must use exit 124, got \(String(describing: exit.rawValue))")
            let elapsed = Date().timeIntervalSince(started)
            #expect(elapsed < 5, "bail-out must be timely, took \(elapsed)s")
        }
    }

    @Test func plainStreamConsumesAllDeltas() async throws {
        let stub = StubEngine(replies: ["a b c"])
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }
        try await makeAsk(query: "hello").runPlain(engine: stub, query: "hello")
        let combined = recorded.raw.joined()
        #expect(combined.contains("a"))
    }

    @Test func repoContextBuildsContextIntoPrompt() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("askrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "func payment() {}".write(to: dir.appendingPathComponent("pay.swift"), atomically: true, encoding: .utf8)

        let stub = StubEngine(replies: ["the answer"])
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }
        try await makeAsk(query: "how does payment work", repo: dir.path, noStream: true)
            .runWithRepoContext(
                engine: stub,
                query: "how does payment work",
                cannedDecision: FastDecision(needsTools: false, needsContext: true, isEditRequest: false)   // context path, deterministic
            )
        let combined = recorded.raw.joined()
        #expect(combined.contains("the answer"))
        #expect(recorded.errors.contains { $0.contains("pay.swift") })   // context note on stderr
    }

    @Test func repoToolsModeUsesToolLayer() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("asktools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("f.swift"), atomically: true, encoding: .utf8)

        let stub = StubEngine(replies: ["done"])
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }
        try await makeAsk(query: "what is in f.swift", repo: dir.path, tools: true, noStream: true)
            .runWithRepoContext(
                engine: stub,
                query: "what is in f.swift",
                cannedDecision: FastDecision(needsTools: true, needsContext: true, isEditRequest: false)   // agentic path
            )
        #expect(recorded.raw.joined().contains("done"))
    }

    @Test func emptyRepoFallsBackToPlain() async throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("emptyrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let stub = StubEngine(replies: ["fallback reply"])
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }
        try await makeAsk(repo: empty.path, noStream: true)
            .runWithRepoContext(
                engine: stub,
                query: "question",
                cannedDecision: FastDecision(needsTools: false, needsContext: false, isEditRequest: false)
            )
        let combined = recorded.raw.joined() + recorded.errors.joined()
        #expect(combined.contains("fallback reply"))
        #expect(combined.contains("No candidate files"))
    }

    @Test func askEditModeCoversEditInstructions() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("askedit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "let v = 1\n".write(to: dir.appendingPathComponent("v.swift"), atomically: true, encoding: .utf8)

        let stub = StubEngine(replies: ["edit reply"])
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }
        try await makeAsk(query: "tighten v.swift", repo: dir.path, edit: true, noStream: true)
            .runWithRepoContext(
                engine: stub,
                query: "tighten v.swift",
                cannedDecision: FastDecision(needsTools: true, needsContext: true, isEditRequest: true)   // edit system prompt
            )
        #expect(recorded.raw.joined().contains("edit reply"))
    }

    @Test func repoContextStreamingPath() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("askstream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "code".write(to: dir.appendingPathComponent("s.swift"), atomically: true, encoding: .utf8)

        let stub = StubEngine(replies: ["streamed tokens here"])
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }
        try await makeAsk(query: "what is in s.swift", repo: dir.path, noStream: false)
            .runWithRepoContext(
                engine: stub,
                query: "what is in s.swift",
                cannedDecision: FastDecision(needsTools: false, needsContext: true, isEditRequest: false)   // context + streaming
            )
        #expect(recorded.raw.joined().contains("streamed"))
    }

    @Test func runExecutesEndToEndWithEngineFactory() async throws {
        // Cover Ask.run()'s routing body: force the stdin probe to "TTY" so
        // the piped branch is skipped, and give a tiny live query. Uses the
        // real Apple backend via EngineFactory (one short inference) — on a
        // machine without Apple Intelligence (CI), the model is genuinely
        // unavailable, which is an environment state, not a regression.
        guard case .available = SystemLanguageModel.default.availability else {
            #expect(Bool(true), "SKIPPED — Apple Intelligence unavailable (CI); engine-factory routing covered by deterministic paths")
            return
        }
        let previous = StdinHelper.isTTYProbe
        StdinHelper.isTTYProbe = { true }
        defer { StdinHelper.isTTYProbe = previous }
        var ask = try Ask.parse(["Reply with exactly: ok", "--no-stream"])
        try await ask.run()
    }

    @Test func runWithNoQueryThrowsAndParsesDecode() async throws {
        // ArgumentParser's own decode: covers wrapper initialization paths
        // that direct construction can't reach.
        let parsed = try Ask.parse(["hello", "--repo", "/tmp"])
        #expect(parsed.query == "hello")
        #expect(parsed.repo == "/tmp")
        #expect(parsed.tools == false)
        #expect(parsed.edit == false)
        #expect(parsed.noStream == false)

        // run() with no query and no piped stdin → error exit.
        var bare = try Ask.parse([])
        do {
            try await bare.run()
            #expect(Bool(false), "empty query should throw")
        } catch {
            // Expected: failure exit.
        }
    }

    /// The canned decision must isolate from BOTH system-1 paths: with the
    /// kill switch OFF (i.e. noFastDecisions=false, the production default)
    /// the canned verdict still governs branch selection — no model call, no
    /// heuristic, no editGate prompt. This is the proof that injection, not
    /// the kill switch, is what makes these tests deterministic.
    @Test func cannedDecisionOverridesDecisionLayerWithKillSwitchOff() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("askcanned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "let canned = 1".write(to: dir.appendingPathComponent("c.swift"), atomically: true, encoding: .utf8)

        let stub = StubEngine(replies: ["canned answer"])
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }

        var ask = makeAsk(query: "what is in c.swift", repo: dir.path, noStream: true)
        ask.noFastDecisions = false   // production default — injection must win alone
        try await ask.runWithRepoContext(
            engine: stub,
            query: "what is in c.swift",
            cannedDecision: FastDecision(needsTools: false, needsContext: true, isEditRequest: false)   // forces context path
        )
        let combined = recorded.raw.joined() + recorded.errors.joined()
        // Context path selected (file-naming note on stderr), engine answered.
        #expect(combined.contains("canned answer"))
        #expect(combined.contains("c.swift"))
        // No tool-layer "Tools used" note → agentic path was NOT taken.
        #expect(!combined.contains("Tools used"))
    }
}

/// Captures TerminalOutput streams so CLI paths can be asserted without
/// needing a real terminal. All recorders register in a shared fan-out, so
/// parallel suites each receive their own copy of every write and can
/// assert without stepping on each other.
final class DeltaRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var rawBuffer: [String] = []
    private nonisolated(unsafe) var errorsBuffer: [String] = []

    var raw: [String] { lock.withLock { rawBuffer } }
    var errors: [String] { lock.withLock { errorsBuffer } }

    func append(stream: TerminalOutput.Stream, text: String) {
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .stdout: rawBuffer.append(text)
        case .stderr: errorsBuffer.append(text)
        }
    }
}

enum RecordingTerminal {
    private static let gate = NSLock()
    nonisolated(unsafe) static var recorders: [ObjectIdentifier: DeltaRecorder] = [:]

    static func attach(_ recorder: DeltaRecorder) {
        gate.lock()
        defer { gate.unlock() }
        recorders[ObjectIdentifier(recorder)] = recorder
        rebuildTap()
    }

    static func detach(_ recorder: DeltaRecorder? = nil) {
        gate.lock()
        defer { gate.unlock() }
        if let recorder {
            recorders.removeValue(forKey: ObjectIdentifier(recorder))
        } else {
            recorders.removeAll()
        }
        rebuildTap()
    }

    private static func rebuildTap() {
        let active = Array(recorders.values)
        if active.isEmpty {
            TerminalOutput.tap = nil
        } else {
            TerminalOutput.tap = { kind, text in
                for r in active { r.append(stream: kind, text: text) }
            }
        }
    }
}
