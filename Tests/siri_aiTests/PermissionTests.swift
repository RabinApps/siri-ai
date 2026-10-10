import Testing
import Foundation
@testable import siri_ai
@testable import SiriAILib

@Suite("Permission wizard", .serialized)
struct PermissionWizardTests {
    private func fakeItem(granted: Bool, name: String = "Fake Permission") -> PermissionItem {
        PermissionItem(
            name: name,
            why: "testing",
            settingsPath: "Fake Settings",
            settingsURL: "x-apple.systempreferences:com.apple.preference.fake",
            check: { granted }
        )
    }

    /// Installs stubbed answers + no-op settings opener. Returns restore.
    private func stubWizard(answers: [String]) -> @Sendable () -> Void {
        let queue = answers
        nonisolated(unsafe) var index = 0
        let previousSource = PermissionCommand.answerSource
        let previousOpener = PermissionCommand.settingsOpener
        PermissionCommand.answerSource = {
            defer { index += 1 }
            guard index < queue.count else { return "" }
            return queue[index]
        }
        PermissionCommand.settingsOpener = { _ in }   // suppress real NSWorkspace.open
        return {
            PermissionCommand.answerSource = previousSource
            PermissionCommand.settingsOpener = previousOpener
        }
    }

    @Test func checkOnlyAllGrantedExits() async throws {
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }
        let command = PermissionCommand()
        try await command.runWith(items: [fakeItem(granted: true)], checkOnlyMode: true)
        #expect(recorded.raw.joined().contains("granted"))
    }

    @Test func checkOnlyMissingExits() async {
        let command = PermissionCommand()
        do {
            do {
                try await command.runWith(items: [fakeItem(granted: false)], checkOnlyMode: true)
                #expect(Bool(false), "should have thrown ExitCode.failure")
            } catch {
                // Expected: failure exit for a missing permission.
            }
        }
    }

    @Test func wizardAllGrantedShortCircuits() async throws {
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }
        let command = PermissionCommand()
        try await command.runWith(items: [fakeItem(granted: true)], checkOnlyMode: false)
        let text = recorded.raw.joined()
        #expect(text.contains("already granted"))
        #expect(text.contains("All required permissions granted"))
    }

    @Test func wizardDeclineExitsFailure() async {
        let restore = stubWizard(answers: ["n"])
        defer { restore() }
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }
        let command = PermissionCommand()
        do {
            try await command.runWith(items: [fakeItem(granted: false)], checkOnlyMode: false)
            #expect(Bool(false), "declining should exit with failure")
        } catch {
            // Expected.
        }
        #expect(recorded.errors.joined().contains("will fail"))
    }

    @Test func wizardPollGrantsAfterFlip() async throws {
        PermissionCommand.pollIntervalSeconds = 0.01
        PermissionCommand.pollTimeoutSeconds = 5
        let restore = stubWizard(answers: ["y"])
        defer { restore() }
        let recorded = DeltaRecorder()
        RecordingTerminal.attach(recorded)
        defer { RecordingTerminal.detach(recorded) }

        // The item flips to granted on its second check — the first read
        // (pre-settings) is false, the poll loop then sees true.
        nonisolated(unsafe) var checks = 0
        let item = PermissionItem(
            name: "Flip",
            why: "testing",
            settingsPath: "Fake",
            settingsURL: "x-apple.systempreferences:com.apple.preference.fake",
            check: {
                defer { checks += 1 }
                return checks >= 1   // granted from the first poll onward
            }
        )
        try await runWizard(items: [item])
        #expect(recorded.raw.joined().contains("granted — thank you!"))
    }

    @Test func wizardPollTimesOutExits() async {
        PermissionCommand.pollIntervalSeconds = 0.01
        PermissionCommand.pollTimeoutSeconds = 0.05
        let restore = stubWizard(answers: ["y"])
        defer { restore() }
        let command = PermissionCommand()
        do {
            try await command.runWith(items: [fakeItem(granted: false)], checkOnlyMode: false)
            #expect(Bool(false), "timeout should exit with failure")
        } catch {
            // Expected.
        }
    }

    // MARK: helpers

    /// The wizard's item-check closure reads a shared flag.
    nonisolated(unsafe) static var flipped = false

    private func runWizard(items: [PermissionItem]) async throws {
        let command = PermissionCommand()
        try await command.runWith(items: items, checkOnlyMode: false)
    }
}
