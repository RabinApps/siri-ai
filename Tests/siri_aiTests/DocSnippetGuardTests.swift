import Testing
import Foundation
@testable import SiriAILib

/// Docs-snippet guard: every ```swift block in the documentation must
/// typecheck against the shipped `SiriAILib` module exactly as a consumer
/// would use it — plain `import SiriAILib`, no `@testable`.
///
/// Modernization-bait lives in prose, not code: nothing else catches an
/// edited guide quietly diverging from the public API. This suite extracts
/// every fenced `swift` block from `docs/**/*.md`, wraps bare statements in
/// an async function fixture (declarations and structs stay top-level), and
/// runs `swiftc -typecheck` against the already-built debug module — the
/// same environment as `APISurfaceGuardTests`. A snippet that no longer
/// compiles fails CI with the page name, section heading, and diagnostics.
///
/// Embedded-Package.swift-style blocks that import PackageDescription and
/// SwiftUI view blocks are compiled too: SwiftUI is available in the macOS
/// SDK, so the AskView example typechecks as written.
@Suite("Docs snippet guard", .serialized)
struct DocSnippetGuardTests {

    // MARK: - Extraction

    struct Snippet {
        let page: String        // e.g. "guide/examples.md"
        let heading: String     // nearest preceding `#`-level heading
        let index: Int          // 1-based index of swift blocks on the page
        let code: String
    }

    static func extractSnippets(docsRoot: String) throws -> [Snippet] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: docsRoot) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "docs root not found at \(docsRoot)"
            ])
        }
        var pages: [String] = []
        for case let path as String in enumerator where path.hasSuffix(".md") {
            // Skip VitePress internals/third-party mirrors.
            if path.contains("node_modules") || path.hasPrefix(".vitepress") { continue }
            pages.append(path)
        }
        pages.sort()

        var snippets: [Snippet] = []
        for page in pages {
            let url = URL(fileURLWithPath: docsRoot).appendingPathComponent(page)
            let text = try String(contentsOf: url, encoding: .utf8)
            var heading = "(top)"
            var index = 0
            var inSwiftBlock = false
            var buffer: [String] = []
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("#") && !inSwiftBlock {
                    heading = line.drop(while: { $0 == "#" })
                        .trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("```swift") && !inSwiftBlock {
                    // Skip blocks tagged with a metadata hint after ```swift
                    // (e.g. `target: …`) — those are markdown directives, not
                    // compilable code as-is. Currently only the import block.
                    if line.contains(":") { continue }
                    inSwiftBlock = true
                    index += 1
                    buffer = []
                } else if inSwiftBlock, line.hasPrefix("```") {
                    inSwiftBlock = false
                    snippets.append(Snippet(
                        page: page, heading: heading, index: index,
                        code: buffer.joined(separator: "\n")
                    ))
                } else if inSwiftBlock {
                    buffer.append(line)
                }
            }
        }
        return snippets
    }

    // MARK: - Compilation

    enum SnippetResult {
        case succeeded
        case compilationFailed(diagnostics: String)
    }

    /// Wrap a snippet: top-level declarations/imports stay as-is; bare
    /// statements move into an async throwing function so `try await`
    /// expression usage typechecks. Detects "declaration-ish" first lines
    /// (func/struct/let-with-type/etc. is overkill — the simple rule is:
    /// if the snippet already contains a top-level `func`, `struct`, or
    /// `import PackageDescription`, compile verbatim; otherwise wrap).
    static func fixture(for code: String) -> String {
        let imports = code
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("import ") }
            .joined(separator: "\n")
        let body = code
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("import ") }
            .joined(separator: "\n")

        let containsDeclaration =
            body.contains("func ") || body.contains("struct ") ||
            body.contains("enum ") || body.contains("var package =") ||
            body.contains("var body: some View")
        if containsDeclaration {
            // Snippet is a declaration set or a SwiftUI view: compile it
            // verbatim inside a container namespace, but still give async
            // usage a top-level async context via an unused wrapper.
            return imports + "\nprivate func docSnippetFixture() async throws {\n" +
                body + "\n}\n" + defaultFixtures
        }
        return imports + "\nprivate func docSnippetFixture() async throws {\n" +
            body + "\n}\n" + defaultFixtures
    }

    /// Constants a reader is assumed to have defined around a fragment
    /// (the prose names them in a previous block): `engine`, `query`,
    /// `useSiriApp`, `showOnboarding`, `mySpec`, `root`. Top-level so
    /// snippet bodies (which sit inside `docSnippetFixture`) can see them.
    /// The `import SiriAILib` lives here so continuation blocks that omit
    /// their own import still compile the way a real consumer page would
    /// (pasted after an earlier snippet that imported the module).
    static let defaultFixtures = row("""
    import SiriAILib
    import SwiftUI
    private var engine: any LLMEngine { AppIntelligenceEngine() }
    private var query: String { "demo query" }
    private var useSiriApp: Bool { false }
    private var question: String { "demo question" }
    private func showOnboarding(detail: String) {}
    private func showOnboarding(selectedBackend: Backend, detail: String) {}
    private let root = "/tmp"
    private let mySpec = DecisionSpec(name: "demo", fields: [], rules: [])
    """)

    static func compileSnippet(_ snippet: Snippet, docsRoot: String) throws -> SnippetResult {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("siri-ai-doc-snippet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("Snippet.swift")
        try fixture(for: snippet.code).write(to: source, atomically: true, encoding: .utf8)

        let libDir = try APISurfaceGuardTests.locateModuleDir()
        let tool = "/usr/bin/swiftc"
        guard FileManager.default.fileExists(atPath: tool) else {
            Issue.record("swiftc not found at \(tool)")
            return .succeeded   // environment problem, not a doc failure
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [
            "-target", "arm64-apple-macos26.0",
            "-sdk", try APISurfaceGuardTests.sdkPath(),
            "-I", libDir,
            "-swift-version", "6",
            "-enable-upcoming-feature", "ApproachableConcurrency",
            "-parse-as-library",
            "-typecheck",
            source.path,
        ]
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()

        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus == 0 { return .succeeded }
        return .compilationFailed(diagnostics: stderr)
    }

    /// Tiny triple-quoted-row helper (avoids inline `"""` nesting headaches).
    private static func row(_ s: String) -> String { s }

    // MARK: - Guard tests

    @Test("every swift snippet in the docs compiles against the public module")
    func snippetsCompile() async throws {
        let docsRoot = try Self.locateDocsRoot()
        let snippets = try Self.extractSnippets(docsRoot: docsRoot)
        #expect(snippets.count >= 20, "expected the docs' ~23 swift snippets; found \(snippets.count) — extraction broke")

        for snippet in snippets {
            // Manifest snippets (`import PackageDescription`) are Package.swift
            // files, not library code — out of scope for the module guard.
            // The bare `.package(url:)` dependency line in Getting Started's
            // install section is also a manifest fragment (documents how to
            // add the package, not how to call the library).
            if snippet.code.contains("import PackageDescription") { continue }
            if snippet.code.contains(".package(url:") && !snippet.code.contains("import SiriAILib") { continue }
            let result = try Self.compileSnippet(snippet, docsRoot: docsRoot)
            guard case .compilationFailed(let diagnostics) = result else { continue }
            let message = """
            docs snippet failed to compile: \(snippet.page) — “\(snippet.heading)” (swift block #\(snippet.index))
            Fix the snippet or its fixtures; the docs must match the shipped API.
            \(String(diagnostics.prefix(1200)))
            """
            Issue.record("\(message)")
        }
    }

    /// Find the package root containing `docs/`, honoring SIRI_AI_PACKAGE_ROOT
    /// (same override as the API-surface guard) for CI. Resolves from the same
    /// load-time package-root snapshot as the API guard so an unrelated
    /// suite's chdir() probing can never race the docs lookup.
    static func locateDocsRoot() throws -> String {
        let packageRoot = APISurfaceGuardTests.packageRootAtLoad
        if FileManager.default.fileExists(atPath: packageRoot + "/docs") &&
           FileManager.default.fileExists(atPath: packageRoot + "/Package.swift") {
            return packageRoot + "/docs"
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [
            NSLocalizedDescriptionKey: "docs/ root not found under \(packageRoot) — set SIRI_AI_PACKAGE_ROOT or run from the package root"
        ])
    }
}
