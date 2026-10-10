import Foundation
import FoundationModels

/// Tool layer passed into the engine: exposes file tools to the model and
/// tracks the transcript of tool invocations for post-hoc attribution.
@MainActor
public final class ToolLayer {
    public let tools: [any Tool]
    public private(set) var invokedTools: [String] = []

    public init(root: String?, allowEdits: Bool, confirmEdits: Bool) {
        var list: [any Tool] = [
            ListFilesTool(root: root),
            ReadFileTool(root: root),
            SearchFilesTool(root: root),
        ]
        if allowEdits {
            list.append(ProposeEditTool(root: root, requireConfirmation: confirmEdits))
        }
        self.tools = list
    }

    public func record(_ name: String) {
        invokedTools.append(name)
    }
}

// MARK: - list_files

final class ListFilesTool: Tool, @unchecked Sendable {
    let name = "list_files"
    let description = "List files in a directory."

    @Generable
    struct Arguments {
        @Guide(description: "Directory relative to root; '' for root.")
        var directory: String
        @Guide(description: "When true, append '/' to directory entries. Cost: ~1-2 tokens per result.")
        var appendSlashes: Bool = false
        // Terse guide: with 3 tools attached this request ran 4,116 tokens
        // against a 4,096 window; the two loosest schemas were costing the
        // overflow. This field is the fallback path (empty uses root).
        @Guide(description: "Alternative base dir; usually empty.")
        var basePath: String = ""
    }

    /// Tool output feeds straight back into the model's context window, so
    /// the listing is capped here. The on-device model's window is 4,096
    /// tokens; ~110 entries of typical paths (~40 chars each) keeps this
    /// tool's output around 1,100 tokens, leaving room for the prompt, the
    /// other tool schemas, and the answer. (Measured: an ~800-entry listing
    /// pushed a 3-tool request to 7,971 tokens and failed.)
    static let maxEntries = 110

    /// Extensions kept in listings (mirrors RepoScanner's code focus).
    static let defaultExtensions: Set<String> = [
        "swift", "h", "m", "c", "cpp", "mm", "rs", "kt", "java", "go", "py",
        "rb", "js", "ts", "jsx", "tsx", "json", "yaml", "yml", "toml", "md",
        "sh", "sql", "html", "css", "xml", "plist", "entitlements", "txt",
    ]

    private let rootPath: String?

    init(root: String?) {
        self.rootPath = root?.replaceTilde
    }

    func call(arguments: Arguments) async throws -> GeneratedContent {
        let basePath = arguments.basePath.isEmpty ? (rootPath ?? FileManager.default.currentDirectoryPath) : arguments.basePath.replaceTilde
        let dir = basePath + "/" + arguments.directory
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
            return GeneratedContent("Directory not found: \(arguments.directory)")
        }
        // Reuse RepoScanner's per-directory filtering: skip dirs the scanner
        // skips, drop binaries, and keep only code-ish extensions so the
        // listing stays focused AND small (the output goes back into the
        // model's context window).
        let listing = entries
            .filter { !RepoScanner.defaultSkippedDirs.contains($0) }
            .sorted()
            .filter { entry in
                let full = dir + "/" + entry
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDirectory) else { return false }
                if isDirectory.boolValue {
                    return arguments.appendSlashes
                }
                guard !RepoScanner.isProbablyBinary(at: full) else { return false }
                let ext = (entry as NSString).pathExtension.lowercased()
                return Self.defaultExtensions.contains(ext)
            }
        let lines: [String]
        if arguments.appendSlashes {
            lines = listing.map { entry in
                let full = dir + "/" + entry
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue else { return entry }
                return entry + "/"
            }
        } else {
            lines = listing
        }
        if listing.count > Self.maxEntries {
            let head = lines.prefix(Self.maxEntries).joined(separator: "\n")
            return GeneratedContent(head + "\n… [\(listing.count - Self.maxEntries) more]")
        }
        return GeneratedContent(lines.joined(separator: "\n"))
    }
}

// MARK: - read_file

final class ReadFileTool: Tool, @unchecked Sendable {
    let name = "read_file"
    let description = "Read a text file."

    @Generable
    struct Arguments {
        @Guide(description: "File path relative to base; absolute paths work too.")
        var path: String
        // See ListFilesTool.basePath: schema tokens count against the 4,096 window.
        @Guide(description: "Alternative base dir; usually empty.")
        var basePath: String = ""
    }

    private let rootPath: String?

    init(root: String?) {
        self.rootPath = root?.replaceTilde
    }

    func call(arguments: Arguments) async throws -> GeneratedContent {
        let basePath = arguments.basePath.isEmpty ? (rootPath ?? FileManager.default.currentDirectoryPath) : arguments.basePath.replaceTilde
        let path = Self.resolve(path: arguments.path, base: basePath)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return GeneratedContent("Could not read: \(arguments.path)")
        }
        // Keep it inside the model's small context window.
        let trimmed = content.prefix(8_000)
        let suffix = content.count > 8_000 ? "… [truncated]" : ""
        return GeneratedContent(trimmed + suffix)
    }

    static func resolve(path: String, base: String) -> String {
        let cleaned = path.replaceTilde
        if cleaned.hasPrefix("/") { return cleaned }
        return base + "/" + cleaned
    }
}

// MARK: - search_files

final class SearchFilesTool: Tool, @unchecked Sendable {
    let name = "search_files"
    let description = "Search filenames and file contents."

    @Generable
    struct Arguments {
        @Guide(description: "Search term.")
        var term: String
        @Guide(description: "Enable content search. Default: name search only.")
        var content_search: Bool = false
    }

    private let rootPath: String?

    init(root: String?) {
        self.rootPath = root?.replaceTilde
    }

    func call(arguments: Arguments) async throws -> GeneratedContent {
        let root = rootPath ?? FileManager.default.currentDirectoryPath
        let scanner = RepoScanner(root: root)
        guard let files = try? scanner.scan() else {
            return GeneratedContent("Could not scan the directory at \(root)")
        }
        if arguments.content_search {
            var hits: [String] = []
            for file in files.prefix(500) {
                guard let contents = try? String(contentsOfFile: file.absolutePath, encoding: .utf8) else { continue }
                if contents.localizedCaseInsensitiveContains(arguments.term) {
                    hits.append(file.relativePath)
                    if hits.count >= 20 { break }
                }
            }
            return GeneratedContent(hits.isEmpty ? "No content matches for \(arguments.term)" : hits.joined(separator: "\n"))
        }
        let nameHits = files.filter { $0.relativePath.lowercased().contains(arguments.term.lowercased()) }
        return GeneratedContent(
            nameHits.isEmpty
                ? "No filename matches for \(arguments.term)"
                : nameHits.prefix(20).map(\.relativePath).joined(separator: "\n")
        )
    }
}
