import Foundation

/// Token-budget aware context assembly.
///
/// Apple's on-device model exposes a 4,096-token session window (8,192 on
/// newer machines / macOS 27) that includes both prompt and response. This
/// module decides which files to include, and how much of each, so the
/// prompt fits the budget with room left over for the model to answer.
public struct ContextBuilder: Sendable {
    public struct Result: Sendable {
        /// Assembled text block to paste into the prompt.
        public let contextText: String
        /// Files that made the cut, for attribution/debugging.
        public let includedFiles: [String]
    }

    /// Answer headroom at the minimum window (4,096). Historical flat value;
    /// kept as the anchor so machines with the documented-minimum window get
    /// exactly the same budget they always did.
    public static let answerHeadroom = 1_200
    public static let framingOverhead = 200            // generic prompt scaffolding tokens
    public static let maxFiles = 12                    // don't spam dozens of tiny fragments

    /// Budget when the caller supplies no window (tests, non-apple engines):
    /// the documented minimum on-device window, NOT a hardcoded assumption
    /// about the current machine. Production callers pass the runtime-detected
    /// size (`AppIntelligenceEngine.modelContextSize()`), which is 8,192-class
    /// on macOS 27 hardware — double these files get in.
    public static let minimumWindow = 4_096

    /// Answer headroom scales with the window: 1,200 tokens at the 4,096
    /// minimum, proportionally larger for larger windows (8,192 → ~2,400).
    /// A bigger window means both more repo files AND proportionally more
    /// room for the model to answer with detail. Clamped to leave at least
    /// 50% of any small/overridden window for context, and never below the
    /// 4,096-anchored value.
    public static func headroom(for modelContextSize: Int) -> Int {
        guard modelContextSize > 0 else { return answerHeadroom }
        let proportional = answerHeadroom * modelContextSize / minimumWindow
        let ceiling = modelContextSize / 2
        return max(answerHeadroom, min(proportional, max(answerHeadroom, ceiling)))
    }

    public let budget: Int

    /// `answerHeadroom == nil` (default) derives the value from the window via
    /// `headroom(for:)`; an explicit value (tests) wins unchanged so existing
    /// table-driven budget tests keep their exact contract.
    public init(modelContextSize: Int = Self.minimumWindow, answerHeadroom: Int? = nil) {
        self.budget = modelContextSize
        self.headroomOverride = answerHeadroom ?? Self.headroom(for: modelContextSize)
    }

    let headroomOverride: Int

    var effectiveHeadroom: Int { headroomOverride }

    /// Approximate token count for a string. The on-device tokenizer ~ clause
    /// based; ~3.5 chars per token is a conservative over-estimate that keeps
    /// us safely under budget with mixed prose+code.
    static func estimateTokens(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 3.5)))
    }

    func availableBudget() -> Int {
        budget - headroomOverride - Self.framingOverhead
    }

    /// Given discovered files and a question, pick and render the most useful
    /// subset inside the token budget.
    ///
    /// Ranking: filename matches the question terms > extension relevance >
    /// small-to-medium file size penalty (tiny files are cheap to include).
    public func build(files: [RepoFile], question: String) -> ContextBuilder.Result {
        let questionTerms = Set(
            question.lowercased()
                .split(whereSeparator: { (char: Character) in !char.isLetter && !char.isNumber })
                .map(String.init)
                .filter { $0.count > 2 }
        )

        let ranked = files
            .map { file -> (RepoFile, Int) in
                var score = 0
                let basename = (file.relativePath as NSString).lastPathComponent.lowercased()
                for term in questionTerms where basename.contains(term) {
                    score += 10
                }
                if questionTerms.contains(file.extension) { score += 6 }
                // Larger files cost budget; slight preference toward compact ones.
                if file.sizeBytes > 16 * 1024 { score -= 4 }
                if file.sizeBytes < 4 * 1024 { score += 2 }
                return (file, score)
            }
            .filter { !questionTerms.isEmpty || $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.maxFiles)
            .map(\.0)

        var used = 0
        var parts: [String] = []
        var included: [String] = []

        for file in ranked {
            guard let content = try? String(contentsOfFile: file.absolutePath, encoding: .utf8) else { continue }
            let header = "### FILE: \(file.relativePath) (\(file.extension))\n"
            let budgetForFile = availableBudget() - used
            if budgetForFile <= 80 { break }  // too little left to be useful

            // Trim content to fit the remaining budget. Account for the header
            // in the estimate and keep a small reserve for rounding.
            let headerTokens = Self.estimateTokens(header)
            let tokenRoom = max(0, (availableBudget() - used) - headerTokens - 16)
            if tokenRoom < 20 { break }
            let maxChars = tokenRoom * 35 / 10  // ~3.5 chars/token, inverted
            var body = content
            if body.count > maxChars {
                body = String(body.prefix(maxChars)) + "\n… [truncated]"
            }
            let piece = header + body + "\n"
            let pieceTokens = Self.estimateTokens(piece)
            if used + pieceTokens > availableBudget() { break }
            used += pieceTokens
            parts.append(piece)
            included.append(file.relativePath)
        }

        let contextText = parts.joined(separator: "\n")
        return ContextBuilder.Result(contextText: contextText, includedFiles: included)
    }
}
