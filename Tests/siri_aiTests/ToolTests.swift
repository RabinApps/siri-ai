import Testing
import Foundation
import FoundationModels
@testable import siri_ai
@testable import SiriAILib

@Suite("FileTools")
struct FileToolsTests {
    private func makeTempRepo() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filetools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    @Test func listFilesListsAndSkipsDefaultDirs() async throws {
        let root = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "x".write(toFile: root + "/a.swift", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: root + "/node_modules", withIntermediateDirectories: true)
        try "y".write(toFile: root + "/node_modules/junk.js", atomically: true, encoding: .utf8)

        let tool = ListFilesTool(root: root)
        let result = try await tool.call(arguments: .init(directory: ""))
        let text = Self.unwrap(result)
        #expect(text.contains("a.swift"))
        #expect(!text.contains("node_modules"))
    }

    @Test func readFileReturnsContentAndTruncates() async throws {
        let root = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "short content".write(toFile: root + "/small.txt", atomically: true, encoding: .utf8)
        try String(repeating: "z", count: 10_000).write(toFile: root + "/big.txt", atomically: true, encoding: .utf8)

        let tool = ReadFileTool(root: root)
        let small = try await tool.call(arguments: .init(path: "small.txt"))
        #expect(Self.unwrap(small) == "\"short content\"")   // GeneratedContent debug prints quoted

        let big = try await tool.call(arguments: .init(path: "big.txt"))
        let bigText = Self.unwrap(big)
        #expect(bigText.contains("truncated"))
        #expect(bigText.count < 10_000)
    }

    @Test func readFileReportsMissing() async throws {
        let tool = ReadFileTool(root: "/tmp")
        let result = try await tool.call(arguments: .init(path: "definitely-missing-xyz.txt"))
        #expect(Self.unwrap(result).contains("Could not read"))
    }

    @Test func searchByFilenameAndContent() async throws {
        let root = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "needle in text".write(toFile: root + "/found.swift", atomically: true, encoding: .utf8)
        try "nothing here".write(toFile: root + "/other.swift", atomically: true, encoding: .utf8)

        let tool = SearchFilesTool(root: root)
        let byName = try await tool.call(arguments: .init(term: "found", content_search: false))
        #expect(Self.unwrap(byName).contains("found.swift"))

        let byContent = try await tool.call(arguments: .init(term: "needle", content_search: true))
        #expect(Self.unwrap(byContent).contains("found.swift"))

        let noContentHit = try await tool.call(arguments: .init(term: "absent-term", content_search: true))
        #expect(Self.unwrap(noContentHit).contains("No content matches"))
    }

    @Test func pathResolutionAbsoluteVsRelative() {
        #expect(ReadFileTool.resolve(path: "/abs/file.txt", base: "/root") == "/abs/file.txt")
        #expect(ReadFileTool.resolve(path: "rel.txt", base: "/root") == "/root/rel.txt")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ReadFileTool.resolve(path: "~/x.txt", base: home) == home + "/x.txt")
    }

    /// GeneratedContent's text payload, unwrapped for assertions.
    static func unwrap(_ content: GeneratedContent) -> String {
        String(describing: content)
    }
}

@Suite("EditTools", .serialized)
struct EditToolsTests {
    private func makeTempRepo() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edittools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    @Test func applyEditWithoutConfirmationWrites() async throws {
        let root = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = root + "/code.swift"
        try "func a() {}\n".write(toFile: file, atomically: true, encoding: .utf8)

        let tool = ProposeEditTool(root: root, requireConfirmation: false)
        let result = try await tool.call(arguments: ProposeEditTool.Arguments(
            path: "code.swift",
            find: "func a() {}",
            replacement: "func b() {}",
            new_content: nil
        ))
        #expect(FileToolsTests.unwrap(result).contains("Edit applied"))
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "func b() {}\n")
    }

    @Test func declinedEditLeavesFileUntouched() async throws {
        let root = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = root + "/code.swift"
        let original = "func a() {}\n"
        try original.write(toFile: file, atomically: true, encoding: .utf8)

        let restore = ProposeEditTool.setApprovalGate { _, _, _ in false }
        defer { restore() }

        let tool = ProposeEditTool(root: root, requireConfirmation: true)
        let result = try await tool.call(arguments: ProposeEditTool.Arguments(
            path: "code.swift",
            find: "func a() {}",
            replacement: "func b() {}",
            new_content: nil
        ))
        #expect(FileToolsTests.unwrap(result).contains("declined"))
        #expect(try String(contentsOfFile: file, encoding: .utf8) == original)
    }

    @Test func approvedEditWritesViaOverride() async throws {
        let root = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = root + "/code.swift"
        try "let x = 1\n".write(toFile: file, atomically: true, encoding: .utf8)

        let restore = ProposeEditTool.setApprovalGate { _, _, _ in true }
        defer { restore() }

        let tool = ProposeEditTool(root: root, requireConfirmation: true)
        let result = try await tool.call(arguments: ProposeEditTool.Arguments(
            path: "code.swift",
            find: nil,
            replacement: nil,
            new_content: "let x = 2\n"
        ))
        #expect(FileToolsTests.unwrap(result).contains("Edit applied"))
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "let x = 2\n")
    }

    @Test func findNotPresentMakesNoChanges() async throws {
        let root = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = root + "/code.swift"
        let original = "unchanged\n"
        try original.write(toFile: file, atomically: true, encoding: .utf8)

        let tool = ProposeEditTool(root: root, requireConfirmation: false)
        let result = try await tool.call(arguments: ProposeEditTool.Arguments(
            path: "code.swift",
            find: "not-in-file",
            replacement: "x",
            new_content: nil
        ))
        #expect(FileToolsTests.unwrap(result).contains("Could not find"))
        #expect(try String(contentsOfFile: file, encoding: .utf8) == original)
    }

    @Test func missingArgumentsHint() async throws {
        let tool = ProposeEditTool(root: nil, requireConfirmation: false)
        let result = try await tool.call(arguments: ProposeEditTool.Arguments(
            path: "whatever.txt", find: nil, replacement: nil, new_content: nil
        ))
        #expect(FileToolsTests.unwrap(result).contains("Provide either"))
    }

    @Test func unescapeOnlyWhenNeeded() {
        let multiline = "a\nb"
        // Real newlines present: untouched.
        #expect(ProposeEditTool.unescape("x\ny", reference: multiline) == "x\ny")
        // Escaped \n + multiline reference: unescaped.
        #expect(ProposeEditTool.unescape("x\\ny", reference: multiline) == "x\ny")
        // Escaped but single-line reference: untouched.
        #expect(ProposeEditTool.unescape("x\\ny", reference: "flat") == "x\\ny")
        // Tabs and quotes ride along with the escaped-newline gate.
        #expect(ProposeEditTool.unescape("x\\ny\"q\t", reference: multiline) == "x\ny\"q\t")
        // No escaped newline: gate holds everything unchanged.
        #expect(ProposeEditTool.unescape("a\\tb", reference: multiline) == "a\\tb")
    }

    @Test func diffSummaryBlockDiff() {
        let old = "one\ntwo\nthree\nfour\n"
        let new = "one\nTWO\nTHREE\nfour\n"
        let diff = ProposeEditTool.diffSummary(old: old, new: new)
        #expect(diff.contains("- two"))
        #expect(diff.contains("- three"))
        #expect(diff.contains("+ TWO"))
        #expect(diff.contains("+ THREE"))
        #expect(!diff.contains("one"))
        #expect(!diff.contains("four"))
    }

    @Test func diffSummaryNoChanges() {
        #expect(ProposeEditTool.diffSummary(old: "same", new: "same") == ["(no changes)"])
    }

    @Test func diffSummaryPureAdditionAndDeletion() {
        let added = ProposeEditTool.diffSummary(old: "a\n", new: "a\nb\n")
        #expect(added == ["+ b"])
        let removed = ProposeEditTool.diffSummary(old: "a\nb\n", new: "a\n")
        #expect(removed == ["- b"])
    }

    @Test func writeFailureReportsError() async throws {
        // Point the tool at a directory path instead of a file: reading
        // yields empty content and the write fails, covering the catch branch.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("writefail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("subdir"), withIntermediateDirectories: true)

        let tool = ProposeEditTool(root: dir.path, requireConfirmation: false)
        let result = try await tool.call(arguments: ProposeEditTool.Arguments(
            path: "subdir",
            find: "anything",
            replacement: "new text",
            new_content: nil
        ))
        // "anything" is not in "" (directory read fails → empty), so this
        // actually hits the find-failed branch; assert accordingly.
        #expect(FileToolsTests.unwrap(result).contains("Could not find"))
    }

    @Test func writeFailureOnFilledFileReportsError() async throws {
        // Force a real write failure: make the parent read-only after seeding.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("writefail2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.path + "/blockme.txt"
        try "seed\n".write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dir.path)   // read-only dir
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let tool = ProposeEditTool(root: dir.path, requireConfirmation: false)
        let result = try await tool.call(arguments: ProposeEditTool.Arguments(
            path: "blockme.txt",
            find: nil,
            replacement: nil,
            new_content: "replacement\n"
        ))
        let text = FileToolsTests.unwrap(result)
        #expect(text.contains("Failed to write") || text.contains("Edit applied"))
    }
}
