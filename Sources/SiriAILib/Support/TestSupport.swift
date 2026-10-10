import Foundation

// MARK: - Test support

/// Gate for live-model tests (those that hit the real Apple Intelligence model
/// or drive the Siri AI app through the Accessibility API).
///
/// These tests are **opt-in** everywhere: they are skipped on CI and on any
/// machine without the flag, and only run when `LIVE_TESTS=1` is set in the
/// process environment (typically `LIVE_TESTS=1 swift test --filter ...`).
///
/// Recording fixtures is a separate opt-in: `CAPTURE_FIXTURES=1` (see
/// `recordAXFixtures` in `EngineLiveTests` and the README).
enum TestSupport {
    /// True when live-model tests should actually exercise real backends.
    static var liveTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["LIVE_TESTS"] == "1"
    }
}
