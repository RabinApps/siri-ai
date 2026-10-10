import Foundation
import FoundationModels

/// The primary backend: Apple Intelligence via the FoundationModels framework.
///
/// The on-device model has a small context window (4,096 tokens on macOS 26,
/// 8,192 on newer hardware/OS combos) which callers must respect — see
/// `ContextBuilder` for the trimming that keeps requests inside budget.
public struct AppIntelligenceEngine: LLMEngine {
    public init() {}
    public func respond(_ request: EngineRequest) async throws -> AgentResponse {
        guard let session = try Self.makeSession(system: request.system, tools: request.toolLayer?.tools) else {
            throw EngineError.unavailable("Apple Intelligence model is not available. Run `siri-ai status`.")
        }
        let options = Self.options(for: request)
        if let layer = request.toolLayer {
            _ = layer  // tools are attached at session construction; the session invokes them
            let response = try await session.respond(to: request.prompt, options: options)
            return AgentResponse(text: response.content, streamed: false)
        }
        let response = try await session.respond(to: request.prompt, options: options)
        return AgentResponse(text: response.content, streamed: false)
    }

    public func stream(_ request: EngineRequest) -> AsyncThrowingStream<String, Error> {
        let system = request.system
        let prompt = request.prompt
        let tools = request.toolLayer?.tools
        let options = Self.options(for: request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let session = try Self.makeSession(system: system, tools: tools) else {
                        throw EngineError.unavailable("Apple Intelligence model is not available. Run `siri-ai status`.")
                    }
                    // ResponseStream elements are cumulative snapshots; diff them to deltas.
                    let snapshots = session.streamResponse(to: prompt, options: options)
                    var last = ""
                    for try await snapshot in snapshots {
                        let text = snapshot.content
                        if text.hasPrefix(last), text.count > last.count {
                            continuation.yield(String(text.dropFirst(last.count)))
                        } else if text != last {
                            // A corrected/rewritten snapshot: surface the whole thing
                            // so consumers can re-render if they want to.
                            continuation.yield(text)
                        }
                        last = text
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public var availability: AvailabilityReport {
        get async { Self.currentAvailability() }
    }

    // MARK: - Context window

    /// The on-device model's real context-window size in tokens, read from
    /// the framework at runtime (the framework itself falls back to 4,096 on
    /// macOS 26 and returns the larger true window on macOS 27/newer
    /// hardware).
    ///
    /// Callers use this for prompt budgeting (see ContextBuilder); when the
    /// model is unavailable there is no window to budget against, so fall
    /// back to ContextBuilder's documented minimum rather than throwing.
    public static func modelContextSize() -> Int {
        guard case .available = SystemLanguageModel.default.availability else {
            return ContextBuilder.minimumWindow
        }
        let size = SystemLanguageModel.default.contextSize
        return size > 0 ? size : ContextBuilder.minimumWindow
    }

    // MARK: - Session construction

    /// Internal (not private) so @testable imports can probe construction.
    static func makeSession(system: String?, tools: [any Tool]?) throws -> LanguageModelSession? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        if let system {
            let instructions = Instructions(system)
            if let tools {
                return LanguageModelSession(model: .default, tools: tools, instructions: instructions)
            }
            return LanguageModelSession(model: .default, instructions: instructions)
        }
        if let tools {
            return LanguageModelSession(model: .default, tools: tools)
        }
        return LanguageModelSession(model: .default)
    }

    /// Internal for @testable coverage.
    static func options(for request: EngineRequest) -> GenerationOptions {
        GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: request.maxTokens
        )
    }

    static func currentAvailability() -> AvailabilityReport {
        switch SystemLanguageModel.default.availability {
        case .available:
            return AvailabilityReport(backend: .apple, ready: true, detail: "Apple Intelligence on-device model available")
        case .unavailable(let reason):
            let description: String
            switch reason {
            case .deviceNotEligible: description = "This device is not eligible for Apple Intelligence."
            case .appleIntelligenceNotEnabled: description = "Apple Intelligence is not enabled (System Settings → Apple Intelligence & Siri)."
            case .modelNotReady: description = "The on-device model has not finished downloading yet."
            @unknown default: description = "Unknown unavailability reason."
            }
            return AvailabilityReport(backend: .apple, ready: false, detail: description)
        }
    }
}

/// Lock-guarded single-value slot shared between the raced children.
private final class DeadlineBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    func store(_ value: T) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Deadline guard for FoundationModels inference.
///
/// Known live failure mode (observed in the release-gate run: >7 min with
/// no model fault surfaced): a tool-attached `LanguageModelSession.respond`
/// can stall indefinitely — the framework exposes no deadline for
/// `respond`, and Task cancellation is cooperative, so a hung framework
/// call may never observe it (the same conclusion shipped in third-party
/// code hitting this exact behavior — see the changelog's limitation
/// note). Therefore this guard races the awaited call against a real
/// wall-clock deadline and *abandons* the hung call:
///
/// - operation finishes first → its value (or thrown error) is returned
///   to the caller; the timer child is cancelled.
/// - deadline fires first → `EngineError.timeout` is thrown to the caller;
///   the operation child is cancelled as a best effort (a stuck framework
///   call will typically not observe cancellation) and the struct is left
///   for the system to reap when nothing references it.
///
/// Correctness under the close race (both children finish nearly
/// simultaneously): the timer child re-reads the operation's lock-guarded
/// box after its sleep completes and prefers a stored operation result over
/// throwing the timeout, so a completed result near the wire is never
/// mislabeled as a timeout; and once either child finishes the race, the
/// first `group.next()` settles the outcome — a late timeout from the timer
/// child after a successful op can no longer surface.
public func withInferenceDeadline<T: Sendable>(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let box = DeadlineBox<T>()
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            let value = try await operation()
            box.store(value)                    // stored BEFORE winning the race
            return value
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if let finished = box.get() { return finished }   // op finished during the sleep
            throw EngineError.timeout(Int(seconds.rounded(.up)).description)
        }
        do {
            let winner = try await group.next()!
            group.cancelAll()                    // stop the loser (timer or op) promptly
            return winner
        } catch {
            // The operation child threw first (its error finished the race):
            // rethrow it — the timer never fires a reachable result once the
            // race is settled. A cancellation of the whole group is not
            // something the guard introduces itself.
            group.cancelAll()
            throw error
        }
    }
}

/// Errors surfaced by engines; mapped to stderr + exit code 1 at the CLI layer.
public enum EngineError: LocalizedError, Sendable {
    case unavailable(String)
    case backend(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "Engine unavailable: \(detail)"
        case .backend(let detail): return "Engine error: \(detail)"
        case .timeout(let detail): return "Timed out waiting for Siri after \(detail)s."
        }
    }
}
