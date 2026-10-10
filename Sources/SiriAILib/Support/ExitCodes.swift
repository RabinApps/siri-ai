import Foundation

/// Exit codes used throughout the CLI for UNIX composability.
enum AppExitCode {
    static let ok = 0
    static let failure = 1
}

/// Represents the outcome of a single engine request.
public struct AgentResponse: Sendable {
    public let text: String
    /// True if the engine consumed a stream rather than buffering everything.
    public let streamed: Bool

    public init(text: String, streamed: Bool) {
        self.text = text
        self.streamed = streamed
    }
}

/// One turn of a multi-turn conversation. Used for chat mode and the OpenAI server.
public struct ChatMessage: Codable, Sendable, Hashable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ text: String) -> ChatMessage { .init(role: "system", content: text) }
    public static func user(_ text: String) -> ChatMessage { .init(role: "user", content: text) }
    public static func assistant(_ text: String) -> ChatMessage { .init(role: "assistant", content: text) }
}

/// Which engine backend is in use.
public enum Backend: String, Codable, Sendable, CaseIterable {
    /// Apple Intelligence via the FoundationModels framework (default).
    case apple
    /// The actual Siri AI app, driven through the macOS Accessibility API.
    case siri
}
