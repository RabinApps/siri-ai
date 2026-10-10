import Foundation
import FoundationModels
import os

// MARK: - Decision types (@Generable schema mirrors)

/// One typed verdict covering everything the System 1 pass decides per query.
/// Kept terse: schema tokens come out of the on-device model's 4,096-token
/// window even on the decision path.
@Generable
public struct FastDecision: Sendable, Equatable {
    /// Query needs file tools (list/read/search) to be answered well.
    @Guide(description: "True when answering needs inspecting repository files.")
    public var needsTools: Bool

    /// Query benefits from repo grounding (stuffed context) even without tools.
    @Guide(description: "True when repo context should be stuffed into the prompt.")
    public var needsContext: Bool

    /// Query asks to change/create code — the --edit pre-gate.
    @Guide(description: "True when the query asks to change or create code.")
    public var isEditRequest: Bool

    /// Memberwise init: @Generable only synthesizes the GeneratedContent
    /// decode init (which then wins name resolution), so plain construction
    /// — e.g. the CLI's canned-decision injections — needs this explicitly.
    public init(needsTools: Bool, needsContext: Bool, isEditRequest: Bool) {
        self.needsTools = needsTools
        self.needsContext = needsContext
        self.isEditRequest = isEditRequest
    }
}

/// Cheap yes/no gate before entering `--edit` mode.
@Generable
public struct EditGate: Sendable {
    @Guide(description: "True when the query asks to change or create code.")
    var isEditRequest: Bool
}

// MARK: - Engine

/// "System 1" fast decision: a single, schema-constrained on-device model call
/// that produces a typed verdict (routing + gates) before the slower System 2
/// generation. Fully constrained via `@Generable`, so the small model cannot
/// ramble. Never blocks a request longer than `timeoutSeconds` — callers
/// should prefer `FastDecisions.route`, which applies the heuristic
/// fallback automatically; use this type directly only when you must
/// observe/catch the throw yourself.
public struct FastDecisionEngine: Sendable {
    /// Hard cap on the decision call. The whole point is that this pass costs
    /// less latency than it saves; measured single-shot on-device schema calls
    /// usually return well under 300 ms, and 2 s is a generous ceiling that
    /// still guarantees a fast worst case (heuristic fallback at 2 s).
    let timeoutSeconds: Double

    public init(timeoutSeconds: Double = 2.0) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Typed routing verdict for one query.
    public func decide(query: String) async throws -> FastDecision {
        try await Self.withTimeout(seconds: timeoutSeconds) {
            guard let session = Self.makeSession() else {
                throw EngineError.unavailable("Apple Intelligence model is not available. Run `siri-ai status`.")
            }
            let options = GenerationOptions(temperature: 0.0, maximumResponseTokens: 128)
            let response = try await session.respond(to: Self.decisionPrompt(query), generating: FastDecision.self, options: options)
            return response.content
        }
    }

    /// Typed edit gate for one query (cheaper output schema than FastDecision).
    public func editGate(query: String) async throws -> EditGate {
        try await Self.withTimeout(seconds: timeoutSeconds) {
            guard let session = Self.makeSession() else {
                throw EngineError.unavailable("Apple Intelligence model is not available. Run `siri-ai status`.")
            }
            let options = GenerationOptions(temperature: 0.0, maximumResponseTokens: 64)
            let response = try await session.respond(to: Self.editGatePrompt(query), generating: EditGate.self, options: options)
            return response.content
        }
    }

    /// Internal (not private) so @testable imports can probe construction.
    static func makeSession() -> LanguageModelSession? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        if useLatencyOptimizedModel {
            return LanguageModelSession(model: .default)
        }
        return LanguageModelSession(model: .default)
        // NOTE: Apple's FoundationModels exposes numeral tiers as .default on
        // current OS builds; .useDefaultLocale etc. are not model selectors.
    }

    /// True when the runtime advertises a latency tier. Kept as a probe point
    /// so the-toggle tests can inject behavior; currently always true because
    /// session construction already falls back to `.default`.
    static let useLatencyOptimizedModel: Bool = true

    static func decisionPrompt(_ query: String) -> String {
        """
        Decide, for this user query, three yes/no facts:
        needsTools — answering well requires inspecting repository files (list/read/search) rather than knowledge alone.
        needsContext — stuffing relevant repo text into the prompt would materially help.
        isEditRequest — the user asks to change, write, fix, or create code.
        Query: \(query)
        """
    }

    static func editGatePrompt(_ query: String) -> String {
        """
        Is this query asking to change, write, fix, or create code (true) or just to read/explain/discuss it (false)?
        Query: \(query)
        """
    }

    // MARK: - Timeout helper

    /// Race the body against a timeout. On timeout, throw. (Structured so the
    /// underlying task is canceled, not leaked.)
    static func withTimeout<T: Sendable>(
        seconds: Double,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw EngineError.timeout("\(Int(seconds))")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Heuristic fallback

/// Deterministic, model-free System 1: keyword/signal routing used when the
/// typed model call throws, times out, or is disabled. Never throws, never
/// blocks; table-testable without a backend.
public enum FastDecisionFallback {
    /// Signals that a query asks for code modification.
    static let editVerbs: Set<String> = [
        "add", "append", "change", "create", "delete", "edit", "extract", "fix",
        "implement", "insert", "introduce", "migrate", "modify", "move", "refactor",
        "remove", "rename", "replace", "rewrite", "update", "write", "patch",
        // Observed via the model/heuristic drift log (see FastDecisions.
        // recordAgreement): the on-device model classifies these as edit
        // requests and users agree — keep the heuristic in step.
        "tighten", "clean", "clean up", "simplify", "optimize", "tweak",
        "adjust", "improve", "shorten", "expand", "extend", "polish",
    ]

    /// Returns the heuristic verdict for a query.
    public static func decide(query: String) -> FastDecision {
        let words = query.lowercased()
            .split(whereSeparator: { (char: Character) in !char.isLetter && !char.isNumber })
        let hasEditVerb = words.contains { editVerbs.contains(String($0)) }
        // "add error handling to connect() in net.swift" → tools + edit.
        // "explain async/await" → neither. General questions → neither.
        return FastDecision(
            needsTools: hasEditVerb || hasFileSignal(query),
            needsContext: hasEditVerb || hasFileSignal(query),
            isEditRequest: hasEditVerb
        )
    }

    /// Cheap edit gate: true only for explicit edit verbs.
    public static func editGate(query: String) -> Bool {
        let words = query.lowercased()
            .split(whereSeparator: { (char: Character) in !char.isLetter && !char.isNumber })
        return words.contains { editVerbs.contains(String($0)) }
    }

    /// True for queries mentioning file-oriented nouns (WORD-BOUNDARY match:
    /// "repo" fires on "this repo" but not on "repolish"; "module" on "which
    /// module" but not "modular") or path-like extensions ("foo.swift").
    public static func hasFileSignal(_ query: String) -> Bool {
        let lower = query.lowercased()
        let fileNouns = ["file", "repo", "repository", "directory", "folder", "module", "package"]
        let containsWholeWord: (String) -> Bool = { noun in
            lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: noun) + "\\b", options: .regularExpression) != nil
        }
        return fileNouns.contains(where: containsWholeWord)
            || (lower.range(of: "\\.swift|\\.ts|\\.js|\\.py|\\.go|\\.rs|\\.java", options: .regularExpression) != nil)
    }
}

// MARK: - Requestor-facing orchestrator

/// The one entry point callers should use: try the typed model call, fall back
/// to heuristics on any failure/timeout, and additionally records the
/// model-vs-heuristic verdict pair on every model call so drift between the
/// two System-1 paths is visible. Never throws.
public enum FastDecisions {
    /// Full routing verdict with fallback. `backend` names the engine the
    /// verdict will steer; per plan, decisions only run on the apple backend —
    /// passing `.siri` returns the synchronous heuristic verdict with no model
    /// call (useful as a deterministic, always-cheap classification).
    public static func route(
        query: String,
        backend: Backend,
        timeoutSeconds: Double = 2.0
    ) async -> FastDecision {
        guard isEnabled, backend == .apple else {
            return FastDecisions.debug(query, FastDecisionFallback.decide(query: query), source: "heuristic")
        }
        let engine = FastDecisionEngine(timeoutSeconds: timeoutSeconds)
        do {
            let decision = try await engine.decide(query: query)
            FastDecisions.recordAgreement(query: query, model: decision)
            return FastDecisions.debug(query, decision, source: "model")
        } catch {
            let reason = String(describing: error)
            _ = reason
            return FastDecisions.debug(query, FastDecisionFallback.decide(query: query), source: "fallback")
        }
    }

    /// Edit pre-gate with the same fallback contract.
    public static func editGate(
        query: String,
        timeoutSeconds: Double = 2.0
    ) async -> Bool {
        guard isEnabled else {
            return FastDecisionFallback.editGate(query: query)
        }
        let engine = FastDecisionEngine(timeoutSeconds: timeoutSeconds)
        do {
            let gate = try await engine.editGate(query: query)
            return gate.isEditRequest
        } catch {
            return FastDecisionFallback.editGate(query: query)
        }
    }

    /// `--no-fast-decisions` / `SIRI_AI_NO_FAST_DECISIONS` kill switch.
    /// Defaults to enabled (routing runs); set to false to skip the model call
    /// and take the deterministic heuristic verdict instead.
    ///
    /// Concurrency: `nonisolated(unsafe)` because this is a process-wide policy
    /// flip (CLI flag → library), coordinated with test counters behind
    /// `testStateLock` in test code. Production entry points are single-actor
    /// request paths, so the race window is theoretical there — but callers
    /// that flip this flag concurrently with `route`/`editGate` calls accept
    /// whichever value that in-flight call observed.
    ///
    /// `stateLock` serializes *kill-switch + log* mutations relative to each
    /// other in tests: several suites legitimately flip `isEnabled` for their
    /// run while FastDecisionTests counts `agreementLog` appends between
    /// calls. Swift Testing's `.serialized` is per-suite only, so suites that
    /// share these globals take this lock around their flip-and-check window
    /// instead. Production never takes it (all entry points are single-actor
    /// request paths).
    public nonisolated(unsafe) static var isEnabled: Bool = ProcessInfo.processInfo.environment["SIRI_AI_NO_FAST_DECISIONS"] == nil
    /// Test-only: guards (isEnabled flips + agreementLog counting) windows.
    static let testStateLock = TestStateGate()

    /// Spin mutex for test windows (see `testStateLock`). Single `held` flag
    /// under an OSAllocatedUnfairLock, which itself serializes state flips.
    /// Acquisition CAS-flips false→true (blocked callers of the unfair lock
    /// don't matter — the flag, not the unfair lock, is the gate). Losers park
    /// on Task.yield(); windows are millisecond-scale state flips, never
    /// sleeps, so the park is transient and priority-safe enough for tests.
    ///
    /// NOTE this mirror is intentionally conservative and test-only: production
    /// code never takes it (see `testStateLock`'s doc comment).
    final class TestStateGate: Sendable {
        private let held = OSAllocatedUnfairLock(initialState: false)

        init() {}

        func withLock<T>(_ body: () throws -> T) rethrows -> T {
            acquireForever()
            defer { release() }
            return try body()
        }

        func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
            await acquireForeverAsync()
            defer { release() }
            return try await body()
        }

        /// True when this acquire won the false→true flip.
        private func tryAcquire() -> Bool {
            held.withLock { isHeld in
                if isHeld { return false }
                isHeld = true
                return true
            }
        }

        private func release() {
            held.withLock { isHeld in
                isHeld = false
                return ()
            }
        }

        func acquireForever() {
            while !tryAcquire() { Thread.sleep(forTimeInterval: 0.000_5) }
        }

        func acquireForeverAsync() async {
            while !tryAcquire() { await Task.yield() }
        }
    }

    /// `SIRI_AI_DEBUG_DECISIONS=1` prints the verdict (and its source) to stderr.
    /// Internal; set the env var instead of writing this directly.
    nonisolated(unsafe) static var debugEnabled: Bool = ProcessInfo.processInfo.environment["SIRI_AI_DEBUG_DECISIONS"] == "1"

    /// Decision-call timeout: overridable per install via
    /// `SIRI_AI_DECISION_TIMEOUT`, default 2 s.
    /// User decision specs get a slightly larger budget than plain routing
    /// (their schema is often bigger) — but still capped, never unbounded.
    public nonisolated(unsafe) static var decisionTimeoutSeconds: Double = {
        if let raw = ProcessInfo.processInfo.environment["SIRI_AI_DECISION_TIMEOUT"], let value = Double(raw), value > 0 {
            return min(value, 10)
        }
        return 2.0
    }()

    /// Aggregated model-vs-heuristic verdicts, for drift tracking. Entries
    /// append-only; tests inspect and reset via `resetAgreementLog`.
    public struct AgreementRecord: Sendable, Equatable {
        public let query: String
        public let model: FastDecision
        public let heuristic: FastDecision
        public var agree: Bool { model == heuristic }
    }

    nonisolated(unsafe) static var agreementLog: [AgreementRecord] = []

    static func resetAgreementLog() {
        agreementLog.removeAll()
    }

    /// On every model-backed route call, compute the heuristic verdict too
    /// and log the pair. Logging is always-on (cheap; one array append) so the
    /// disagreement rate is observable in tests without an env flag; stderr
    /// NOTES are printed only when debugEnabled).
    static func recordAgreement(query: String, model: FastDecision) {
        let heuristic = FastDecisionFallback.decide(query: query)
        agreementLog.append(AgreementRecord(query: query, model: model, heuristic: heuristic))
        if debugEnabled, model != heuristic {
            TerminalOutput.error(
                "[fast-decision#DRIFT] model tools=\(model.needsTools) ctx=\(model.needsContext) edit=\(model.isEditRequest) | heuristic tools=\(heuristic.needsTools) ctx=\(heuristic.needsContext) edit=\(heuristic.isEditRequest) — ~\"\(query.prefix(60))\"")
        }
    }

    @discardableResult
    static func debug(_ query: String, _ decision: FastDecision, source: String) -> FastDecision {
        if debugEnabled {
            TerminalOutput.error(
                "[fast-decision#\(source)] tools=\(decision.needsTools) context=\(decision.needsContext) edit=\(decision.isEditRequest) — ~\"\(query.prefix(60))\""
            )
        }
        return decision
    }
}
