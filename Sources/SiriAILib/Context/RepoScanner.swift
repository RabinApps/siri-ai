import Foundation

/// Walks a repository and returns files that are good candidates to include in
/// the context window for a code question.
///
/// Honors .gitignore (via ripgrep when present; falls back to a hand-rolled
/// ignore rule set otherwise), skips obvious binary and vendored content, and
/// caps the discovery size so a huge repo can't blow past the model's window.
public struct RepoScanner: Sendable {
    /// Never descend into these directories regardless of ignore rules.
    public static let defaultSkippedDirs: Set<String> = [
        ".git", ".build", "node_modules", "vendor", "dist",
        "build", "target", ".idea", ".vscode", "Pods",
        "DerivedData", "__pycache__", ".venv",
    ]

    /// Max scan size, in bytes, of any single file we will consider.
    public static let maxFileBytes = 64 * 1024

    public let root: String
    /// Extra subdirectories to skip, in addition to defaults.
    public let skippedDirs: Set<String>
    /// File extensions considered interesting for code Q&A.
    public let extensions: Set<String>?

    public init(root: String, skippedDirs: Set<String> = [], extensions: Set<String>? = nil) {
        self.root = root.replaceTilde
        self.skippedDirs = Self.defaultSkippedDirs.union(skippedDirs)
        self.extensions = extensions
    }

    /// Returns relative paths from `root` for all candidate files.
    public func scan() throws -> [RepoFile] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EngineError.backend("Repository path is not a directory: \(root)")
        }

        let ignoreRules = GitIgnore.load(forRoot: root)
        var files: [RepoFile] = []
        try walk(at: root, ignoreRules: ignoreRules, files: &files, relative: "")
        if files.isEmpty {
            // Ripgrep-backed fallback: when .gitignore parsing didn't produce
            // candidates, ask ripgrep to enumerate tracked/visible paths and
            // use those that survive the canonical binary/vendored/name filters.
            // Always invoke rg with an ABSOLUTE root: rg echoes paths back in
            // the form it was given, and only absolute output can be resolved
            // relative to the repo root unambiguously (a relative root would
            // anchor to the process cwd, which we don't control).
            let absoluteRoot = root.hasPrefix("/")
                ? root
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(root).path
            if let rgFiles = try? Self.scanWithRipgrep(
                root: absoluteRoot, ignoredRules: ignoreRules, instanceExtensions: extensions
            ) {
                files = rgFiles
            }
        }
        return files
    }

    private func walk(at dir: String, ignoreRules: [GitIgnoreRule], files: inout [RepoFile], relative: String) throws {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for entry in entries.sorted() {
            let full = dir + "/" + entry
            let rel = relative.isEmpty ? entry : relative + "/" + entry
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                guard !skippedDirs.contains(entry) else { continue }
                guard !GitIgnore.isIgnored(path: rel, isDirectory: true, rules: ignoreRules) else { continue }
                try walk(at: full, ignoreRules: ignoreRules, files: &files, relative: rel)
            } else {
                guard !GitIgnore.isIgnored(path: rel, isDirectory: false, rules: ignoreRules) else { continue }
                guard !Self.isProbablyBinary(at: full) else { continue }
                let ext = (entry as NSString).pathExtension.lowercased()
                if let exts = extensions, !exts.contains(ext) { continue }
                let size = ((try? fm.attributesOfItem(atPath: full)[.size]) as? NSNumber)?.intValue ?? 0
                guard size <= Self.maxFileBytes else { continue }
                files.append(RepoFile(
                    relativePath: rel,
                    absolutePath: full,
                    sizeBytes: size,
                    extension: ((entry as NSString).pathExtension.lowercased())
                ))
            }
        }
    }

    // MARK: - Ripgrep-backed fallback

    /// Test seam: exposes the private ripgrep fallback so the rg-backed path
    /// can be tested against real temporary repos without having to force the
    /// hand-rolled walk to produce nothing first.
    static func scanWithRipgrepForTesting(
        root: String,
        ignoredRules: [GitIgnoreRule],
        instanceExtensions: Set<String>?
    ) throws -> [RepoFile] {
        try scanWithRipgrep(root: root, ignoredRules: ignoredRules, instanceExtensions: instanceExtensions)
    }

    /// Ripgrep-backed enumeration fallback for repos where the hand-rolled
    /// .gitignore parser produces nothing (e.g. repos with only a global
    /// gitignore, or unusual ignore layouts it can't represent). Uses
    /// `rg --files` to enumerate paths ripgrep considers visible, then runs
    /// them through the same binary/vendored/name filters as the directory walk.
    ///
    /// Best-effort: if ripgrep is not on PATH or returns nothing, this simply
    /// returns nil and callers keep whatever the directory walk produced.
    ///
    /// `instanceExtensions` is passed in explicitly (rather than read from a
    /// static mutable) so concurrent `RepoScanner` scans can't clobber each
    /// other's extension filter.
    private static func scanWithRipgrep(
        root: String,
        ignoredRules: [GitIgnoreRule],
        instanceExtensions: Set<String>?
    ) throws -> [RepoFile] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["rg", "--files", "--no-ignore-vcs", "--hidden", root]
        let out = try process.runAndReadStdout()

        let candidatePaths = out
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var files: [RepoFile] = []
        let fm = FileManager.default
        for candidate in candidatePaths {
            guard let resolved = resolveCandidate(candidate, root: root) else {
                continue   // outside root, unresolvable, or the root itself
            }
            let absPath = resolved.absolute
            let relative = resolved.relative
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: absPath, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }

            guard !GitIgnore.isIgnored(path: relative, isDirectory: false, rules: ignoredRules) else { continue }
            guard !Self.isProbablyBinary(at: absPath) else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: absPath) else { continue }
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            guard size <= maxFileBytes else { continue }
            let ext = (relative as NSString).pathExtension.lowercased()
            if let exts = instanceExtensions, !exts.contains(ext) { continue }
            files.append(RepoFile(
                relativePath: relative,
                absolutePath: absPath,
                sizeBytes: size,
                extension: ext
            ))
        }
        return files
    }

    /// Resolves one `rg --files` output line to canonical forms:
    ///
    /// - `absolute`: the file's absolute path. rg prints paths exactly as the
    ///   root was passed: an absolute root yields absolute entries; a relative
    ///   root yields relative entries.
    /// - `relative`: the path relative to `root` ("src/a.swift") — what
    ///   RepoFile.relativePath and GitIgnore rule matching expect.
    ///
    /// Returns nil for candidates outside `root` (the old prefix check accepted
    /// lookalike siblings like root="/a/b", candidate="/a/bc/x.swift"), for
    /// unresolvable relative output, and for the root path itself.
    static func resolveCandidate(_ candidate: String, root: String) -> (absolute: String, relative: String)? {
        // Normalize the root: strip a trailing slash so prefix math is exact.
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root

        let absPath: String
        if candidate.hasPrefix("/") {
            absPath = candidate
        } else {
            // Relative rg output only resolves against an absolute root
            // (relative-to-relative anchoring would need the process cwd).
            guard normalizedRoot.hasPrefix("/") else { return nil }
            absPath = (normalizedRoot as NSString).appendingPathComponent(candidate)
        }

        guard absPath != normalizedRoot else { return nil }   // candidate IS the root
        let prefix = normalizedRoot + "/"
        guard absPath.hasPrefix(prefix) else { return nil }
        return (absPath, String(absPath.dropFirst(prefix.count)))
    }

    static func isProbablyBinary(at path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return true }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        if head.contains(0) { return true }
        if head.isEmpty { return false }
        // Heuristic: high proportion of non-printable bytes means binary.
        let sample = head.prefix(256)
        let printable = sample.filter { (32...126).contains(Int($0)) || $0 == 9 || $0 == 10 || $0 == 13 }
        return Double(printable.count) / Double(max(sample.count, 1)) < 0.95
    }
}

public struct RepoFile: Sendable, Hashable {
    public let relativePath: String
    public let absolutePath: String
    public let sizeBytes: Int
    public let `extension`: String
}

extension String {
    public var replaceTilde: String {
        guard hasPrefix("~") else { return self }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + dropFirst()
    }
}

// MARK: - .gitignore (simplified)

/// A small subset of .gitignore semantics sufficient for candidate selection:
/// literal path matches, glob via `*`/`?`, directory-only rules appending `/`,
/// and negation `!`.
struct GitIgnoreRule: Sendable {
    let pattern: String
    let isDirectoryOnly: Bool
    let negated: Bool

    init(pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        var p = trimmed
        var negated = false
        var dirOnly = false
        if p.hasPrefix("!") {
            negated = true
            p.removeFirst()
        }
        if p.hasSuffix("/") {
            dirOnly = true
            p.removeLast()
        }
        p = p.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.pattern = p.lowercased()
        self.isDirectoryOnly = dirOnly
        self.negated = negated
    }

    func matches(path lowercasedRelativePath: String, isDirectory: Bool) -> Bool {
        // A directory-only rule matches the directory itself and anything inside it.
        if isDirectoryOnly {
            let path = lowercasedRelativePath
            if path == pattern { return true }
            if path.hasPrefix(pattern + "/") { return true }
            if path.contains("/" + pattern + "/") { return true }
            return false
        }
        let path = lowercasedRelativePath
        let pattern = self.pattern
        if pattern == path { return true }
        // Match by any path segment or trailing full path as common tools do.
        if path.hasSuffix("/" + pattern) { return true }
        if path.contains("/" + pattern + "/") { return true }
        if pattern.contains("*") || pattern.contains("?") {
            return globMatch(path: path, pattern: pattern)
        }
        return false
    }

    private func globMatch(path: String, pattern: String) -> Bool {
        // Convert glob into a regex supporting * and ? with path boundaries.
        let escaped = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: "[^/]*")
            .replacingOccurrences(of: "?", with: "[^/]")
        let regex = try? NSRegularExpression(pattern: "(^|/)\(escaped)(/|$)")
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex?.firstMatch(in: path, options: [], range: range) != nil
    }
}

enum GitIgnore {
    static func load(forRoot root: String) -> [GitIgnoreRule] {
        let path = root + "/.gitignore"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let rules = contents.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#") }
            .map { GitIgnoreRule(pattern: String($0)) }
        return rules
    }

    static func isIgnored(path: String, isDirectory: Bool, rules: [GitIgnoreRule]) -> Bool {
        let lowered = path.lowercased()
        var ignored = false
        for rule in rules {
            if rule.matches(path: lowered, isDirectory: isDirectory) {
                ignored = !rule.negated
            }
        }
        return ignored
    }
}

// MARK: - lightweight Process helper

extension Process {
    /// Runs the process and returns its combined stdout+stderr as a string.
    /// Throws on non-zero exit or launch failure. Best-effort helper for
    /// lightweight shell-out (here: `rg --files`).
    func runAndReadStdout() throws -> String {
        let out = Pipe()
        let err = Pipe()
        self.standardOutput = out
        self.standardError = err
        try self.run()
        self.waitUntilExit()
        if self.terminationStatus != 0 {
            let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw EngineError.backend("External command failed (exit \(self.terminationStatus)): \(errText)")
        }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
