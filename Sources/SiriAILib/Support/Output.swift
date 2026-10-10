import Foundation

/// Stdout/stderr helpers. Named `TerminalOutput` rather than `Output`
/// because `Tool` conformers have an `Output` associated type that shadows
/// a same-named enum at call sites inside those classes.
public enum TerminalOutput {
    /// Optional test tap: receives every line written. Nil in production.
    enum Stream: Sendable { case stdout, stderr }
    nonisolated(unsafe) static var tap: (@Sendable (Stream, String) -> Void)?

    /// Print to stderr; used for diagnostics so stdout stays clean for piping.
    /// Public: the CLI (and chat-style apps) legitimately print through it;
    /// library engines use it for stderr diagnostics only.
    public static func error(_ text: String) {
        tap?(.stderr, text)
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Print a line to stdout with a trailing newline.
    public static func line(_ text: String = "") {
        tap?(.stdout, text)
        print(text)
    }

    /// Print without a newline (used for streaming tokens).
    public static func raw(_ text: String) {
        tap?(.stdout, text)
        print(text, terminator: "")
        fflush(stdout)
    }
}
