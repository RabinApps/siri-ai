import Foundation
import ApplicationServices
import AppKit

/// The secondary backend: drives the real "Siri AI" chat app (macOS 27) through
/// the Accessibility API, then reads the answer back out of its AX tree.
///
/// Trade-offs versus the default backend (documented in README):
/// - No streaming, no tool calling, no temperature control.
/// - Fragile against macOS updates that change the Siri AI UI structure.
/// - Requires Accessibility (and, for diagnostics, Screen Recording) permission.
///
/// The design mirrors Pasithea0/siri-cli: find/launch the app, AXPress its
/// "New Conversation" button, write the query into the composer text field,
/// AXConfirm, then poll the window's AX tree until the response text settles.
/// One observation from the AX polling loop: the tree's current text either
/// changed since the last poll (`.progress`) or the answer settled (`.final`).
enum AXEvent: Sendable {
    case progress(rawText: String)
    case final(cleanedText: String)
}

public struct SiriAXEngine: LLMEngine {
    let system: String?
    let timeout: TimeInterval
    /// Extra AX attempts after a transient settle-timeout. Each retry re-drives
    /// a fresh Siri conversation. `0` = old single-attempt behavior.
    let retries: Int

    /// - Parameters:
    ///   - system: optional system prompt folded into every request.
    ///   - timeout: seconds to wait for the Siri reply to settle before the
    ///     attempt is declared stalled (default 30).
    ///   - retries: how many extra attempts a transient settle-timeout gets
    ///     (default 1 — Siri occasionally stalls a session; a fresh AX drive
    ///     usually answers cleanly). Only the timeout is retried: structural
    ///     AX failures (missing composer, unavailable app) propagate
    ///     immediately, and a stream that already emitted deltas is never
    ///     restarted mid-flight.
    public init(system: String? = nil, timeout: TimeInterval = 30, retries: Int = 1) {
        self.system = system
        self.timeout = timeout
        self.retries = max(0, retries)
    }

    /// The Siri backend can't honor system instructions as a separate field;
    /// folds them into the prompt if present, then drives the AX session with
    /// transient-settle-timeout retries.
    public func respond(_ request: EngineRequest) async throws -> AgentResponse {
        var prompt = request.prompt
        if let system = request.system ?? self.system {
            prompt = "\(system)\n\n\(prompt)"
        }
        return try await Self.driveAXWithTimeoutRetries(retries: retries) { _ in
            var finalText: String?
            for try await event in Self.observe(prompt: prompt, timeout: timeout) {
                if case .final(let cleaned) = event { finalText = cleaned }
            }
            guard let text = finalText else {
                // Transient: Siri sometimes stalls a session; a fresh AX drive
                // usually settles (reproduced in the release-gate live run).
                throw AXRetrySignal.transient(EngineError.timeout("\(Int(timeout))"))
            }
            return AgentResponse(text: text, streamed: false)
        }
    }

    /// Streams settle-progress deltas: each growth of the AX tree is forwarded
    /// as a cleaned snapshot of what has arrived so far. On settle, one delta
    /// closes the response so that *concatenated* stream output equals the
    /// final cleaned answer exactly:
    /// last progress = P (longest prefix of the final answer),
    /// final delta   = remainder of final answer after P.
    public func stream(_ request: EngineRequest) -> AsyncThrowingStream<String, Error> {
        let basePrompt = request.prompt
        let effectiveSystem = request.system ?? self.system
        let timeout = self.timeout
        let retries = self.retries
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var prompt = basePrompt
                    if let system = effectiveSystem {
                        prompt = "\(system)\n\n\(prompt)"
                    }
                    _ = try await Self.driveAXWithTimeoutRetries(retries: retries) { _ in
                        var lastProgress = ""
                        var emitted = false
                        do {
                            for try await event in Self.observe(prompt: prompt, timeout: timeout) {
                                let cleaned: String
                                switch event {
                                case .progress(let raw): cleaned = AXCleaner.clean(raw)
                                case .final(let cleanedText): cleaned = cleanedText
                                }
                                if let delta = Self.convergenceDelta(previous: lastProgress, current: cleaned) {
                                    lastProgress = cleaned
                                    emitted = true
                                    continuation.yield(delta)
                                }
                            }
                        } catch {
                            // A timeout BEFORE any delta reached the caller is
                            // transient (safe to re-drive a fresh conversation);
                            // a timeout AFTER deltas must not restart the stream,
                            // because the consumer's concatenation already holds
                            // the earlier session's content. Either way the
                            // original error object is rethrown untouched.
                            var retriable = false
                            if let engineError = error as? EngineError,
                               case .timeout = engineError {
                                retriable = !emitted
                            }
                            throw AXRetrySignal.wrapping(error, retriable: retriable)
                        }
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
        get async {
            let axGranted = AXIsProcessTrusted()
            let appRunning = Self.siriAppPID() != nil
            if axGranted && appRunning {
                return AvailabilityReport(backend: .siri, ready: true, detail: "Siri AI app reachable via Accessibility")
            }
            var problems: [String] = []
            if !axGranted { problems.append("Accessibility permission not granted to this terminal/app") }
            if !appRunning { problems.append("Siri AI app not installed or not launchable") }
            return AvailabilityReport(backend: .siri, ready: false, detail: problems.joined(separator: "; "))
        }
    }

    // MARK: - Automation

    /// Marks a Siri AX attempt outcome for `driveAXWithTimeoutRetries`: the
    /// settle-timeout is transient (a fresh Siri session usually answers
    /// cleanly); every other error is terminal and propagates untouched.
    enum AXRetrySignal: Error {
        /// Transient failure: re-drive the session; `error` is rethrown at exhaustion.
        case transient(Error)
        /// Terminal failure: `error` is rethrown immediately, no retry.
        case terminal(Error)

        /// Marks `error` as transient or terminal for the retry driver.
        static func wrapping(_ error: some Error, retriable: Bool) -> any Error {
            retriable ? Self.transient(error) : Self.terminal(error)
        }
    }

    /// The auto-retry driver: runs `attempt` up to `1 + retries` total times,
    /// re-running only after an `AXRetrySignal.transient` (the Siri settle
    /// timeout). Each retry re-drives a fresh Siri conversation, so attempts
    /// are independent. `.terminal` signals and any other thrown error —
    /// including `CancellationError` — propagate untouched. `attemptIndex`
    /// (0-based) lets attempts observe their position for diagnostics.
    static func driveAXWithTimeoutRetries<T>(
        retries: Int,
        _ attempt: (Int) async throws -> T
    ) async throws -> T {
        var index = 0
        while true {
            do {
                return try await attempt(index)
            } catch let signal as AXRetrySignal {
                switch signal {
                case .transient(let original):
                    if index >= max(0, retries) { throw original }
                    index += 1
                    TerminalOutput.error(
                        "siri-ai: Siri AX settle timeout — re-driving the conversation " +
                        "(attempt \(index + 1) of \(max(0, retries) + 1))")
                case .terminal(let original):
                    throw original
                }
            }
        }
    }

    /// Given the previously-forwarded cleaned progress and the current cleaned
    /// snapshot, returns the delta a concatenated-stream consumer should see:
    ///
    /// - current == previous      → nil (no new text)
    /// - current extends previous → the incremental suffix (pure growth)
    /// - anything else            → "\u{000B}" + current (vertical-tab re-render
    ///                              marker followed by the whole new snapshot)
    ///
    /// Invariant: concatenating every yielded delta reproduces the last
    /// snapshot after interpreting each \u{000B} as "discard what you have".
    static func convergenceDelta(previous: String, current: String) -> String? {
        if current == previous { return nil }
        if current.hasPrefix(previous) { return String(current.dropFirst(previous.count)) }
        return "\u{000B}" + current
    }


    /// Optional raw-capture hook: records every poll snapshot (prompt + raw
    /// tree text) for fixture generation. Nil in production.
    nonisolated(unsafe) static var captureSink: (@Sendable (_ prompt: String, _ raw: String) -> Void)?

    /// Test hook: exposes the private observe stream at default accessibility.
    func observeForTesting(prompt: String, timeout: TimeInterval = 30) -> AsyncThrowingStream<AXEvent, Error> {
        Self.observe(prompt: prompt, timeout: timeout)
    }

    /// Drives the Siri AI app through AX and yields AXEvents from polling:
    /// each growth or change of the tree is a `.progress`, and once the text
    /// is stable across two consecutive 500 ms polls the cleaned answer is
    /// emitted as `.final`.
    private static func observe(prompt: String, timeout: TimeInterval) -> AsyncThrowingStream<AXEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let pid = try await siriAppWithVisibleUI() else {
                        throw EngineError.unavailable("Siri AI app not found. Is it installed and signed in?")
                    }
                    let app = AXUIElementCreateApplication(pid)

        // 1. Reset to a fresh conversation so old content doesn't pollute capture.
        if let button = AXFinder.findButton(titled: ["New Conversation", "New Chat", "New"], in: app) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }

        // 2. Find the composer text field and type the query.
        //    The composer only exists in conversation mode: after the
        //    New Conversation press the AXTextField materializes. Wait for
        //    it to appear (up to ~3 s) instead of a fixed 400 ms sleep —
        //    app cold-starts and slower Macs expose the field late.
        var composer: AXUIElement?
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if let field = AXFinder.findTextField(in: app) { composer = field; break }
        }
        guard let composerField = composer else {
            throw EngineError.backend("Could not locate the Siri AI composer text field in the AX tree.")
        }
        guard AXUIElementSetStringValue(composerField, prompt) else {
            throw EngineError.backend("Could not set the query into the Siri AI composer.")
        }
        AXUIElementPerformAction(composerField, kAXConfirmAction as CFString)

                    // 3. Poll the window's AX tree until the response text settles.
                    let deadline = Date().addingTimeInterval(timeout)
                    var lastText = ""
                    var stableCount = 0
                    while Date() < deadline {
                        try await Task.sleep(nanoseconds: 500_000_000)
                        let snapshot = AXFinder.visibleText(in: app)
                            .filter { !$0.contains(prompt) }         // drop the echo of our query
                            .joined(separator: "\n")
                        SiriAXEngine.captureSink?(prompt, snapshot)
                        if snapshot == lastText, !snapshot.isEmpty {
                            stableCount += 1
                            if stableCount >= 2 {                 // two identical reads = settled
                                continuation.yield(.final(cleanedText: AXCleaner.clean(lastText)))
                                continuation.finish()
                                return
                            }
                        } else {
                            // Every poll that changes the tree is progress —
                            // consumers see growth between polls.
                            if !snapshot.isEmpty {
                                continuation.yield(.progress(rawText: snapshot))
                            }
                            stableCount = 0
                            lastText = snapshot
                        }
                    }
                    throw EngineError.timeout("\(Int(timeout))")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Locate the Siri AI application by bundle ID, launching it if necessary,
    /// and ensure it has a VISIBLE WINDOW before the caller starts AX work.
    ///
    /// The macOS 27 "Siri AI" app's real bundle ID is `com.apple.campo` —
    /// despite displaying as "Siri AI" and living at
    /// /System/Applications/Siri AI.app, it runs as the Siri binary process.
    /// `com.apple.SiriAI` does not exist on any tested system.
    ///
    /// Why a visible-window gate matters: the app idles as a background
    /// daemon (observed: pid live, zero on-screen windows, AX tree exposes
    /// only the menu bar). In that state the "New Conversation" button and
    /// the composer don't exist in the tree at all, and
    /// `findTextField` fails with the infamous "composer text field" error.
    /// `open -b com.apple.campo` materializes the window this session.
    static func siriAppWithVisibleUI(timeoutSeconds: TimeInterval = 8) async throws -> pid_t? {
        guard let pid = siriAppPID() else { return nil }
        // Fast path: window already on screen (normal for repeated calls).
        if let _ = Self.visibleWindows(pid) { return pid }

        // Cold path: open the UI, then poll for a window to materialize.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", "com.apple.campo"]
        _ = try? open.run()
        open.waitUntilExit()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
            if Self.visibleWindows(pid) != nil { return pid }
            // A stale pid from a dead daemon: re-resolve once.
            if siriAppPID() != pid, let fresh = siriAppPID() {
                if Self.visibleWindows(fresh) != nil { return fresh }
            }
        }
        return pid   // proceed anyway — the caller's error messaging covers it
    }

    /// Returns the AXWindows array (count > 0) for the app, or nil when the
    /// app has no window materialized in the AX tree.
    private static func visibleWindows(_ pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        guard let list = windows as? [AXUIElement], !list.isEmpty else { return nil }
        return list
    }

    private static func siriAppPID() -> pid_t? {
        let bundleID = "com.apple.campo"
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return running.processIdentifier
        }
        // Not running: activate macOS's launch machinery via `open -b`.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", bundleID]
        _ = try? open.run()
        open.waitUntilExit()
        // Wait briefly for the app to appear.
        for _ in 0..<20 {
            usleep(250_000)
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return app.processIdentifier
            }
        }
        return nil
    }
}

/// Small helpers for walking AX trees.
enum AXFinder {
    static func findButton(titled titles: [String], in app: AXUIElement) -> AXUIElement? {
        findRecursive(in: app) { element in
            guard let role = stringValue(of: element, attribute: kAXRoleAttribute),
                  role == "AXButton" else { return nil }
            let title = stringValue(of: element, attribute: kAXTitleAttribute) ?? ""
            let desc = stringValue(of: element, attribute: kAXDescriptionAttribute) ?? ""
            return titles.contains { title.localizedCaseInsensitiveContains($0) || desc.localizedCaseInsensitiveContains($0) }
                ? element : nil
        }
    }

    static func findTextField(in app: AXUIElement) -> AXUIElement? {
        findRecursive(in: app) { element in
            guard let role = stringValue(of: element, attribute: kAXRoleAttribute),
                  role == "AXTextField" || role == "AXTextArea" else { return nil }
            return element
        }
    }

    /// Returns all non-empty, user-visible text strings in the app's window tree.
    static func visibleText(in app: AXUIElement) -> [String] {
        var results: [String] = []
        collectText(in: app, into: &results)
        return results
    }

    private static func collectText(in element: AXUIElement, into results: inout [String]) {
        if let value = stringValue(of: element, attribute: kAXValueAttribute), !value.isEmpty {
            results.append(value)
        }
        if let children = attributeValue(of: element, attribute: kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                collectText(in: child, into: &results)
            }
        }
    }

    private static func findRecursive(
        in element: AXUIElement,
        match: (AXUIElement) -> AXUIElement?
    ) -> AXUIElement? {
        if let hit = match(element) { return hit }
        guard let children = attributeValue(of: element, attribute: kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let hit = findRecursive(in: child, match: match) { return hit }
        }
        return nil
    }
}

/// Strips the Siri AI app's own chrome and render noise that leaks into AX
/// captures. Handles both capture shapes: single-settle answers (ask mode)
/// and incrementally-polling captures (chat/streaming mode), where Siri's
/// own activity labels ("Searching…", "Looking over results") appear as
/// transient lines in the tree mid-generation.
///
/// 1. Rich cards render twice: once as one packed "blob" line (prose + card
///    title + card body concatenated), then again as clean separate lines.
/// 2. Short card-title fragments ("Tokyo", "Moon") duplicate a word already
///    present in the prose line.
/// 3. A stray "0" counter line is appended to every response.
enum AXCleaner {
    private static let chrome = [
        "New Conversation", "New Chat", "Siri", "Done", "Send",
        "Ask Siri", "Ask anything…", "Stop",
    ]

    /// Siri's transient activity labels, observed mid-generation in the AX
    /// tree during multi-poll (streaming/chat) captures.
    private static let activityLabels = [
        "Searching", "Searching for", "Looking over results",
        "Reviewing results", "Going over results", "Searching notes",
        "Thinking", "Working on it", "One moment",
    ]

    /// True when a line is one of Siri's transient activity labels (or a
    /// short variant like "Searching for favorite number" built on them).
    static func isActivityLabel(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        for label in activityLabels where trimmed.hasPrefix(label) {
            // "Searching for favorite number" is still activity, but a real
            // answer can't start with any of these phrases.
            return trimmed.count < 60
        }
        return false
    }

    /// True for source-attribution lines Siri appends to rich cards,
    /// e.g. "Notes — iCloud", "Calendar — iCloud".
    static func isSourceAttribution(_ line: String) -> Bool {
        line.hasSuffix("— iCloud") || line.hasSuffix("- iCloud")
    }

    /// Lines at or below this length that appear inside another kept line are
    /// treated as card-title fragments and dropped.
    private static let fragmentMaxChars = 32

    static func clean(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !isActivityLabel($0) }   // activity labels are never content
            .filter { !isSourceAttribution($0) }   // "Notes — iCloud" etc.
            .filter { line in !chrome.contains { line.caseInsensitiveCompare($0) == .orderedSame } }

        // Pass 1: collapse identical consecutive lines (double rendering).
        lines = lines.reduce(into: [String]()) { acc, line in
            if acc.last != line { acc.append(line) }
        }

        // Pass 2: drop the trailing AX counter (observed as a bare "0" last).
        if let last = lines.last, last == "0" {
            lines.removeLast()
        }

        // Pass 3: drop the packed first-line blob when every substantive line
        // after it is embedded inside it (the clean render follows).
        if lines.count > 1, isPackedBlob(lines[0], rest: Array(lines.dropFirst())) {
            lines.removeFirst()
        }

        // Pass 4: drop bare arithmetic-expression lines ("12 × 12 =",
        // "85 + 17 =") — the calculator card draws the equation; the prose
        // line already carries the result.
        if lines.contains(where: { Self.looksLikeProse($0) }) {
            lines = lines.filter { !Self.isBareArithmetic($0) }
        }

        // Pass 5: drop short fragment lines whose text already appears inside
        // a longer kept line (card titles like "Tokyo", "Moon", bare results
        // like "144" that also appear in the prose).
        lines = lines.filter { line in
            guard line.count <= Self.fragmentMaxChars else { return true }
            return !lines.contains { other in
                other != line && other.count > line.count && other.contains(line)
            }
        }

        return lines.joined(separator: "\n")
    }

    /// A "packed blob" is a line that contains the text of every substantive
    /// following line (prose, card title, case body merged by the renderer).
    private static func isPackedBlob(_ first: String, rest: [String]) -> Bool {
        let substantive = rest.filter { $0.count >= fragmentMaxChars }
        guard !substantive.isEmpty else { return false }
        return substantive.allSatisfy { first.contains($0) || first.contains($0.prefix(24)) }
    }

    /// Prose = sentence-like: at least two words and some letters.
    /// ("It's 144." qualifies; "12 × 12 =" has no letters and does not.)
    private static func looksLikeProse(_ line: String) -> Bool {
        let words = line.split(separator: " ")
        guard words.count >= 2 else { return false }
        let letters = line.filter { $0.isLetter }
        return Double(letters.count) / Double(max(line.count, 1)) > 0.2
    }

    /// Matches calculator-card equation lines like "12 × 12 =" or "85 + 17 =".
    private static func isBareArithmetic(_ line: String) -> Bool {
        let hasOperator = line.contains("×") || line.contains("÷")
            || line.contains("+") || line.contains("−") || line.contains("=")
        guard hasOperator else { return false }
        let stripped = line.filter { !$0.isNumber && !$0.isWhitespace
            && $0 != "×" && $0 != "÷" && $0 != "+" && $0 != "−" && $0 != "=" && $0 != "." }
        return stripped.isEmpty
    }
}

// MARK: - AX attribute helpers

private func attributeValue(of element: AXUIElement, attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return result == .success ? value : nil
}

private func stringValue(of element: AXUIElement, attribute: String) -> String? {
    attributeValue(of: element, attribute: attribute) as? String
}

extension AXUIElement {
    func performAction(_ action: String) {
        AXUIElementPerformAction(self, action as CFString)
    }
}

/// Set a string via the standard kAXValueAttribute path; returns success.
func AXUIElementSetStringValue(_ element: AXUIElement, _ value: String) -> Bool {
    let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
    return setResult == .success
}
