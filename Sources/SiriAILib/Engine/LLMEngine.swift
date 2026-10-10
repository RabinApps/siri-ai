import Foundation

/// Abstracts which AI backend answers a prompt: Apple Intelligence (default)
/// or the real Siri AI app via Accessibility.
public protocol LLMEngine: Sendable {
    /// Non-streaming request. Returns the complete response text.
    func respond(_ request: EngineRequest) async throws -> AgentResponse

    /// Streaming request, yielding text deltas as they are produced.
    /// Not every backend streams; engines that cannot stream emit a single
    /// final delta and set `streamed: false`.
    func stream(_ request: EngineRequest) -> AsyncThrowingStream<String, Error>

    /// Human-readable availability diagnostics for the `status` command.
    var availability: AvailabilityReport { get async }
}

public struct EngineRequest: Sendable {
    public var system: String?
    public var prompt: String
    public var temperature: Double?
    public var maxTokens: Int?
    /// Optional tool layer the engine consults before answering.
    public var toolLayer: ToolLayer?
    /// Hint whether the caller is prepared to consume a stream. Engines that
    /// cannot stream honor `respond`/`stream` semantics regardless; this is
    /// informational and the CLI uses it to pick its display path.
    public var stream: Bool = true

    public init(system: String? = nil, prompt: String, temperature: Double? = nil, maxTokens: Int? = nil, toolLayer: ToolLayer? = nil, stream: Bool = true) {
        self.system = system
        self.prompt = prompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.toolLayer = toolLayer
        self.stream = stream
    }
}

public struct AvailabilityReport: Sendable {
    public let backend: Backend
    public let ready: Bool
    public let detail: String

    public init(backend: Backend, ready: Bool, detail: String) {
        self.backend = backend
        self.ready = ready
        self.detail = detail
    }
}
