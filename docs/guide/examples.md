# Code examples

Copy-paste-ready snippets for the `SiriAILib` surface. Each one matches the
API shipped in this package — see [Embedding in a Swift app](/guide/swift-app-integration)
for the full walkthrough and [Architecture](/project/architecture) for how the
pieces layer. All examples require macOS 26+ (27 for the Siri AX backend) and
Apple Intelligence enabled.

> **Runnable twins:** the snippets here have live counterparts in
> `Examples/SwiftExample` — run `swift run Example <mode>`:
> `stream`, `answer --repo`, `agentic --repo`, `chat`, `decide`, `backend`,
> `status` mirror the sections below. The guards (`DocSnippetGuardTests`)
> keep the docs snippets compiling; the Example app keeps them behaving.

## Engines: one protocol, two backends

```swift
import SiriAILib

// The protocol everything implements:
//   func respond(_ request: EngineRequest) async throws -> AgentResponse
//   func stream(_ request: EngineRequest) -> AsyncThrowingStream<String, Error>
//   var availability: AvailabilityReport { get async }

let apple: LLMEngine = AppIntelligenceEngine()      // FoundationModels, streams
let siri:  LLMEngine = SiriAXEngine()               // real Siri AI app, no streaming
```

## Buffered answer

```swift
let engine = AppIntelligenceEngine()
let response = try await engine.respond(EngineRequest(
    system: "You are a concise assistant.",
    prompt: "Explain async/await in Swift, briefly.",
    temperature: nil,
    maxTokens: 200
))
print(response.text)      // full answer
print(response.streamed)  // false
```

## Streaming into a UI

```swift
var answer = ""
for try await delta in engine.stream(EngineRequest(prompt: "Count 1 to 3.")) {
    answer += delta   // accumulate deltas as they arrive
}
```

## Check availability before asking

```swift
let availability = await engine.availability
guard availability.ready else {
    // availability.detail explains what to fix, e.g.
    // "Apple Intelligence is not enabled (System Settings → …)"
    showOnboarding(detail: availability.detail)
    return
}
```

Errors are typed, so each failure maps to its own recovery UI:

```swift
do {
    let reply = try await engine.respond(EngineRequest(prompt: "hi"))
} catch let error as EngineError {
    switch error {
    case .unavailable: /* capability missing — point at Settings */ break
    case .timeout:     /* retry with a longer budget */ break
    case .backend:     /* engine fault — surface the detail */ break
    }
} catch {
    // anything else
}
```

## Multi-turn chat

```swift
var history: [ChatMessage] = [.system("You are a terse assistant.")]
history.append(.user("What is a task group?"))

let prompt = history.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
let reply = try await engine.respond(EngineRequest(
    system: history.first?.content, prompt: prompt
))
history.append(.assistant(reply.text))
```

## Repo-grounded answer (`--repo`, in-process)

```swift
let root = "/path/to/repo"
let files = try RepoScanner(root: root).scan()
let window = AppIntelligenceEngine.modelContextSize()
let context = ContextBuilder(modelContextSize: window)
    .build(files: files, question: "Where is the retry logic?")

let prompt = """
### Context from repository at \(root):
\(context.contextText)

### Question:
Where is the retry logic?

Answer concisely, citing file paths.
"""
for try await delta in engine.stream(EngineRequest(prompt: prompt)) {
    print(delta, terminator: "")
}
```

## Agentic tool use (read-only)

```swift
// ToolLayer is @MainActor: construct on the main actor.
let layer = await MainActor.run {
    ToolLayer(root: "/path/to/repo", allowEdits: false, confirmEdits: false)
}
let response = try await engine.respond(EngineRequest(
    system: "Use the tools to inspect code before answering. Cite file paths.",
    prompt: "Where is the OpenAI server implemented?",
    toolLayer: layer
))
let used = await layer.invokedTools   // e.g. ["list_files", "read_file"]
```

Keep `allowEdits: false` in apps — the `propose_edit` y/N confirm gate is a
terminal flow. See [Repository Q&A & Editing](/guide/repo-editing).

## Fast typed decisions

```swift
// One quick schema-constrained on-device call before the slow answer pass.
let decision = await FastDecisions.route(query: "fix the retry loop", backend: .apple)
if decision.needsTools   { /* attach a ToolLayer */ }
if decision.needsContext { /* prime repo context first */ }
if decision.isEditRequest { /* show edit-mode UI */ }

// Opt out (mirrors --no-fast-decisions):
FastDecisions.isEnabled = false

// Custom rules from a .siri-ai/decisions.spec file — note the different
// result type: useTools/useContext/applyEdit instead of the built-in verdict.
let verdict = await FastDecisions.routeCustom(
    query: "...", backend: .apple, spec: mySpec
)
if verdict.useTools   { /* attach a ToolLayer */ }
if verdict.applyEdit  { /* enter edit mode */ }
```

Custom-spec runs are also skipped for the `siri` backend and disabled switch,
degrading to an all-false result — same contract as the built-in pass.

## Choosing a backend with the enum

```swift
// Backend is a Codable String enum; raw values ("apple", "siri") are the
// wire format used by the CLI's --backend flag and the serve API.
let selection: Backend = .apple
let engine: LLMEngine = (selection == .siri) ? SiriAXEngine() : AppIntelligenceEngine()

// Availability reports carry the same enum:
let report = await engine.availability
print(report.backend)   // Backend.apple
```

## Embedding the OpenAI-compatible server (rare)

```swift
let server = OpenAIServer(port: 11_434, engine: AppIntelligenceEngine())
try await server.run()   // GET /health, GET /v1/models, POST /v1/chat/completions
```

Prefer the engine API directly for a single app talking to its own model —
it skips sockets and serialization entirely. See [Serve API](/serve/).

## Keeping test hooks private: the API-surface guard

The library's test seams stay `internal`; consumers reach them only via
`@testable import SiriAILib`. `APISurfaceGuardTests` compiles one-line
consumer fixtures with a plain `import SiriAILib` and asserts each seam
fails to compile, so a seam that accidentally becomes `public` fails CI:

```sh
swift test --filter APISurfaceGuardTests
```

Adding a new test hook? Register it in `guardedSeams` — one display name plus
the expression a consumer would write. See [Testing & Fixtures](/guide/testing).
