import Foundation
import FoundationModels
import Testing
@testable import siri_ai
@testable import SiriAILib

/// User-defined decision specs ("System 1" custom schemas): parser, runtime
/// schema compilation, rule evaluation, loading/discovery, and the CLI
/// full-replacement contract.
@Suite("DecisionSpecTests")
struct DecisionSpecTests {

    // MARK: - Parser

    @Test("Parses a valid spec end to end")
    func parsesValidSpec() throws {
        let text = """
        # triage decisions
        name "Repo triage"
        field needsDocs:bool "True when the answer needs the docs/ folder"
        field mode:string[tune|explain|sketch] "How to answer the query"
        field complexity:int "Integer difficulty 0-9" optional
        rule needsDocs==true -> useContext
        rule mode==tune, complexity>=3 -> useTools applyEdit
        rule mode==sketch -> useTools
        """
        let spec = try DecisionSpecParser.parse(text)
        #expect(spec.name == "Repo triage")
        #expect(spec.fields.count == 3)
        #expect(spec.fields[0].kind == .bool)
        #expect(spec.fields[1].kind == .string)
        #expect(spec.fields[1].allowedValues == ["tune", "explain", "sketch"])
        #expect(spec.fields[2].optional)
        #expect(spec.rules.count == 3)
        #expect(spec.rules[0].conditions == [DecisionCondition(field: "needsDocs", equals: "true")])
        #expect(spec.rules[0].effects == [.useContext])
        #expect(spec.rules[1].effects == [.useTools, .applyEdit])
    }

    @Test("Comments and blank lines are ignored")
    func commentsAndBlanks() throws {
        let text = """
        # only a comment

        field want:bool "gate"
        # trailing comment line
        """
        let spec = try DecisionSpecParser.parse(text)
        #expect(spec.fields.count == 1)
        #expect(spec.rules.isEmpty)
    }

    @Test("Quoted description captures escapes")
    func quotedDescription() throws {
        let spec = try DecisionSpecParser.parse(#"""
        field gate:bool "Has \"quotes\" inside"
        """#)
        #expect(spec.fields[0].description == "Has \"quotes\" inside")
    }

    @Test("Optional and default(bool) modifiers")
    func optionalAndDefault() throws {
        let spec = try DecisionSpecParser.parse("""
        field want:bool "gate" optional default(true)
        field level:int "depth" optional
        """)
        #expect(spec.fields[0].optional)
        #expect(spec.fields[0].defaultBool == true)
        #expect(spec.fields[1].optional)
    }

    @Test("Rejects unknown keyword with line number")
    func unknownKeyword() {
        #expect(throws: DecisionSpecError.self) {
            _ = try DecisionSpecParser.parse("nonsense line here")
        }
        do {
            _ = try DecisionSpecParser.parse("nonsense here")
        } catch let error as DecisionSpecError {
            #expect(error.line == 1)
            #expect(error.message.contains("unknown keyword"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("Rejects duplicate fields and unknown rule fields")
    func rejectsDuplicatesAndBadRefs() {
        do {
            _ = try DecisionSpecParser.parse("""
            field a:bool "one"
            field a:bool "two"
            """)
            Issue.record("expected duplicate field error")
        } catch let error as DecisionSpecError {
            #expect(error.message.contains("duplicate"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        do {
            _ = try DecisionSpecParser.parse("""
            field a:bool "one"
            rule ghost==true -> useTools
            """)
            Issue.record("expected unknown rule field error")
        } catch let error as DecisionSpecError {
            #expect(error.message.contains("unknown field"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("Rejects rule syntax errors")
    func rejectsBadRules() {
        // Missing arrow.
        do {
            _ = try DecisionSpecParser.parse("""
            field a:bool "one"
            rule a==true useTools
            """)
            Issue.record("expected missing-arrow error")
        } catch let error as DecisionSpecError {
            #expect(error.message.contains("missing `->`"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        // Unknown outcome.
        do {
            _ = try DecisionSpecParser.parse("""
            field a:bool "one"
            rule a==true -> explodeEverything
            """)
            Issue.record("expected unknown-outcome error")
        } catch let error as DecisionSpecError {
            #expect(error.message.contains("unknown outcome"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }

        // String field without allowlist.
        do {
            _ = try DecisionSpecParser.parse("field mode:string \"no values\"")
            Issue.record("expected empty-allowlist error")
        } catch let error as DecisionSpecError {
            #expect(error.message.contains("allowlist"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test("Rejects spec with no fields")
    func rejectsEmptySpec() {
        do {
            _ = try DecisionSpecParser.parse("name \"Nothing\"")
            Issue.record("expected no-fields error")
        } catch let error as DecisionSpecError {
            #expect(error.message.contains("no fields"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    // MARK: - Schema compilation

    @Test("Compiles fields into a GenerationSchema")
    func compilesSchema() throws {
        let spec = try DecisionSpecParser.parse("""
        name "Triage"
        field want:bool "gate"
        field mode:string[tune|explain|sketch] "how"
        field depth:int "level" optional
        """)
        let schema = try DecisionSchemaCompiler.schema(for: spec)
        #expect(!schema.debugDescription.isEmpty)
    }

    @Test("Extract round-trips values through GeneratedContent")
    func extractRoundTrip() throws {
        let spec = try DecisionSpecParser.parse("""
        field want:bool "gate"
        field mode:string[tune|explain] "how"
        """)
        let json = #"{"want":true,"mode":"tune"}"#
        let content = try GeneratedContent(json: json)
        let result = try FastDecisionEngine.extract(spec: spec, from: content)
        #expect(result.values["want"] == "true")
        #expect(result.values["mode"] == "tune")
    }

    // MARK: - Rule evaluation

    @Test("Rules map values onto routing outcomes in order")
    func ruleOrdering() {
        let spec = DecisionSpec(
            name: "T",
            fields: [
                DecisionField(name: "a", kind: .bool, description: "", allowedValues: [], optional: false, defaultBool: nil),
                DecisionField(name: "m", kind: .string, description: "", allowedValues: ["x", "y"], optional: false, defaultBool: nil),
            ],
            rules: [
                DecisionRule(conditions: [.init(field: "m", equals: "x")], effects: [.useTools]),
                DecisionRule(conditions: [.init(field: "m", equals: "y")], effects: [.useContext, .applyEdit]),
            ]
        )
        let x = DecisionRuleEvaluator.evaluate(spec: spec, values: ["a": "false", "m": "x"])
        #expect(x.useTools && !x.useContext && !x.applyEdit)
        let y = DecisionRuleEvaluator.evaluate(spec: spec, values: ["a": "false", "m": "y"])
        #expect(y.useContext && y.applyEdit && !y.useTools)
        let none = DecisionRuleEvaluator.evaluate(spec: spec, values: ["a": "false", "m": "x", "_": "z"])
        #expect(none.useTools)  // first rule still matches regardless of extra keys
    }

    @Test("Omitted optional bool matches ==false")
    func optionalBoolOmission() {
        let spec = DecisionSpec(
            name: "T",
            fields: [
                DecisionField(name: "flag", kind: .bool, description: "", allowedValues: [], optional: true, defaultBool: nil),
            ],
            rules: [
                DecisionRule(conditions: [.init(field: "flag", equals: "false")], effects: [.noEdit]),
                DecisionRule(conditions: [.init(field: "flag", equals: "true")], effects: [.applyEdit]),
            ]
        )
        let omitted = DecisionRuleEvaluator.evaluate(spec: spec, values: [:])
        #expect(omitted.applyEdit == false)
        let present = DecisionRuleEvaluator.evaluate(spec: spec, values: ["flag": "true"])
        #expect(present.applyEdit)
    }

    @Test("no* outcomes override earlier rules")
    func negationOutcomes() {
        let spec = DecisionSpec(
            name: "T",
            fields: [
                DecisionField(name: "a", kind: .bool, description: "", allowedValues: [], optional: false, defaultBool: nil),
                DecisionField(name: "b", kind: .bool, description: "", allowedValues: [], optional: false, defaultBool: nil),
            ],
            rules: [
                DecisionRule(conditions: [.init(field: "a", equals: "true")], effects: [.useTools, .useContext]),
                DecisionRule(conditions: [.init(field: "a", equals: "true"), .init(field: "b", equals: "true")], effects: [.noTools]),
            ]
        )
        let both = DecisionRuleEvaluator.evaluate(spec: spec, values: ["a": "true", "b": "true"])
        #expect(!both.useTools)
        #expect(both.useContext)   // ctx from rule 1 survives
    }

    // MARK: - Custom route (full replacement)

    @Test("routeCustom falls back to plain routing when disabled or siri")
    func routeCustomFallbacks() async {
        let spec = DecisionSpec(
            name: "T",
            fields: [
                DecisionField(name: "a", kind: .bool, description: "", allowedValues: [], optional: false, defaultBool: nil),
            ],
            rules: [DecisionRule(conditions: [.init(field: "a", equals: "true")], effects: [.applyEdit])]
        )
        let previous = FastDecisions.isEnabled
        FastDecisions.isEnabled = false
        defer { FastDecisions.isEnabled = previous }
        let plain = await FastDecisions.routeCustom(query: "any", backend: .apple, spec: spec)
        #expect(!plain.useTools && !plain.useContext && !plain.applyEdit)
        let siri = await FastDecisions.routeCustom(query: "any", backend: .siri, spec: spec)
        #expect(!siri.applyEdit)
    }

    // MARK: - Loading and discovery

    @Test("Load from file path")
    func loadFromFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spec-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("my.spec")
        try "field gate:bool \"gate\"".write(to: url, atomically: true, encoding: .utf8)
        let spec = try DecisionSpec.load(path: url.path)
        #expect(spec.fields.count == 1)
    }

    @Test("Discovery returns nil without the file, loads it when present")
    func discovery() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spec-disc-\(UUID().uuidString)")
        let hidden = dir.appendingPathComponent(DecisionSpec.discoveryDirectory)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(DecisionSpec.discover(repoRoot: dir.path) == nil)

        try "name \"Found\"\nfield gate:bool \"gate\""
            .write(to: hidden.appendingPathComponent(DecisionSpec.fileName), atomically: true, encoding: .utf8)
        let spec = DecisionSpec.discover(repoRoot: dir.path)
        #expect(spec?.name == "Found")
    }

    // MARK: - Live model (opt-in)

    @Test("Live custom-spec decision", .enabled(if: ProcessInfo.processInfo.environment["LIVE_TESTS"] == "1"))
    func liveCustomDecision() async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw EngineError.unavailable("Apple Intelligence not available; skipping live custom decision test.")
        }
        let spec = try DecisionSpecParser.parse("""
        name "TriageLive"
        field wantsCode:bool "True when the query is about code"
        field pace:string[quick|deep] "How thorough the answer should be"
        rule wantsCode==true, pace==deep -> useTools useContext
        """)
        // Generous ceiling: a live schema call under parallel-suite load can
        // outlast the 5 s default (observed .timeout("5") under LIVE_TESTS).
        let engine = FastDecisionEngine(timeoutSeconds: 15.0)
        let result = try await engine.decideCustom(
            query: "walk me through how the server routes requests, line by line",
            spec: spec
        )
        #expect(result.values["pace"] != nil)
    }
}
