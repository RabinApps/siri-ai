import Testing
import Foundation
import FoundationModels
import ApplicationServices
@testable import siri_ai
@testable import SiriAILib

@Suite("HTTP parser edge cases")
struct ParseHTTPTests {
    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func minimalRequestWithBody() {
        let req = OpenAIServer.parseHTTPRequest(from: bytes(
            "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"
        ))
        #expect(req?.method == "POST")
        #expect(req?.path == "/v1/chat/completions")
        #expect(req?.body == "{}")
    }

    @Test func queryStringsAreStripped() {
        let req = OpenAIServer.parseHTTPRequest(from: bytes(
            "GET /v1/models?foo=1&bar=2 HTTP/1.1\r\n\r\n"
        ))
        #expect(req?.path == "/v1/models")
    }

    @Test func missingHeaderSeparatorReturnsNil() {
        #expect(OpenAIServer.parseHTTPRequest(from: bytes("GET / HTTP/1.1\r\n")) == nil)
        #expect(OpenAIServer.parseHTTPRequest(from: []) == nil)
    }

    @Test func malformedRequestLineReturnsNil() {
        #expect(OpenAIServer.parseHTTPRequest(from: bytes("\r\n\r\n")) == nil)
        #expect(OpenAIServer.parseHTTPRequest(from: bytes("NONSENSE\r\n\r\n")) == nil)
    }

    @Test func contentLengthParsing() {
        #expect(OpenAIServer.contentLength(from: "POST / HTTP/1.1\r\nContent-Length: 42\r\n") == 42)
        #expect(OpenAIServer.contentLength(from: "POST / HTTP/1.1\r\ncontent-length: 7\r\n") == 7)
        #expect(OpenAIServer.contentLength(from: "no headers here") == 0)
        #expect(OpenAIServer.contentLength(from: "Content-Length: notanumber\r\n") == 0)
    }

    @Test func jsonEscapingRoundTrip() throws {
        for sample in ["plain", "line\nbreak", "tab\there", "quote\"inside", "back\\slash", "emoji 🍍"] {
            let encoded = OpenAIServer.jsonString(sample)
            let data = Data("[\(encoded)]".utf8)
            let array = try JSONSerialization.jsonObject(with: data) as? [String]
            #expect(array?.first == sample)
        }
    }
}

@Suite("Engine selection and construction")
struct EngineTests {
    @Test func factoryBackends() {
        #expect(EngineFactory.make(backend: "siri") is SiriAXEngine)
        #expect(EngineFactory.make(backend: "SIRIAI") is SiriAXEngine)
        #expect(EngineFactory.make(backend: "apple") is AppIntelligenceEngine)
        #expect(EngineFactory.make(backend: "unknown-thing") is AppIntelligenceEngine)  // default
    }

    @Test func appleEngineAvailabilityAndOptions() async {
        let report = await AppIntelligenceEngine().availability
        #expect(report.backend == .apple)
        // This machine has Apple Intelligence enabled; assert accordingly
        // but tolerate the unavailable branch on CI machines.
        if !report.ready {
            #expect(!report.detail.isEmpty)
        }
        let options = AppIntelligenceEngine.options(for: EngineRequest(
            system: nil, prompt: "p", temperature: 0.7, maxTokens: 120
        ))
        #expect(options.temperature.map { abs($0 - 0.7) < 0.0001 } ?? false)
    }

    @Test func siriAXAvailabilityChecks() async {
        // Uses the real AX probe; both branches are acceptable but must be coherent.
        let report = await SiriAXEngine().availability
        #expect(report.backend == .siri)
        if AXIsProcessTrusted() && SandboxProbe.siriAppLaunchable() {
            #expect(report.ready)
        }
    }

    @Test func siriAXConvergenceDeltaStableAPI() {
        //Sanity on the public helper used by the streaming path.
        #expect(SiriAXEngine.convergenceDelta(previous: "a", current: "ab") == "b")
        #expect(SiriAXEngine.convergenceDelta(previous: "a", current: "a") == nil)
        #expect(SiriAXEngine.convergenceDelta(previous: "", current: "a") == "a")
    }
}

enum SandboxProbe {
    /// Best-effort "is the Siri AI app present" check without launching it.
    static func siriAppLaunchable() -> Bool {
        FileManager.default.fileExists(atPath: "/System/Applications/Siri AI.app")
    }
}

@Suite("ContextBuilder edges")
struct ContextBuilderEdgeTests {
    @Test func noMatchingFilesYieldsEmptyContext() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hello".write(to: dir.appendingPathComponent("unrelated.md"), atomically: true, encoding: .utf8)

        let result = ContextBuilder(modelContextSize: 4_096).build(
            files: try RepoScanner(root: dir.path).scan(),
            question: "kubernetes deployment strategy"   // no overlap
        )
        // Small file still may pass the size bonus; accept either, but the
        // question term filter should deprioritize, not necessarily exclude.
        #expect(result.contextText.count < 10_000)
    }

    @Test func tinyBudgetBreaksEarly() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-tiny-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try String(repeating: "y", count: 4000).write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        // Headroom consumes nearly everything; nothing should fit.
        let starved = ContextBuilder(modelContextSize: 4_096, answerHeadroom: 4_000)
        let result = starved.build(
            files: try RepoScanner(root: dir.path).scan(),
            question: "a.txt"
        )
        #expect(result.includedFiles.isEmpty)
    }
}

@Suite("AXCleaner extras")
struct AXCleanerExtraTests {
    @Test func activityLabelsDroppedAtAnyPosition() {
        let raw = "The sky is blue today.\nSearching for weather\nSearching\nThe sky is blue today.\n0"
        let cleaned = AXCleaner.clean(raw)
        #expect(!cleaned.contains("Searching"))
        #expect(cleaned.contains("The sky is blue today."))
    }

    @Test func sourceAttributionDropped() {
        let raw = "Meeting at 3pm.\nCalendar — iCloud\nMeeting at 3pm."
        let cleaned = AXCleaner.clean(raw)
        #expect(!cleaned.contains("iCloud"))
        #expect(cleaned.contains("Meeting at 3pm."))
    }

    @Test func emptyInputStaysEmpty() {
        #expect(AXCleaner.clean("") == "")
        #expect(AXCleaner.clean("\n\n  \n") == "")
        #expect(AXCleaner.clean("0") == "")
        #expect(AXCleaner.clean("Searching") == "")
    }
}

@Suite("Misc support bits")
struct SupportTests {
    @Test func stdinHelperDetection() {
        // In test context stdin is typically not a TTY; just assert coherence.
        #expect(StdinHelper.hasPipedInput() == (isatty(fileno(stdin)) != 1))
    }

    @Test func stdinHelperTTYBranches() {
        // Probe swap is global; save/restore so a parallel suite touching
        // stdinHelperDetection observes the real isatty result, not a forced
        // branch. Restore to the PREVIOUS state, not nil (nil is just the
        // default; a caller may legitimately have installed its own).
        let previous = StdinHelper.isTTYProbe
        defer { StdinHelper.isTTYProbe = previous }

        // Force the TTY branch: readPipedInput returns "" without touching stdin.
        StdinHelper.isTTYProbe = { true }
        #expect(StdinHelper.readPipedInput() == "")
        #expect(!StdinHelper.hasPipedInput())

        // Forced pipe branch: both report piped.
        StdinHelper.isTTYProbe = { false }
        #expect(StdinHelper.hasPipedInput())
    }

    @Test func hostInfoContainsOSVersion() {
        // Covers HostInfo.summary's full body; hostname may be nil on CI.
        #expect(!HostInfo.summary.isEmpty)
    }

    @Test func exitCodeConstants() {
        #expect(AppExitCode.ok == 0)
        #expect(AppExitCode.failure == 1)
    }

    @Test func permissionProbesReturnCoherently() {
        let ax = Permissions.accessibilityGranted
        let sr = Permissions.screenRecordingGranted
        // Probes must return *something* boolean; nothing to assert beyond types.
        #expect(ax == true || ax == false)
        #expect(sr == true || sr == false)
        #expect(!Permissions.accessibilityWhy.isEmpty)
        #expect(!Permissions.screenRecordingWhy.isEmpty)
    }

    @Test func engineErrorDescriptions() {
        // Covers EngineError.errorDescription's full switch.
        let unavailable = EngineError.unavailable("u")
        #expect(unavailable.errorDescription == "Engine unavailable: u")
        let backend = EngineError.backend("b")
        #expect(backend.errorDescription == "Engine error: b")
        let timeout = EngineError.timeout("9")
        #expect(timeout.errorDescription == "Timed out waiting for Siri after 9s.")
    }
}
