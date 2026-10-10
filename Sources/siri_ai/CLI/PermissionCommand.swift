import Foundation
import AppKit
import ApplicationServices
import ArgumentParser
import SiriAILib

/// `siri-ai permission` — walks the user through granting the macOS
/// permissions the Siri AX backend needs, with live re-checks so the user can
/// see each one flip to green the moment they grant it.
struct PermissionCommand: AsyncParsableCommand {
    // No custom init: with all-wrapped defaults present the synthesized
    // memberwise init lets tests construct `PermissionCommand()` directly.
    static let configuration = CommandConfiguration(
        commandName: "permission",
        abstract: "Check and grant the macOS permissions siri-ai needs.",
        discussion: """
        Checks Accessibility (required by the Siri AX backend) and Screen
        Recording (used by diagnostics). For each missing permission the right
        System Settings pane is opened and the command polls live until you
        grant it — or wait 5 minutes and it moves on.
        """
    )

    @Flag(name: .long, help: "Only print the current permission status and exit (no wizard).")
    var checkOnly: Bool = false

    @Flag(name: .long, help: "Skip Screen Recording (only needed for diagnostics/OCR fallback).")
    var accessibilityOnly: Bool = false

    /// Explicit init so tests can construct the type without ArgumentParser's
    /// `parse()` machinery touching the flag wrappers.
    init() {
        _checkOnly = Flag(wrappedValue: false)
        _accessibilityOnly = Flag(wrappedValue: false)
    }

    mutating func run() async throws {
        try await runWith(
            items: accessibilityOnly ? [.accessibility] : [.accessibility, .screenRecording],
            checkOnlyMode: checkOnly
        )
    }

    /// Core wizard logic, separated so tests can drive it with custom items
    /// (fake check closures), stubbed output capture, and an explicit
    /// check-only switch — avoiding ArgumentParser's flag-wrapper read
    /// machinery, which crashes when the type wasn't built via parse().
    func runWith(items: [PermissionItem], checkOnlyMode: Bool) async throws {
        if checkOnlyMode {
            var allGood = true
            for item in items {
                let granted = item.check()
                if !granted { allGood = false }
                TerminalOutput.line("\(item.name): \(granted ? "granted" : "NOT granted")")
            }
            if !allGood { throw ExitCode.failure }
            return
        }

        TerminalOutput.line("siri-ai permission check")
        TerminalOutput.line("Permissions are granted to the app that runs siri-ai")
        TerminalOutput.line("(Terminal, iTerm, or your IDE's embedded terminal).")
        TerminalOutput.line("")

        for item in items {
            if item.check() {
                TerminalOutput.line("[✓] \(item.name): already granted")
                continue
            }
            TerminalOutput.line("[ ] \(item.name): needed to \(item.why)")
            TerminalOutput.raw("Open System Settings → \(item.settingsPath) now? [Y/n] ")
            let answer = await readAnswer()
            if answer == "n" || answer == "no" {
                TerminalOutput.error("Without \(item.name), features that need it will fail.")
                TerminalOutput.line("Run `siri-ai permission` again when ready.")
                throw ExitCode.failure
            }
            if let url = URL(string: item.settingsURL) {
                await Self.openSettings(url)
            }
            TerminalOutput.line("")
            TerminalOutput.line("Waiting for \(item.name) — flip the switch for your terminal app")
            TerminalOutput.line("under \"\(item.settingsPath)\", then come back here (Ctrl-C to stop).")

            let granted = await pollFor(item)
            if granted {
                TerminalOutput.line("[✓] \(item.name): granted — thank you!")
            } else {
                TerminalOutput.error("[ ] \(item.name) not granted after 5 minutes;")
                TerminalOutput.error("    run `siri-ai permission` again when ready.")
                throw ExitCode.failure
            }
            TerminalOutput.line("")
        }

        TerminalOutput.line("All required permissions granted.")
        TerminalOutput.line("Try: siri-ai ask \"hello\" --backend siri")
    }

    /// Live-polls the permission once per second. macOS usually applies the
    /// grant immediately, so the flip lands within a second or two of the
    /// user toggling the switch. Tests can shrink the interval/duration via
    /// the injectable constants below.
    nonisolated(unsafe) static var pollIntervalSeconds: Double = 1.0
    nonisolated(unsafe) static var pollTimeoutSeconds: Double = 300

    private func pollFor(_ item: PermissionItem) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.pollTimeoutSeconds)
        while Date() < deadline {
            if item.check() { return true }
            try? await Task.sleep(nanoseconds: UInt64(Self.pollIntervalSeconds * 1_000_000_000))
        }
        return item.check()
    }

    /// Injectable answer source (default: real stdin read). Tests stub it.
    nonisolated(unsafe) static var answerSource: (@Sendable () async -> String)?

    private func readAnswer() async -> String {
        if let source = Self.answerSource { return await source() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard let line = readLine() else {
                    continuation.resume(returning: "")
                    return
                }
                continuation.resume(returning: line.trimmingCharacters(in: .whitespaces).lowercased())
            }
        }
    }

    /// Injectable settings-open (tests suppress the real NSWorkspace call).
    nonisolated(unsafe) static var settingsOpener: (@Sendable (URL) async -> Void)?

    static func openSettings(_ url: URL) async {
        if let opener = settingsOpener {
            await opener(url)
            return
        }
        NSWorkspace.shared.open(url)
    }
}

struct PermissionItem: Sendable {
    let name: String
    let why: String
    let settingsPath: String
    let settingsURL: String
    let check: @Sendable () -> Bool

    static let accessibility = PermissionItem(
        name: "Accessibility",
        why: "read Siri AI's answers from its UI tree",
        settingsPath: "Privacy & Security → Accessibility",
        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        check: { Permissions.accessibilityGranted }
    )

    static let screenRecording = PermissionItem(
        name: "Screen Recording",
        why: "power the diagnostics and OCR fallback surfaces",
        settingsPath: "Privacy & Security → Screen Recording",
        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        check: { Permissions.screenRecordingGranted }
    )
}
