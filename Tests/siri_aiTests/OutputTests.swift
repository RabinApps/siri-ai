import Testing
import Foundation
@testable import siri_ai
@testable import SiriAILib

@Suite("TerminalOutput")
struct TerminalOutputTests {
    @Test func errorWritesToStderr() {
        // Redirect stderr to a temp file, call, restore, assert content.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stderr-\(UUID().uuidString).txt")
        guard let target = fopen(url.path, "w") else {
            Issue.record("could not open temp file")
            return
        }
        let saved = dup(STDERR_FILENO)
        dup2(fileno(target), STDERR_FILENO)
        defer {
            dup2(saved, STDERR_FILENO)
            close(saved)
            fclose(target)
            try? FileManager.default.removeItem(at: url)
        }
        TerminalOutput.error("diagnostic line")
        fflush(stderr)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(text.contains("diagnostic line"))
    }
}

@Suite("ChatMessage helpers")
struct ChatMessageTests {
    @Test func roleFactories() {
        #expect(ChatMessage.system("s").role == "system")
        #expect(ChatMessage.system("s").content == "s")
        #expect(ChatMessage.user("u").role == "user")
        #expect(ChatMessage.assistant("a").role == "assistant")
        #expect(ChatMessage.assistant("a").content == "a")
    }

    @Test func codableRoundTrip() throws {
        let message = ChatMessage.user("hello")
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded == message)
    }
}
