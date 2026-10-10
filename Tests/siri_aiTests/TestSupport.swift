import Foundation

enum TestSupport {
    /// Opt-in gate for tests that hit the real Apple Intelligence / Siri AI app
    /// backends. Disabled everywhere by default; only the few explicitly-listed
    /// suites underneath `EngineLiveTests.swift` read this, and only after
    /// their own extra runtime guards (model availability, AX trust).
    static var liveTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["LIVE_TESTS"] == "1"
    }
}
