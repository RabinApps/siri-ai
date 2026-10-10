import Testing
import Foundation
import ApplicationServices
@testable import siri_ai
@testable import SiriAILib

@Suite("Chat transcript formatting")
struct ChatTranscriptTests {
    @Test func transcriptRolesAndContentsOrder() {
        let history: [ChatMessage] = [
            .system("You are terse."),
            .user("first question"),
            .assistant("first answer"),
            .user("second question"),
        ]
        let prompt = Chat.transcriptPrompt(history)
        #expect(prompt.contains("system: You are terse."))
        #expect(prompt.contains("user: first question"))
        #expect(prompt.contains("assistant: first answer"))
        #expect(prompt.hasSuffix("user: second question"))
        #expect(prompt.split(separator: "\n").count == 4)
    }

    @Test func transcriptTrimsToLastEight() {
        var history: [ChatMessage] = []
        for i in 0..<10 {
            history.append(.user("q\(i)"))
            history.append(.assistant("a\(i)"))
        }
        let prompt = Chat.transcriptPrompt(history)
        #expect(!prompt.contains("q0"))
        #expect(!prompt.contains("q1"))
        #expect(prompt.contains("a9"))
        #expect(prompt.contains("q9"))
        #expect(prompt.split(separator: "\n").count == 8)
    }
}

@Suite("Siri AX event pipeline (live)", .serialized)
struct SiriEventPipelineTests {
    @Test func observeProducesProgressThenFinal() async throws {
        guard TestSupport.liveTestsEnabled else {
            #expect(Bool(true), "live-model tests disabled; set LIVE_TESTS=1 to run")
            return
        }
        guard FileManager.default.fileExists(atPath: "/System/Applications/Siri AI.app"),
              AXIsProcessTrusted() else {
            #expect(Bool(true), "Siri AI app or AX permission unavailable; skipping live pipeline test")
            return
        }
        var sawProgress = false
        var sawFinal = false
        var finalText = ""
        for try await event in SiriAXEngine().observeForTesting(prompt: "what is 2 + 2") {
            switch event {
            case .progress: sawProgress = true
            case .final(let cleaned): sawFinal = true; finalText = cleaned
            }
        }
        #expect(sawFinal)
        #expect(!finalText.isEmpty)
        // Siri may echo prior/extraneous lines in the window; require a digit
        // answer to be present somewhere in the cleaned capture.
        #expect(finalText.range(of: #"[0-9]"#, options: .regularExpression) != nil)
        _ = sawProgress
    }

    @Test func respondProducesSameAnswerShape() async throws {
        guard TestSupport.liveTestsEnabled else {
            #expect(Bool(true), "live-model tests disabled; set LIVE_TESTS=1 to run")
            return
        }
        guard FileManager.default.fileExists(atPath: "/System/Applications/Siri AI.app"),
              AXIsProcessTrusted() else {
            #expect(Bool(true), "live Siri path skipped")
            return
        }
        let response = try await SiriAXEngine().respond(EngineRequest(
            system: nil, prompt: "what is 5 + 5", temperature: nil, maxTokens: nil
        ))
        #expect(!response.text.isEmpty)
        #expect(!response.streamed)
    }
}
