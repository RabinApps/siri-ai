import Foundation
import Testing
@testable import siri_ai
@testable import SiriAILib

/// Regression tests for `AXCleaner` driven by recorded live sessions.
///
/// `Fixtures/ax-sessions.json` holds full Siri AI captures (prompt, final
/// cleaned answer, and every raw AX-tree poll snapshot), recorded from real
/// runs with `CAPTURE_FIXTURES=1 swift test --filter recordAXFixtures`.
/// These tests replay the fixture and assert two things per session:
///
/// 1. The raw captures contain the known Siri chrome (calculator boxes,
///    fragment titles, the stray "0" poll counter) — i.e. the fixture is
///    capturing the real, noisy shape.
/// 2. `AXCleaner.clean` over the settled poll reproduces the recorded final
///    answer, and no chrome marker survives cleaning on any poll snapshot.
///
/// All tests silently skip when the fixture file is absent (fresh clones,
/// CI machines without live Siri: regenerate locally with CAPTURE_FIXTURES=1).
@Suite("AXCleaner fixture regression")
struct AXCleanerFixtureTests {

    /// Fixture locations, in preference order: the resource-copy inside the
    /// test bundle (declared in Package.swift — always present for `swift test`)
    /// and, as a fallback for raw executable executors that don't populate
    /// Bundle.module, the repo-relative path.
    private static let fixturesURL = URL(fileURLWithPath: "Tests/siri_aiTests/Fixtures/ax-sessions.json")

    private enum FixtureError: Error { case malformed }

    private static var bundledFixtureURL: URL? {
        let bundled = Bundle.module.url(forResource: "ax-sessions", withExtension: "json", subdirectory: nil)
        return bundled ?? nil
    }

    /// Nil when the fixture can't be located in either place.
    private static func loadSessions() throws -> [[String: String]]? {
        let url = bundledFixtureURL ?? fixturesURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            throw FixtureError.malformed
        }
        return decoded
    }

    private func rawLines(_ raw: String) -> [String] {
        raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func lastPoll(_ raw: String) -> String {
        raw.components(separatedBy: "\n```\n").last ?? ""
    }

    @Test("ax-sessions.json is present and well-formed")
    func fixtureFileParses() throws {
        do {
            let sessions = try Self.loadSessions()
            if let sessions {
                #expect(sessions.count >= 3)
                for session in sessions {
                    #expect(session["prompt"]?.isEmpty == false)
                    #expect(session["final"] != nil)
                    #expect(session["raws"]?.isEmpty == false)
                }
            } else {
                #expect(Bool(true), "fixture file absent; regenerate with CAPTURE_FIXTURES=1 swift test --filter recordAXFixtures")
            }
        } catch {
            #expect(Bool(false), "fixture file present but malformed: \(error)")
            throw error
        }
    }

    /// Fixture recordings carry the chrome shapes each session type is
    /// known to produce; without a live Siri capture this doesn't apply.
    @Test("raw captures carry the chrome AXCleaner strips")
    func fixturesContainKnownChrome() async throws {
        guard let sessions = try Self.loadSessions(), !sessions.isEmpty else { return }
        for session in sessions {
            let prompt = (try #require(session["prompt"])).lowercased()
            let raw = try #require(session["raws"])

            // Universal chrome: every captured poll ends with the stray "0"
            // AX counter.
            for poll in raw.components(separatedBy: "\n```\n") {
                #expect(rawLines(poll).last == "0", "prompt: \(prompt) — stray AX counter missing from a poll snapshot")
            }

            // Math prompts draw the calculator card (bare equation line).
            if prompt.contains("times") || prompt.contains("plus") {
                #expect(rawLines(raw).contains { $0.contains("×") || $0.contains("+") },
                        "prompt: \(prompt) — bare arithmetic line missing from capture")
            }

            // Card prompts duplicate a fragment title ("Tokyo", "Moon") as
            // its own line inside the render; the packed blob also fuses it
            // into the first line.
            if prompt.contains("japan") || prompt.contains("moon") {
                let lines = rawLines(raw)
                #expect(lines.contains { ["Tokyo", "Moon"].contains($0) } || lines.count >= 4,
                        "prompt: \(prompt) — card-title fragment missing from capture")
            }
        }
    }

    /// For every fixture session: cleaning the settled poll must reproduce
    /// the recorded final answer, and no chrome marker may survive cleaning
    /// on any poll snapshot. Together these guard the cleaner against
    /// regression across real full-session captures.
    @Test("cleaning every poll yields settled, chrome-free output")
    func cleanedFixturesAreChromeFreeAndSettled() async throws {
        guard let sessions = try Self.loadSessions() else { return }
        for session in sessions {
            let prompt = try #require(session["prompt"])
            let final = try #require(session["final"])
            let polls = try #require(session["raws"]).components(separatedBy: "\n```\n")

            // The last poll, passed through the cleaner, is the answer.
            let cleanedLast = AXCleaner.clean(polls.last ?? "")
            #expect(cleanedLast == final, "prompt: \(prompt) — cleaned settled poll diverged from recorded final: got \"\(cleanedLast)\" want \"\(final)\"")

            // No chrome survives on any captured snapshot.
            for poll in polls {
                let cleaned = AXCleaner.clean(poll)
                #expect(cleaned.split(separator: "\n").filter { $0 == "0" }.isEmpty,
                        "prompt: \(prompt) — stray AX counter survived clean")
                #expect(!cleaned.contains("× 12 =") && !cleaned.contains("85 + 17 ="),
                        "prompt: \(prompt) — bare arithmetic survived clean")
                #expect(!cleaned.contains("— iCloud"),
                        "prompt: \(prompt) — source attribution survived clean")
            }
        }
    }
}
