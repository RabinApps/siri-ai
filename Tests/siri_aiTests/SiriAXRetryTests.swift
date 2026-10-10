import Testing
import Foundation
@testable import SiriAILib

/// Deterministic coverage for the SiriAXEngine retry semantics
/// (no live Siri needed): the retry driver's transient/terminal routing,
/// the exhaust path, cancellation, and the configuration surface.
/// The live AX-folding behavior itself is covered by the LIVE_TESTS tier.
@Suite("SiriAXEngine retry semantics")
struct SiriAXRetryTests {

    // MARK: - Retry driver routing

    @Test("transient failures retry until success; retries exhausted rethrows original")
    func transientRetriesThenExhausts() async throws {
        // Exhausts after the 3 allowed attempts (retries: 2), rethrowing
        // the ORIGINAL EngineError.timeout — not the AXRetrySignal wrapper.
        var attempts = 0
        do {
            _ = try await SiriAXEngine.driveAXWithTimeoutRetries(retries: 2) { index in
                attempts += 1
                #expect(index == attempts - 1, "attempt index must be 0-based and monotonic")
                throw SiriAXEngine.AXRetrySignal.transient(EngineError.timeout("7"))
            } as Int
            #expect(Bool(false), "should have thrown on exhaustion")
        } catch let error as EngineError {
            if case .timeout(let seconds) = error {
                #expect(seconds == "7", "the caller-facing error must be the original timeout, not the driver signal")
            } else {
                #expect(Bool(false), "wrong EngineError case: \(error)")
            }
        }
        #expect(attempts == 3, "retries: 2 must yield exactly 3 attempts, got \(attempts)")

        // Succeeds on the 2nd attempt when a retry recovers.
        var recoverAfter = 1
        let value = try await SiriAXEngine.driveAXWithTimeoutRetries(retries: 2) { _ in
            if recoverAfter > 0 { recoverAfter -= 1; throw SiriAXEngine.AXRetrySignal.transient(EngineError.timeout("30")) }
            return "settled"
        } as String
        #expect(value == "settled")
    }

    @Test("terminal failures propagate immediately without a retry")
    func terminalPropagatesImmediately() async {
        var attempts = 0
        do {
            _ = try await SiriAXEngine.driveAXWithTimeoutRetries(retries: 5) { _ in
                attempts += 1
                throw SiriAXEngine.AXRetrySignal.terminal(EngineError.backend("composer text field missing"))
            } as Int
            #expect(Bool(false), "terminal errors must throw")
        } catch let error as EngineError {
            if case .backend(let detail) = error {
                #expect(detail == "composer text field missing")
            } else {
                #expect(Bool(false), "wrong EngineError case: \(error)")
            }
        } catch {
            #expect(Bool(false), "signal wrapper leaked to the caller: \(error)")
        }
        #expect(attempts == 1, "terminal errors never get a second attempt, got \(attempts)")
    }

    @Test("unsignalled errors and cancellation propagate untouched")
    func plainErrorsAreNotRetried() async {
        var attempts = 0
        do {
            // A bare non-signal error (e.g. an unexpected throw inside the
            // AX pipeline) must NOT be classified as transient.
            _ = try await SiriAXEngine.driveAXWithTimeoutRetries(retries: 3) { _ in
                attempts += 1
                throw EngineError.unavailable("app not found")
            } as Int
            #expect(Bool(false))
        } catch let error as EngineError {
            if case .unavailable(let detail) = error {
                #expect(detail == "app not found")
            } else {
                #expect(Bool(false), "wrong EngineError case: \(error)")
            }
        } catch is CancellationError {
            #expect(Bool(false), "plain error surfaced as cancellation")
        } catch {
            #expect(Bool(false), "plain error mutated by the driver: \(error)")
        }
        #expect(attempts == 1)

        // Cancellation: the driver must not swallow or retry it (structural
        // contract — attempt closures rethrow CancellationError verbatim).
        var cancelAttempts = 0
        do {
            _ = try await SiriAXEngine.driveAXWithTimeoutRetries(retries: 3) { _ in
                cancelAttempts += 1
                throw CancellationError()
            } as Int
            #expect(Bool(false))
        } catch is CancellationError {
            // exactly right
        } catch {
            #expect(Bool(false), "cancellation must surface as CancellationError, got \(error)")
        }
        #expect(cancelAttempts == 1)
    }

    @Test("negative retries are clamped to zero")
    func negativeRetriesClamp() async {
        var attempts = 0
        do {
            _ = try await SiriAXEngine.driveAXWithTimeoutRetries(retries: -4) { _ in
                attempts += 1
                throw SiriAXEngine.AXRetrySignal.transient(EngineError.timeout("30"))
            } as Int
            #expect(Bool(false))
        } catch {
            // any error is fine — the contract under test is attempt count
        }
        #expect(attempts == 1, "negative retries must clamp to a single attempt, got \(attempts)")
    }

    // MARK: - Configuration surface

    @Test("init config: timeout and retries stored, negative retries clamped")
    func initConfigSurface() {
        let custom = SiriAXEngine(system: "s", timeout: 9, retries: 3)
        // members are internal — reachable under @testable
        #expect(custom.timeout == 9)
        #expect(custom.retries == 3)
        #expect(custom.system == "s")

        let clamped = SiriAXEngine(retries: -2)
        #expect(clamped.retries == 0)
        #expect(clamped.timeout == 30, "default timeout must remain 30s")
        #expect(clamped.retries == 0 && SiriAXEngine().retries == 1, "default retries must be 1 (single auto-retry)")
    }

    // MARK: - withInferenceDeadline (live tool-loop bail-out guard)

    /// The live tool loop hung >7 min; this guard races the awaited call
    /// against a wall-clock deadline and abandons the hung call. These tests
    /// pin the race semantics deterministically — the live wiring is
    /// verified by the LIVE_TESTS tier.
    @Test("deadline: fast operation returns its value; slow operation is abandoned with EngineError.timeout")
    func deadlineFastAndSlowPaths() async throws {
        // Fast path: result delivered, no timeout noise.
        let fast = try await withInferenceDeadline(5, { () async -> Int in 7 })
        #expect(fast == 7)

        // Slow path: charging for 20s, deadline at 0.3s — must throw the
        // timeout near-instantly (the point of the guard) rather than wait.
        let started = Date()
        do {
            _ = try await withInferenceDeadline(0.3, { () async throws -> Int in
                try await Task.sleep(nanoseconds: 20_000_000_000)
                return -1
            })
            #expect(Bool(false), "slow operation must be abandoned")
        } catch let error as EngineError {
            if case .timeout = error {} else { #expect(Bool(false), "wrong error: \(error)") }
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 5, "bail-out must be timely, took \(elapsed)s")
    }

    @Test("deadline: operation errors propagate as-is; close race prefers completed result over timeout")
    func deadlineErrorPropagationAndCloseRace() async throws {
        // Operation's own error reaches the caller untouched.
        do {
            _ = try await withInferenceDeadline(10, { () async throws -> Int in
                throw EngineError.unavailable("probe")
            })
            #expect(Bool(false), "operation error must propagate")
        } catch let error as EngineError {
            if case .unavailable(let detail) = error {
                #expect(detail == "probe")
            } else {
                #expect(Bool(false), "wrong error: \(error)")
            }
        }

        // Close race: cheap op finishes during the timer's sleep — must
        // return the VALUE, not the timeout that fired microseconds later.
        for _ in 0..<5 {
            let value = try await withInferenceDeadline(0.05, { () async -> Int in 42 })
            #expect(value == 42, "completed result must win over a late-firing timer")
            try await Task.sleep(nanoseconds: 20_000_000) // let the timer child drain
        }
    }
}
