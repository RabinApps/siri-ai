import Foundation
import FoundationModels

// MARK: - Decision spec model ("System 1" user-defined schemas)
//
// A user supplies a small decision-spec file (`.decision-spec`) that declares
// a typed output schema (fields with descriptions) and routing rules that map
// the model's field values onto routing outcomes. The spec fully replaces the
// built-in FastDecision schema when provided.

/// One declared field in a user decision spec.
public struct DecisionField: Sendable, Equatable {
    public init(name: String, kind: Kind, description: String, allowedValues: [String] = [], optional: Bool = false, defaultBool: Bool? = nil) {
        self.name = name
        self.kind = kind
        self.description = description
        self.allowedValues = allowedValues
        self.optional = optional
        self.defaultBool = defaultBool
    }
    /// Field kind in the generated schema.
    public enum Kind: String, Sendable {
        case bool
        case string
        case int
    }

    public let name: String
    public let kind: Kind
    /// Semantics of the field, shown to the model as the property description.
    public let description: String
    /// For string fields: the allowed value set (renders as `anyOf`).
    public let allowedValues: [String]
    /// True when the model may leave this field out (optional property).
    public let optional: Bool
    /// Optional default for optional bool/int fields when the model omits it.
    public let defaultBool: Bool?

    public static func == (a: DecisionField, b: DecisionField) -> Bool {
        a.name == b.name && a.kind == b.kind && a.description == b.description
            && a.allowedValues == b.allowedValues && a.optional == b.optional && a.defaultBool == b.defaultBool
    }
}

/// One condition inside a rule: field must equal this value (or, for int
/// fields, be at least `minimum` when the condition used `>=`).
public struct DecisionCondition: Sendable, Equatable {
    public init(field: String, equals: String, minimum: Int? = nil) {
        self.field = field
        self.equals = equals
        self.minimum = minimum
    }

    public let field: String
    public let equals: String
    /// nil for plain equality; set for `field>=n` int-floor conditions.
    public var minimum: Int? = nil
}

/// One rule: when every listed condition matches the model's values, apply
/// ALL its effects. Rules are evaluated in order; every matching rule's
/// effects apply (later rules win on conflict).
public struct DecisionRule: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        case useTools
        case useContext
        case applyEdit
        // Complementary outcomes (rule negatives for the default-true fields).
        case noTools
        case noContext
        case noEdit
    }

    public init(conditions: [DecisionCondition], effects: [Outcome]) {
        self.conditions = conditions
        self.effects = effects
    }

    /// Keyed by field name; compared against the model's value.
    public let conditions: [DecisionCondition]
    /// Outcomes to apply when all conditions match.
    public let effects: [Outcome]
}

/// Parsed user decision spec: the schema plus the rules.
public struct DecisionSpec: Sendable, Equatable {
    public init(name: String, fields: [DecisionField], rules: [DecisionRule]) {
        self.name = name
        self.fields = fields
        self.rules = rules
    }

    public let name: String
    public let fields: [DecisionField]
    public let rules: [DecisionRule]

    /// Canonical filename for repo-level auto-discovery.
    public static let fileName = "decisions.spec"
    /// Directory (relative to repo root) auto-discovered from.
    public static let discoveryDirectory = ".siri-ai"
    public static let discoveryPath = discoveryDirectory + "/" + fileName

    public static func == (a: DecisionSpec, b: DecisionSpec) -> Bool {
        a.name == b.name && a.fields == b.fields && a.rules == b.rules
    }
}

/// Parse errors carry a line number and a fix-it hint.
public struct DecisionSpecError: LocalizedError, Sendable {
    public let line: Int
    public let message: String
    public let hint: String

    public var errorDescription: String? {
        "decisions spec line \(line): \(message)"
    }
}

// MARK: - Parser (line-oriented custom syntax)

/// Line-oriented decision-spec grammar:
///
///   # comment
///   name "Repo triage"
///   field needsDocs:bool "True when the answer needs the docs/ folder"
///   field mode:string[tune|explain] "How to answer" optional
///   field complexity:int(0-9) optional -- as int via a number guide
///   rule mode==tune, complexity>=3 -> useTools useContext
///   rule needsDocs==true -> useContext
///
/// Grammar:
///   name <string literal>
///   field <ident>:<kind>[<args>] <string literal> [optional]
///        kind args: bool -> none
///                   string -> allowlisted values [a|b|c]
///                   int    -> range (lo-hi)
///   rule <conditions> -> <outcomes>
///        condition:  field==value  (string/bool)  |  field>=n (int floors)
///        outcome:    useTools|useContext|applyEdit|noTools|noContext|noEdit
public enum DecisionSpecParser {
    public static func parse(_ text: String) throws -> DecisionSpec {
        var name = "UserDecision"
        var fields: [DecisionField] = []
        var rules: [DecisionRule] = []

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lineNo = index + 1
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let keyword = tokens.first else { continue }

            switch keyword {
            case "name":
                guard tokens.count >= 2, let literal = capturedQuoted(line) else {
                    throw DecisionSpecError(line: lineNo, message: "`name` needs a quoted name", hint: "name \"Triage decisions\"")
                }
                name = literal
            case "field":
                let field = try parseField(line: line, tokens: tokens, lineNo: lineNo)
                guard !fields.contains(where: { $0.name == field.name }) else {
                    throw DecisionSpecError(line: lineNo, message: "duplicate field `\(field.name)`", hint: "each field name must be unique")
                }
                fields.append(field)
            case "rule":
                let rule = try parseRule(line: line, tokens: tokens, lineNo: lineNo, fields: fields)
                rules.append(rule)
            default:
                throw DecisionSpecError(
                    line: lineNo,
                    message: "unknown keyword `\(keyword)`",
                    hint: "expected `name`, `field`, or `rule`"
                )
            }
        }

        guard !fields.isEmpty else {
            throw DecisionSpecError(line: 1, message: "spec declares no fields", hint: "add at least one `field` line")
        }
        // Safer default: extension field optional bool default false.
        let seenNames = Set(fields.map(\.name))
        for rule in rules {
            for condition in rule.conditions {
                guard seenNames.contains(condition.field) else {
                    throw DecisionSpecError(
                        line: 1,
                        message: "rule references unknown field `\(condition.field)`",
                        hint: "declare `field \(condition.field):...` before using it in a rule"
                    )
                }
            }
        }
        return DecisionSpec(name: name, fields: fields, rules: rules)
    }

    static func stripComment(_ line: String) -> String {
        guard let hashIndex = line.firstIndex(of: "#") else { return line }
        return String(line[..<hashIndex])
    }

    /// Quoted string literal capture (supports escaped quotes minimally).
    static func capturedQuoted(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "\"") else { return nil }
        var rest = line.index(after: open)
        var chars: [Character] = []
        while rest < line.endIndex {
            let char = line[rest]
            if char == "\\" {
                let next = line.index(after: rest)
                if next < line.endIndex { chars.append(line[next]) }
                rest = line.index(after: next)
                continue
            }
            if char == "\"" {
                return String(chars)
            }
            chars.append(char)
            rest = line.index(after: rest)
        }
        return nil
    }

    static func quotedTailAfter(_ prefix: String, line: String) -> String? {
        guard let prefixRange = line.range(of: prefix) else { return nil }
        return capturedQuoted(String(line[prefixRange.upperBound...]))
    }

    // MARK: field lines

    static func parseField(line: String, tokens: [String], lineNo: Int) throws -> DecisionField {
        // field <ident>:<kind><args> <"description"> [optional]
        guard tokens.count >= 3, tokens[0] == "field" else {
            throw DecisionSpecError(line: lineNo, message: "malformed field", hint: "field <name>:<kind> <\"description\"> [optional]")
        }
        let decl = tokens[1]
        let parts = decl.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw DecisionSpecError(line: lineNo, message: "field missing `:` separator", hint: "field <name>:<kind> ...")
        }
        let fieldName = parts[0]
        guard validFieldName(fieldName) else {
            throw DecisionSpecError(line: lineNo, message: "invalid field name `\(fieldName)`", hint: "letters, digits, underscore; must not start with a digit")
        }
        // Kind + optional bracket args.
        let kindToken = parts[1]
        let kindName = kindToken.lowercased()
        let bracketArgs = extractBrackets(kindToken)
        let bareKind = kindToken.split(separator: "[", maxSplits: 1).first.map(String.init) ?? kindToken

        var optional = false
        var defaultBool: Bool? = nil
        var allowedValues: [String] = []
        var description: String? = nil
        // Everything after the kind token: ["description"] [optional] [default(b|n)].
        var rest = tokens[2...]
        // Strip leading description literal if present.
        if line.contains("\""), let literal = quotedTailAfter("\(fieldName): ", line: line) {
            description = literal
            rest = rest.dropFirst()
        } else if let literal = capturedQuoted(line) {
            description = literal
            rest = rest.dropFirst()
        }
        for token in rest {
            switch token {
            case "optional": optional = true
            default:
                if token.hasPrefix("default("), token.hasSuffix(")") {
                    let inner = token.dropFirst("default(".count).dropLast()
                    if bareKind == "bool" { defaultBool = inner == "true" } else { break }
                }
            }
        }
        // Optional flags may also appear before the description token; re-check.
        if line.contains(" optional") { optional = true }

        switch bareKind {
        case "bool":
            return DecisionField(name: fieldName, kind: .bool, description: description ?? "Boolean gate.", allowedValues: [], optional: optional, defaultBool: defaultBool)
        case "string":
            guard !bracketArgs.isEmpty else {
                throw DecisionSpecError(line: lineNo, message: "string field needs allowlisted values", hint: "field \(fieldName):string[a|b] \"desc\"")
            }
            allowedValues = bracketArgs.split(separator: "|", omittingEmptySubsequences: true).map(String.init)
            guard !allowedValues.isEmpty else {
                throw DecisionSpecError(line: lineNo, message: "string field had empty allowlist", hint: "field \(fieldName):string[a|b|c] \"desc\"")
            }
            return DecisionField(name: fieldName, kind: .string, description: description ?? "One of the allowed values.", allowedValues: allowedValues, optional: optional, defaultBool: nil)
        case "int":
            return DecisionField(name: fieldName, kind: .int, description: description ?? "Integer score.", allowedValues: [], optional: optional, defaultBool: nil)
        default:
            throw DecisionSpecError(line: lineNo, message: "unknown field kind `\(kindName)`", hint: "bool | string[..] | int")
        }
    }

    /// Pulls "..." bracket args out of a kind token: `string[a|b]` → `a|b`.
    static func extractBrackets(_ token: String) -> String {
        guard let open = token.firstIndex(of: "["), let close = token.lastIndex(of: "]"), open < close else { return "" }
        return String(token[token.index(after: open)..<close])
    }

    static func validFieldName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: rule lines

    static func parseRule(line: String, tokens: [String], lineNo: Int, fields: [DecisionField]) throws -> DecisionRule {
        // rule <conds> -> <outcomes>
        guard let arrowRange = line.range(of: "->") else {
            throw DecisionSpecError(line: lineNo, message: "rule missing `->`", hint: "rule <conds> -> useTools ...")
        }
        let condPart = String(line[line.startIndex..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let outcomePart = String(line[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        var conds: [DecisionCondition] = []
        let condBody = condPart.hasPrefix("rule") ? String(condPart.dropFirst(4)) : condPart
        for condToken in condBody.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !condToken.isEmpty {
            // Two grammar shapes: `field==value` (all kinds) and `field>=n`
            // (int fields only — a floor comparison).
            var condition: DecisionCondition
            if let ge = condToken.firstIndex(of: ">"), condToken.index(after: ge) < condToken.endIndex,
               condToken[condToken.index(after: ge)] == "=" {
                let field = String(condToken[..<ge]).trimmingCharacters(in: .whitespaces)
                let valueStart = condToken.index(ge, offsetBy: 2)
                let value = valueStart < condToken.endIndex
                    ? String(condToken[valueStart...]).trimmingCharacters(in: .whitespaces)
                    : ""
                guard validFieldName(field) else {
                    throw DecisionSpecError(line: lineNo, message: "invalid condition field `\(field)`", hint: "letters, digits, underscore")
                }
                guard let floorValue = Int(value) else {
                    throw DecisionSpecError(line: lineNo, message: "condition `\(condToken)` needs an integer floor", hint: "complexity>=3")
                }
                condition = DecisionCondition(field: field, equals: value, minimum: floorValue)
            } else {
                guard let eq = condToken.firstIndex(of: "="), condToken.index(after: eq) < condToken.endIndex,
                      condToken[condToken.index(after: eq)] == "=" else {
                    throw DecisionSpecError(line: lineNo, message: "condition `\(condToken)` must be `field==value` or `field>=n`", hint: "needsMigration==true, mode==tune, or complexity>=3")
                }
                let field = String(condToken[..<eq]).trimmingCharacters(in: .whitespaces)
                let value = String(condToken[condToken.index(condToken.index(after: eq), offsetBy: 1)...]).trimmingCharacters(in: .whitespaces)
                guard validFieldName(field) else {
                    throw DecisionSpecError(line: lineNo, message: "invalid condition field `\(field)`", hint: "letters, digits, underscore")
                }
                guard !value.isEmpty else {
                    throw DecisionSpecError(line: lineNo, message: "condition `\(field)==` is missing its value", hint: "field==value")
                }
                condition = DecisionCondition(field: field, equals: value)
            }
            conds.append(condition)
        }
        guard !conds.isEmpty else {
            throw DecisionSpecError(line: lineNo, message: "rule has no conditions", hint: "needsDocs==true -> useContext")
        }

        var effects: [DecisionRule.Outcome] = []
        for token in outcomePart.split(separator: " ").map(String.init) where !token.isEmpty {
            guard let outcome = DecisionRule.Outcome(rawValue: token) else {
                throw DecisionSpecError(line: lineNo, message: "unknown outcome `\(token)`", hint: "useTools|useContext|applyEdit|noTools|noContext|noEdit")
            }
            effects.append(outcome)
        }
        guard !effects.isEmpty else {
            throw DecisionSpecError(line: lineNo, message: "rule has no outcomes", hint: "rule ... -> useTools useContext")
        }
        return DecisionRule(conditions: conds, effects: effects)
    }
}

// MARK: - Runtime schema compiler

/// Builds a real FoundationModels `GenerationSchema` from the declared fields.
enum DecisionSchemaCompiler {
    /// Compile the spec into a dynamic root schema.
    static func schema(for spec: DecisionSpec) throws -> GenerationSchema {
        let rootName = spec.name.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let cleanName = rootName.isEmpty ? "UserDecision" : rootName

        var properties: [DynamicGenerationSchema.Property] = []
        for field in spec.fields {
            let subSchema: DynamicGenerationSchema
            switch field.kind {
            case .bool:
                subSchema = DynamicGenerationSchema(type: Bool.self)
            case .string:
                subSchema = DynamicGenerationSchema(name: field.name, description: field.description, anyOf: field.allowedValues)
            case .int:
                subSchema = DynamicGenerationSchema(type: Int.self)
            }
            properties.append(DynamicGenerationSchema.Property(
                name: field.name,
                description: field.description,
                schema: subSchema,
                isOptional: field.optional
            ))
        }
        let root = DynamicGenerationSchema(name: cleanName, description: "User-defined routing decision.", properties: properties)
        return try GenerationSchema(root: root, dependencies: [])
    }
}

// MARK: - Rule evaluation

/// Evaluator: applies the spec's rules to the model's field values, producing
/// the standard routing triple the callers already understand.
public enum DecisionRuleEvaluator {
    /// Full evaluation result: routing triple plus the raw values.
    public struct Result: Sendable {
        public var useTools: Bool
        public var useContext: Bool
        public var applyEdit: Bool
        /// Raw per-field values as strings ("true"/"false" for bools).
        public var values: [String: String]
    }

    public static func evaluate(spec: DecisionSpec, values: [String: String]) -> Result {
        // Start from each field's declared default (optional bools default
        // false; strings/ints contribute no routing until a rule fires).
        var result = Result(useTools: false, useContext: false, applyEdit: false, values: values)
        for rule in spec.rules {
            guard matches(spec: spec, rule: rule, values: values) else { continue }
            for effect in rule.effects {
                switch effect {
                case .useTools: result.useTools = true
                case .useContext: result.useContext = true
                case .applyEdit: result.applyEdit = true
                case .noTools: result.useTools = false
                case .noContext: result.useContext = false
                case .noEdit: result.applyEdit = false
                }
            }
        }
        return result
    }

    static func matches(spec: DecisionSpec, rule: DecisionRule, values: [String: String]) -> Bool {
        for condition in rule.conditions {
            guard let field = spec.fields.first(where: { $0.name == condition.field }) else { return false }
            let raw = values[field.name]
            switch field.kind {
            case .bool:
                let fieldFalse = raw == nil || raw == "false" || raw == "0"
                let wantBool = condition.equals.lowercased() == "true"
                let actualBool = !fieldFalse
                if actualBool != wantBool { return false }
            case .int:
                // `field>=n` int floors; equality also allowed.
                guard let actualRaw = raw, let actual = Int(actualRaw) else { return false }
                if let minimum = condition.minimum {
                    if actual < minimum { return false }
                } else if let wanted = Int(condition.equals), actual != wanted {
                    return false
                }
            default:
                guard let actual = raw, actual.lowercased() == condition.equals.lowercased() else { return false }
            }
            // Optional fields the model omitted: only match ==false/==<default>.
            if field.optional, raw == nil, condition.equals.lowercased() != "false" && field.kind != .bool && field.kind != .string {
                return false
            }
        }
        return true
    }
}

// MARK: - Engine integration (dynamic-schema path)

extension FastDecisionEngine {
    /// Typed routing verdict honored through a user decision spec: the model
    /// answers with the user's schema; rules map values to routing outcomes.
    /// Full replacement — the built-in FastDecision schema is not consulted.
    func decideCustom(query: String, spec: DecisionSpec) async throws -> DecisionRuleEvaluator.Result {
        try await Self.withTimeout(seconds: timeoutSeconds) {
            guard let session = Self.makeSession() else {
                throw EngineError.unavailable("Apple Intelligence model is not available. Run `siri-ai status`.")
            }
            let schema = try DecisionSchemaCompiler.schema(for: spec)
            let options = GenerationOptions(temperature: 0.0, maximumResponseTokens: 256)
            let prompt = Self.customDecisionPrompt(query: query, spec: spec)
            let response = try await session.respond(to: prompt, schema: schema, options: options)
            return try Self.extract(spec: spec, from: response.content)
        }
    }

    static func customDecisionPrompt(query: String, spec: DecisionSpec) -> String {
        let fieldLines = spec.fields
            .map { field -> String in
                let kindHint: String
                switch field.kind {
                case .bool: kindHint = "true/false"
                case .string: kindHint = "one of: \(field.allowedValues.joined(separator: " | "))"
                case .int: kindHint = "an integer"
                }
                return "- \(field.name): \(kindHint) — \(field.description)\(field.optional ? " (optional)" : "")"
            }
            .joined(separator: "\n")
        return """
        Decide, for this user query, values for these fields:
        \(fieldLines)
        Query: \(query)
        """
    }

    /// Pull each declared field's value out of GeneratedContent as a string.
    static func extract(spec: DecisionSpec, from content: GeneratedContent) throws -> DecisionRuleEvaluator.Result {
        var values: [String: String] = [:]
        for field in spec.fields {
            switch field.kind {
            case .bool:
                let v = try content.value(Bool.self, forProperty: field.name)
                values[field.name] = v == true ? "true" : "false"
            case .string:
                let v = try content.value(String.self, forProperty: field.name)
                values[field.name] = v
            case .int:
                let v = try content.value(Int.self, forProperty: field.name)
                values[field.name] = String(v)
            }
        }
        return DecisionRuleEvaluator.evaluate(spec: spec, values: values)
    }
}

// MARK: - FastDecisions integration (spec-aware route)

extension FastDecisions {
    /// Spec-aware route: the user's decision spec FULLY REPLACES the built-in
    /// schema. Same never-fail contract — any failure falls back to the
    /// deterministic heuristic triple (useTools/useContext/applyEdit all
    /// false, i.e. the plain-answer routing) unless the fallback itself can
    /// consult the spec (keep it simple: heuristics stay built-in).
    public static func routeCustom(
        query: String,
        backend: Backend,
        spec: DecisionSpec,
        timeoutSeconds: Double = 2.0
    ) async -> DecisionRuleEvaluator.Result {
        guard isEnabled, backend == .apple else {
            return DecisionRuleEvaluator.Result(useTools: false, useContext: false, applyEdit: false, values: [:])
        }
        let engine = FastDecisionEngine(timeoutSeconds: timeoutSeconds)
        do {
            let result = try await engine.decideCustom(query: query, spec: spec)
            FastDecisions.debug(query, FastDecision(needsTools: result.useTools, needsContext: result.useContext, isEditRequest: result.applyEdit), source: "model+spec[\(spec.name)]")
            return result
        } catch {
            if debugEnabled {
                TerminalOutput.error("[fast-decision#spec-fallback[\(spec.name)]] \(String(describing: error)) — using plain routing")
            }
            return DecisionRuleEvaluator.Result(useTools: false, useContext: false, applyEdit: false, values: [:])
        }
    }
}

// MARK: - Spec loading

extension DecisionSpec {
    /// Load from a file path, tilde-expanded.
    public static func load(path: String) throws -> DecisionSpec {
        let expanded = path.replaceTilde
        let text = try String(contentsOfFile: expanded, encoding: .utf8)
        return try DecisionSpecParser.parse(text)
    }

    /// Auto-discovery: `<repo>/.siri-ai/decisions.spec`. Returns nil when the
    /// file does not exist (spec-less installs keep built-in behavior).
    public static func discover(repoRoot: String?) -> DecisionSpec? {
        guard let root = repoRoot else { return nil }
        let candidate = root.replaceTilde + "/" + Self.discoveryPath
        guard FileManager.default.fileExists(atPath: candidate) else { return nil }
        return try? Self.load(path: candidate)
    }
}
