# Embedding in a Swift app

Everything the `siri-ai` CLI does is also a **Swift library**. If your app is
Swift on macOS, embed the package directly — no HTTP server, no port
management, no process supervision. (The `serve` command and its
OpenAI-compatible API remain available for non-Swift clients; see the
[Serve API](/serve/).)

```swift target: SiriAILib
import SiriAILib
```

## Requirements

Your app inherits the package's platform floor:

- **macOS 26 (Tahoe)** or later — macOS 27 for the Siri AX backend
- **Apple Silicon**
- **Apple Intelligence enabled** on the user's Mac
- Swift 6.4+ / Xcode 26+

The on-device model never sends anything off the machine, so no entitlements,
secrets, or App-Sandbox changes are needed for the Apple Intelligence backend.
The Siri AX backend additionally needs **Accessibility**
permission *for your app* — see [Permissions](/guide/permissions).

## Add the dependency

```swift
// Package.swift  (or add the same entries in Xcode: File → Add Package Dependencies…)
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/RabinApps/siri-ai.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            dependencies: [.product(name: "siri-ai", package: "siri-ai")]
        )
    ]
)
```

> The published product name is `siri-ai`; the module you import is
> `SiriAILib`.

## Streaming example

The core abstraction is an **engine**. `AppIntelligenceEngine` talks to Apple
Intelligence on-device via FoundationModels; its `stream(_:)` yields text
deltas as they are generated.

```swift
import SiriAILib

func askAppleIntelligence(_ question: String) async throws {
    let engine = AppIntelligenceEngine()
    let request = EngineRequest(
        system: "You are a concise assistant.",
        prompt: question
    )

    for try await delta in engine.stream(request) {
        // delta is the next chunk of the answer — append it to your UI.
        print(delta, terminator: "")
    }
    print()
}
```

In a SwiftUI view, accumulate deltas into an `@State` string:

```swift
struct AskView: View {
    let engine = AppIntelligenceEngine()
    @State private var answer = ""
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading) {
            Text(answer)
            if isWorking { ProgressView() }
        }
        .task {
            guard answer.isEmpty, !isWorking else { return }
            isWorking = true
            defer { isWorking = false }
            let request = EngineRequest(prompt: "Explain async/await in Swift, briefly.")
            do {
                for try await delta in engine.stream(request) {
                    answer += delta
                }
            } catch {
                answer += "\n⚠️ \(error.localizedDescription)"
            }
        }
    }
}
```

Prefer buffering the whole answer instead? Use `respond(_:)`:

```swift
let response = try await engine.respond(EngineRequest(prompt: "Hello!"))
print(response.text)      // full answer
print(response.streamed)  // false — buffered, not streamed
```

## Check availability first

Every engine reports readiness asynchronously so you can show useful
diagnostics *before* the user types anything:

```swift
let engine = AppIntelligenceEngine()
let availability = await engine.availability
if availability.ready {
    // backend: .apple, detail: "Apple Intelligence on-device model available"
} else {
    // e.g. detail: "Apple Intelligence is not enabled (System Settings → …)"
    showOnboarding(selectedBackend: availability.backend, detail: availability.detail)
}
```

Errors are typed too — `EngineError` distinguishes `.unavailable` (capability
missing), `.timeout`, and `.backend` faults, so you can route each case to the
right recovery UX.

## Repo-grounded answering (the `--repo` workflow, in-process)

The library ships the same building blocks the CLI composes for
`ask --repo`: `RepoScanner` discovers candidate files, `ContextBuilder`
selects and trims a token-budgeted subset for the on-device model's window,
and `ToolLayer` exposes file tools (`list_files`, `read_file`, `search_files`)
for agentic answers.

```swift
func answerAboutRepo(at root: String, question: String) async throws {
    let engine = AppIntelligenceEngine()
    let files = try RepoScanner(root: root).scan()

    let window = AppIntelligenceEngine.modelContextSize()
    let context = ContextBuilder(modelContextSize: window).build(files: files, question: question)

    let prompt = """
    ### Context from repository at \(root):
    \(context.contextText)

    ### Question:
    \(question)

    Answer concisely, citing file paths.
    """
    let request = EngineRequest(
        system: "You are a precise, concise coding assistant.",
        prompt: prompt
    )
    for try await delta in engine.stream(request) {
        print(delta, terminator: "")
    }
}
```

Or go fully agentic — let the model decide which files to inspect:

```swift
let layer = await MainActor.run {
    // allowEdits: false → read-only tools (list/read/search).
    ToolLayer(root: root, allowEdits: false, confirmEdits: false)
}
let request = EngineRequest(
    system: "You are a coding assistant. Use the tools to inspect code before answering.",
    prompt: question,
    toolLayer: layer
)
let response = try await engine.respond(request)
if case let used = await layer.invokedTools, !used.isEmpty {
    print("Tools used:", used.joined(separator: ", "))
}
print(response.text)
```

> Edits (`allowEdits: true`, the `propose_edit` tool) render a `y/N`
> confirmation prompt on the terminal — that flow is built for the CLI. In an
> app, keep `allowEdits: false` unless you also supply your own confirmation
> UX.

## Multi-turn chat

`ChatMessage` models turns; the tests' transcript pattern (roles + contents,
last turn or two) maps cleanly onto Apple Intelligence's small window:

```swift
var history: [ChatMessage] = [.system("You are a terse assistant.")]
history.append(.user("What is a task group?"))

let prompt = history.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
let request = EngineRequest(system: history.first?.content, prompt: prompt)
let reply = try await engine.respond(request)
history.append(.assistant(reply.text))
```

## Routing with fast decisions (optional)

`FastDecisions.route(query:backend:)` is the CLI's "System 1" pass — one fast
on-device schema-constrained call that classifies a query (needs file tools?
needs context? an edit request?) with a deterministic keyword fallback, never
throwing. Use it to pick a UI affordance before committing to an engine call:

```swift
let decision = await FastDecisions.route(query: query, backend: .apple)
if decision.needsContext {
    // prime the repo-context path before answering
}
if decision.isEditRequest {
    // show an edit-mode UI instead of a plain answer
}
```

Disable it with `FastDecisions.isEnabled = false` (mirrors the CLI's
`--no-fast-decisions`). Custom routing rules are available too — see
[Custom decision specs](/guide/decision-specs) for the `.siri-ai/decisions.spec`
format and `FastDecisions.routeCustom(query:backend:spec:)`.

## The Siri AX backend

`SiriAXEngine` drives the real Siri AI app through the Accessibility API
(macOS 27). Same protocol, drop-in swap — but no streaming, no tool calling,
and it requires Accessibility permission for *your app*:

```swift
let backend: LLMEngine = useSiriApp ? SiriAXEngine() : AppIntelligenceEngine()
let availability = await backend.availability   // check Accessibility + app presence first
let reply = try await backend.respond(EngineRequest(prompt: "…"))
```

## Local OpenAI-compatible server (embedding the server, rare)

If you *want* a loopback HTTP surface inside your own process — e.g. to share
one on-device model with helper scripts — the server is importable too; see
the [embedding example](/guide/examples#embedding-the-openai-compatible-server-rare). For a single
Swift app talking to its own model, prefer the engine API directly — it
skips serialization, sockets, and port bookkeeping entirely.

## Next steps

- [Permissions](/guide/permissions) — granting Accessibility for the Siri AX
  backend
- [Fast typed decisions](/guide/fast-decisions) — how the System 1 pass works
- [Serve API](/serve/) — the OpenAI-compatible HTTP surface (for non-Swift
  clients)
- [Architecture](/project/architecture) — how the library is layered
