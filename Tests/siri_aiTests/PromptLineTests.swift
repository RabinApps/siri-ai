import Testing
import Foundation
@testable import siri_ai
@testable import SiriAILib

@Suite("Prompt line formatting")
struct PromptLineTests {
    @Test func firstTurnHasNoLatency() {
        #expect(Chat.promptLine(turn: 0, lastLatencyMs: nil) == "[turn 0] > ")
    }

    @Test func laterTurnShowsCounterAndLastLatency() {
        let line = Chat.promptLine(turn: 3, lastLatencyMs: 1234.6)
        #expect(line == "[turn 3 · last 1235ms] > ")
    }

    @Test func subMillisecondLatencyRoundsToZero() {
        #expect(Chat.promptLine(turn: 1, lastLatencyMs: 0.2) == "[turn 1 · last 0ms] > ")
    }}
