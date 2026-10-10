import Foundation
import FoundationModels

/// Model-driven edit proposal: the model describes a whole-file replacement or
/// a find/replace; we put it in front of the user in the terminal and only
/// write to disk after explicit confirmation. Safest possible agentic edit.
final class ProposeEditTool: Tool, @unchecked Sendable {
    let name = "propose_edit"
    // Kept terse: every tool schema costs prompt tokens against the
    // on-device model's 4,096-token window.
    let description = "Propose a find/replace or full rewrite. User confirms before it applies."

    @Generable
    struct Arguments {
        @Guide(description: "File path relative to root; absolute paths work too.")
        var path: String
        @Guide(description: "Text to replace (used with replacement).")
        var find: String?
        @Guide(description: "Replacement for find; ignored when new_content is set.")
        var replacement: String?
        @Guide(description: "Full new content, replaces everything.")
        var new_content: String?
    }

    private let rootPath: String?
    private let requireConfirmation: Bool

    init(root: String?, requireConfirmation: Bool) {
        self.rootPath = root?.replaceTilde
        self.requireConfirmation = requireConfirmation
    }

    func call(arguments: Arguments) async throws -> GeneratedContent {
        let path = ReadFileTool.resolve(path: arguments.path, base: rootPath ?? FileManager.default.currentDirectoryPath)
        let current = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let proposed: String
        if let newContent = arguments.new_content {
            proposed = Self.unescape(newContent, reference: current)
        } else if let find = arguments.find, let replacement = arguments.replacement {
            let fixedFind = Self.unescape(find, reference: current)
            let fixedReplacement = Self.unescape(replacement, reference: current)
            guard current.contains(fixedFind) else {
                return GeneratedContent("Could not find the text to replace in \(arguments.path). No changes made.")
            }
            proposed = current.replacingOccurrences(of: fixedFind, with: fixedReplacement)
        } else {
            return GeneratedContent("Provide either find+replacement, or new_content. No changes made.")
        }

        if requireConfirmation {
            let approved = await ProposeEditTool.approvalGate(
                old: current,
                new: proposed,
                path: path
            )
            guard approved else {
                return GeneratedContent("The user declined this edit. No changes were made.")
            }
        }
        do {
            try proposed.write(toFile: path, atomically: true, encoding: .utf8)
            return GeneratedContent("Edit applied to \(arguments.path).")
        } catch {
            return GeneratedContent("Failed to write \(arguments.path): \(error.localizedDescription)")
        }
    }

    /// Small language models sometimes emit escaped sequences (\n, \t, \")
    /// literally inside tool arguments. When the target file uses real
    /// newlines and the proposed text contains none but does contain the
    /// two-character `\n` sequence, interpret those as real characters.
    static func unescape(_ text: String, reference: String) -> String {
        let hasRealNewline = text.contains("\n")
        let hasEscapedNewline = text.contains("\\n")
        let referenceIsMultiline = reference.contains("\n")
        guard !hasRealNewline, hasEscapedNewline, referenceIsMultiline else { return text }
        return text
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Injectable y/N gate: the interactive version renders a diff and reads
    /// approval from stdin; tests can swap in a canned decision via
    /// `setApprovalGate` so `call()` flows are testable end to end.
    nonisolated(unsafe) static var approvalGateImpl: (@Sendable (String, String, String) async -> Bool)?

    /// Swap the approval decision for tests. Returns a restore closure.
    @discardableResult
    static func setApprovalGate(
        _ impl: @escaping @Sendable (String, String, String) async -> Bool?
    ) -> @Sendable () -> Void {
        let previous = approvalGateImpl
        approvalGateImpl = { old, new, path in
            guard let answer = await impl(old, new, path) else {
                return await interactiveConfirm(old: old, new: new, path: path)
            }
            return answer
        }
        return { approvalGateImpl = previous }
    }

    static func approvalGate(old: String, new: String, path: String) async -> Bool {
        if let gate = approvalGateImpl {
            return await gate(old, new, path)
        }
        return await ProposeEditTool.interactiveConfirm(old: old, new: new, path: path)
    }

    /// Render a unified diff to the terminal and block on a y/n answer.
    static func interactiveConfirm(old: String, new: String, path: String) async -> Bool {
        let diffLines = Self.diffSummary(old: old, new: new)
        TerminalOutput.raw("\n── Proposing edit to \(path) ──\n")
        for line in diffLines {
            TerminalOutput.raw(line + "\n")
        }
        TerminalOutput.raw("Apply this change? [y/N] ")
        let answer = await Self.readApproval()
        TerminalOutput.line("")
        return answer
    }

    private static func readApproval() async -> Bool {
        // Standard input can block the whole actor; read on a background thread.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                guard let line = readLine() else {
                    continuation.resume(returning: false)
                    return
                }
                let normalized = line.trimmingCharacters(in: .whitespaces).lowercased()
                continuation.resume(returning: normalized == "y" || normalized == "yes")
            }
        }
    }

    /// A simple LCS-free block diff: finds the common prefix and suffix of the
    /// two texts' line arrays and shows only the changed block between them.
    /// Good enough for find/replace and whole-file rewrites, where the edit is
    /// contiguous — not for scattered multi-hunk edits.
    static func diffSummary(old: String, new: String) -> [String] {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Common prefix
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count,
              oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        // Common suffix
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        var lines: [String] = []
        let oldStart = prefix, oldEnd = oldLines.count - suffix
        let newStart = prefix, newEnd = newLines.count - suffix
        for index in oldStart..<oldEnd {
            lines.append("- \(oldLines[index])")
        }
        for index in newStart..<newEnd {
            lines.append("+ \(newLines[index])")
        }
        return lines.isEmpty ? ["(no changes)"] : Array(lines.prefix(120))
    }
}
