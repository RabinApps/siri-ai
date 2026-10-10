import Foundation

public enum StdinHelper {
    /// Injectable TTY probe (tests force either branch).
    nonisolated(unsafe) static var isTTYProbe: (() -> Bool)?

    private static func isTTY() -> Bool {
        isTTYProbe.map { $0() } ?? (isatty(fileno(stdin)) == 1)
    }

    /// Returns piped stdin content if it's not an interactive TTY; empty otherwise.
    public static func readPipedInput() -> String {
        if isTTY() {
            return ""
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    /// Return true if stdin was piped (used to detect `echo foo | siri-ai ask`).
    public static func hasPipedInput() -> Bool {
        !isTTY()
    }
}

public enum HostInfo {
    public static var summary: String {
        let processInfo = ProcessInfo.processInfo
        let os = processInfo.operatingSystemVersion
        let host = Host.current().localizedName ?? "apple-silicon"
        return "macOS \(os.majorVersion).\(os.minorVersion) on \(host)"
    }
}
