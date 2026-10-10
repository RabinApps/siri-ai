import Testing
import Foundation
@testable import SiriAILib

/// API-surface guard: keeps the library's test seams OUT of the public SDK.
///
/// These tests compile a small consumer fixture with a **plain** import
/// (`import SiriAILib`, NOT `@testable`) and assert that referencing a test
/// seam is a compile error. If someone flips a seam to `public` — or adds a
/// new public accessor to library state that was meant to stay internal —
/// the fixture compiles and the guard fails, breaking CI before release.
///
/// This is the language-level contract, not a symbol-table check: Swift
/// legitimately emits nm-visible metadata for internal decls, and release
/// builds dead-strip them; what must never happen is a consumer being able
/// to *name* a seam without `@testable`.
@Suite("API surface guard", .serialized)
struct APISurfaceGuardTests {

    /// One line per guarded seam: the exact expression a consumer would
    /// write to reach it. Keep in sync with the library's test hooks —
    /// adding a seam means adding a guard line here.
    static let guardedSeams: [(name: String, expression: String)] = [
        // OpenAI server: model-routing + spec-resolution overrides.
        ("OpenAIServer.routingOverride",
         "let _ = OpenAIServer.routingOverride"),
        ("OpenAIServer.setRoutingOverride",
         "_ = OpenAIServer.setRoutingOverride({ _ in nil })"),
        ("OpenAIServer.specResolutionOverride",
         "let _ = OpenAIServer.specResolutionOverride"),
        ("OpenAIServer.setDecisionSpecResolver",
         "_ = OpenAIServer.setDecisionSpecResolver({ nil }, applyImmediately: false)"),
        ("OpenAIServer.listenerForTesting",
         "_ = try OpenAIServer(port: 0, engine: AppIntelligenceEngine()).listenerForTesting()"),
        // ProposeEditTool: approval gate swap. (The Tool classes themselves
        // are internal, so a plain-import consumer sees "cannot find" — the
        // guard accepts that; the expectation below also matches it.)
        ("ProposeEditTool.approvalGateImpl",
         "let _ = ProposeEditTool.approvalGateImpl"),
        ("ProposeEditTool.setApprovalGate",
         "_ = ProposeEditTool.setApprovalGate({ _, _, _ in nil })"),
        // StdinHelper: TTY probe injection.
        ("StdinHelper.isTTYProbe",
         "let _ = StdinHelper.isTTYProbe"),
        // TerminalOutput: output capture tap.
        ("TerminalOutput.tap",
         "let _ = TerminalOutput.tap"),
        // SiriAXEngine: AX fixture capture hook + test-only observe stream.
        ("SiriAXEngine.captureSink",
         "let _ = SiriAXEngine.captureSink"),
        ("SiriAXEngine.observeForTesting",
         "_ = SiriAXEngine().observeForTesting(prompt: \"x\")"),
        // FastDecisions: drift-log internals + test-state gate.
        ("FastDecisions.agreementLog",
         "let _ = FastDecisions.agreementLog"),
        ("FastDecisions.resetAgreementLog",
         "_ = FastDecisions.resetAgreementLog()"),
        ("FastDecisions.recordAgreement",
         "_ = FastDecisions.recordAgreement(query: \"x\", model: FastDecision(needsTools: false, needsContext: false, isEditRequest: false))"),
        ("FastDecisions.debug",
         "_ = FastDecisions.debug(\"x\", FastDecision(needsTools: false, needsContext: false, isEditRequest: false), source: \"t\")"),
        ("FastDecisions.debugEnabled",
         "let _ = FastDecisions.debugEnabled"),
        ("FastDecisions.testStateLock",
         "let _ = FastDecisions.testStateLock"),
        // Internal heuristic-table detail.
        ("FastDecisionFallback.editVerbs",
         "let _ = FastDecisionFallback.editVerbs"),
        // RepoScanner: ripgrep test path (internal-only plumbing).
        ("RepoScanner.scanWithRipgrepForTesting",
         "_ = try RepoScanner.scanWithRipgrepForTesting(root: \"/tmp\", ignoredRules: [], instanceExtensions: nil)"),
        // ContextBuilder: budget internals.
        // NOTE: ContextBuilder.estimateTokens is intentionally NOT guarded:
        // it is internal by design; it only compiles via @testable.
        ("ContextBuilder.estimateTokens",
         "let _ = ContextBuilder.estimateTokens(\"x\")"),
        ("ContextBuilder.headroomOverride",
         "let b = ContextBuilder(); let _ = b.headroomOverride"),
        // Engine internals: session construction + prompts.
        ("AppIntelligenceEngine.makeSession",
         "_ = try AppIntelligenceEngine.makeSession(system: nil, tools: nil)"),
        ("AppIntelligenceEngine.options",
         "_ = AppIntelligenceEngine.options(for: EngineRequest(prompt: \"x\"))"),
        ("FastDecisionEngine.makeSession",
         "let _ = FastDecisionEngine.makeSession()"),
        ("FastDecisionEngine.withTimeout",
         "_ = try await FastDecisionEngine.withTimeout(seconds: 0.001) { () async throws -> Int in 1 }"),
        // DecisionSpec internals.
        ("DecisionRuleEvaluator.evaluateInternal",
         "let _ = DecisionRuleEvaluator.matches(spec: DecisionSpec(name: \"s\", fields: [], rules: []), rule: DecisionRule(conditions: [], effects: []), values: [:])"),
        ("DecisionSpecParser internals",
         "let _ = DecisionSpecParser.stripComment(\"x\")"),
        ("DecisionSchemaCompiler",
         "let _ = try DecisionSchemaCompiler.schema(for: DecisionSpec(name: \"s\", fields: [], rules: []))"),
        // AX internals.
        ("AXCleaner",
         "let _ = AXCleaner.clean(\"x\")"),
        ("AXEvent",
         "let e: AXEvent? = nil; _ = e"),
    ]

    /// Compile error message marker for language-level access denial.
    static let inaccessibleMarker = "inaccessible due to"

    /// Stand-in for the listenerForTesting guard line: the public init needs
    /// a concrete engine; this helper template is emitted into the fixture.
    static func engineTemplate() -> String { "AppIntelligenceEngine()" }

    // MARK: - Guard tests

    @Test("every test seam is inaccessible from a plain consumer import")
    func seamsAreNotPublic() async throws {
        for seam in Self.guardedSeams {
            let result = try Self.compileConsumerFixture(body: seam.expression)
            guard case .compilationFailed(let diagnostics) = result else {
                // .succeeded here is the FAILURE case: the fixture compiled,
                // meaning the seam is (now) public and reachable from a plain
                // consumer import. Fail with an actionable message.
                Issue.record("seam \(seam.name) is reachable from a plain import — it became public (or gained a public accessor). \(Self.fixHint)")
                continue
            }
            #expect(
                diagnostics.contains(Self.inaccessibleMarker) || diagnostics.contains("has no member")
                    || diagnostics.contains("cannot find"),
                "seam \(seam.name) is reachable from a plain import — it became public (or gained a public accessor). Keep library test hooks internal: \(Self.fixHint)"
            )
        }
    }

    @Test("public SDK surface is still usable from a plain consumer import")
    func publicSurfaceStillCompiles() async throws {
        // The inverse control: the documented SDK entry points must compile
        // WITHOUT @testable. If this fails after a refactor, the guard
        // environment itself broke (not the API).
        let body = """
        let engine = AppIntelligenceEngine()
        let request = EngineRequest(prompt: "hello")
        let decision = await FastDecisions.route(query: "status check", backend: .siri)   // synchronous, no model call
        let backend: Backend = .apple
        _ = engine
        _ = request
        _ = decision
        _ = backend
        """
        let result = try Self.compileConsumerFixture(body: body)
        switch result {
        case .succeeded:
            break
        case .compilationFailed(let diagnostics):
            Issue.record("documented public API failed to compile from a plain import — check the guard fixture setup: \(diagnostics.prefix(400))")
        }
    }

    // MARK: - Fixture plumbing

    private static let fixHint = "Revert the visibility change: test hooks live at `internal` and are reached via `@testable import SiriAILib`."

    enum FixtureResult {
        case succeeded
        case compilationFailed(diagnostics: String)
    }

    /// Compile a single-file consumer against the already-built debug module.
    /// Uses the SwiftPM build products directory discovered from the test
    /// bundle location (`.build/out/Products/Debug`), so no package rebuild
    /// is triggered from inside the test run.
    static func compileConsumerFixture(body: String) throws -> FixtureResult {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("siri-ai-api-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("Consumer.swift")
        let fixtureText = "import SiriAILib\nfunc consumer() async {\n" + body + "\n}\n"
        try fixtureText.write(to: source, atomically: true, encoding: .utf8)

        let libDir = try locateModuleDir()
        let tool = "/usr/bin/swiftc"
        guard FileManager.default.fileExists(atPath: tool) else {
            Issue.record("swiftc not found at \(tool)")
            return .succeeded   // environment problem, not an API failure
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [
            "-target", "arm64-apple-macos26.0",
            "-sdk", try sdkPath(),
            "-I", libDir,
            "-swift-version", "6",
            "-enable-upcoming-feature", "ApproachableConcurrency",
            "-parse-as-library",
            "-typecheck",
            source.path,
        ]
        // Note: `-typecheck` avoids linking (FoundationModels link infra isn't set up
        let out = Pipe(); let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()

        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus == 0 {
            // Guard failure: the seam compiled — meaning it is now public.
            return .succeeded
        }
        return .compilationFailed(diagnostics: stderr)
    }

    /// Find the directory containing SiriAILib.swiftmodule. Prefer an
    /// explicitly provided env override so CI can point anywhere; otherwise
    /// resolve from a snapshot of the package root taken once at test-module
    /// load, NOT from the live CWD — DecisionSpecServeTests legitimately
    /// chdir()s for its resolver probes and would race this lookup when the
    /// suites run in parallel.
    static let packageRootAtLoad: String = {
        if let overridden = ProcessInfo.processInfo.environment["SIRI_AI_PACKAGE_ROOT"] {
            return overridden
        }
        var dir = FileManager.default.currentDirectoryPath
        // Test streams can already be inside .build; walk up to Package.swift.
        for _ in 0...6 {
            if FileManager.default.fileExists(atPath: dir + "/Package.swift") { return dir }
            let parent = URL(fileURLWithPath: dir).deletingLastPathComponent().path
            if parent == dir { break }
            dir = parent
        }
        return FileManager.default.currentDirectoryPath
    }()

    static func locateModuleDir() throws -> String {
        #if SWIFT_PACKAGE
        // Resolve from the package root snapshotted at module load.
        let packageRoot = packageRootAtLoad
        let candidates = [
            "\(packageRoot)/.build/out/Products/Debug",
            "\(packageRoot)/.build/debug",
            "\(packageRoot)/.build/arm64-apple-macosx/debug",
        ]
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate + "/SiriAILib.swiftmodule") {
                return candidate
            }
        }
        #endif
        throw CocoaError(.fileNoSuchFile, userInfo: [
            NSLocalizedDescriptionKey: "SiriAILib.swiftmodule not found — build the package (swift build) before running the API-guard suite, or set SIRI_AI_PACKAGE_ROOT."
        ])
    }

    static func sdkPath() throws -> String {
        let macosx = ("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform" as NSString)
            .appendingPathComponent("Developer/SDKs/MacOSX.sdk")
        if FileManager.default.fileExists(atPath: macosx) { return macosx }
        // Fall back to the default SDK as reported by xcrun.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--show-sdk-path"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !path.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "could not resolve the macOS SDK path"])
        }
        return path
    }
}
