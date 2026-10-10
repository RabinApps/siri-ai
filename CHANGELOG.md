# Changelog

All notable changes to `siri-ai` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the package pushes
source releases as git tags.

## [Unreleased]

### Fixed

- **Siri AX engine: configurable timeout + auto-retry on transient stalls**
  — `SiriAXEngine(system:timeout:retries:)` gains a `retries` parameter
  (default `1`, clamped to ≥ 0). A Siri session that stalls past the settle
  timeout (already configurable, default 30 s) is retried automatically: each
  retry re-drives a fresh conversation instead of surfacing `EngineError
  .timeout`, so the live tier stops flaking on Siri's observed fatigue state.
  Routing is deliberate: only the settle-timeout is transient — structural AX
  failures (missing composer, unavailable app) and cancellation propagate
  immediately, and a stream that already emitted deltas is never restarted
  mid-flight (the original error is rethrown untouched). Deterministic
  coverage in `SiriAXRetryTests`; exhaust rethrows the original timeout,
  terminal errors cost no attempt, and negative values clamp to a single
  attempt.
- **Siri AX backend: visible-window gate** — the app idles as a background
  daemon with zero on-screen windows; in that state its AX tree exposes only
  the menu bar, so the "New Conversation" button and composer never
  materialize and every respond threw "Could not locate the Siri AI composer
  text field". `observe` now resolves the pid, opens the app to materialize
  the chat window, polls `AXWindows` (≤8 s) before driving the tree, and
  waits for the composer text field to appear after the New Conversation
  press (≤3 s) instead of a fixed 400 ms sleep. Verified against the live
  Siri AI app: all live AX suites and the e2e Siri AX flow pass.

### Added

- **Library split** — everything the CLI does now lives in an importable
  library target, `SiriAILib` (published as the `siri-ai` package product).
  macOS apps can embed the package and call engines, repo-context selection,
  tools, and the server in-process with no HTTP hop:
  `import SiriAILib`. The executable target (`siri_ai`, the `siri-ai` binary)
  is a thin ArgumentParser shell over the library. See
  [Embedding in a Swift app](docs/guide/swift-app-integration.md).
- **SDK surface** — the public API is the engine protocol and its inputs and
  outputs: `LLMEngine` (`respond` / `stream` / `availability`),
  `AppIntelligenceEngine` (Apple Intelligence on-device via FoundationModels),
  `SiriAXEngine` (drives the real Siri AI app via Accessibility, macOS 27),
  `EngineRequest`, `AgentResponse`, `EngineError`, `ChatMessage`,
  `ContextBuilder` (+ `estimateTokens` for budgeting), `RepoScanner`,
  `ToolLayer`, `FastDecisions.route` (+ `routeCustom` for custom
  `.siri-ai/decisions.spec` rules), and `OpenAIServer` for embedding the
  OpenAI-compatible HTTP surface. Documented publicly; a guard test keeps
  everything else out (below).
- **Example app** — `swift run Example <mode>` (`Examples/SwiftExample`)
  demonstrating the library surface without the CLI:
  - `stream "…"` — plain streaming ask, printing deltas as they arrive
  - `answer --repo <path> "…"` — repo-grounded streaming answer via
    `RepoScanner` + token-budgeted `ContextBuilder`
  - `agentic --repo <path> "…"` — model drives the read-only file tools
    (`list_files`, `read_file`, `search_files`)
  - `chat [q1 q2 …]` — multi-turn `ChatMessage` transcript loop
  - `decide "…"` — FastDecisions typed routing verdict
  - `backend [apple|siri]` — engine swap via the `Backend` enum
  - `status` — engine availability probe
  These are the runnable twins of the [code examples](docs/guide/examples.md)
  page; the docs-snippet guard keeps the snippets compiling against them.
- **Challenging-prompt tests** — `ChallengingPromptsTests` moves live coverage
  past arithmetic: Siri AX persona-compliance, multi-part query coverage,
  and unicode/emoji prompt folding (all verified against the real Siri AI
  app); Apple Intelligence multi-step reasoning with format verification
  (order-complete, duplicates tolerated) and an agentic tool loop citing a
  seeded file marker (tool-layer skip marked honestly when the session
  doesn't invoke tools). Deterministic AXCleaner stress: interleaved-chrome
  shapes, adversarial edges (empty/chrome-only/unicode blob/packed blob),
  and chrome case-insensitivity without over-stripping prose mentions.
- **End-to-end suite** — `E2ETests` covers composed flows in three CI-safe
  deterministic tiers (real CLI binary via process spawn with exit-code
  contracts; HTTP server via the CLI routing seam over loopback sockets with
  the runner-proof in-process socket client; RepoScanner→ContextBuilder
  pipeline on a scratch repo) plus a `LIVE_TESTS=1` live tier (CLI ask on
  the on-device model, real serve+HTTP round-trip, Siri AX respond with
  model-fatigue/AX-drift skipped-not-hammered).
- **Docs-snippet guard** — `DocSnippetGuardTests` extracts every ```swift
  block from the documentation and typechecks it against the built module
  (plain `import SiriAILib`, same `swiftc` environment as the API guard),
  so a snippet that drifts from the shipped API fails CI with the page,
  section heading, and diagnostics. `swift test --filter DocSnippetGuardTests`.
- **API-surface guard** — `APISurfaceGuardTests` compiles one-line consumer
  fixtures against the built module with a *plain* `import SiriAILib`
  (no `@testable`) and asserts that every test seam (routing overrides, the
  TTY probe, the AX capture sink, fixture listeners, decision-spec internals,
  …) fails to compile. If a seam ever becomes public, CI fails with the seam
  name and a fix hint. An inverse test pins the documented public surface so
  refactors that break the guard environment itself are caught too. Run with
  `swift test --filter APISurfaceGuardTests`. See
  [Testing & Fixtures](docs/guide/testing.md).

### Changed

- **`Backend` enum** — the backend selector is now a public, `Codable`
  `String` enum (`Backend.apple`, `Backend.siri`) that replaces raw string
  literals across the library, server, and CLI. `AvailabilityReport` and the
  OpenAI-compatible `serve` surface report the backend as the enum's raw
  value; `--backend` on the CLI keeps accepting the strings `apple` (default)
  and `siri` and converts at the boundary. Anything matching on backend
  strings in downstream clients should switch to the enum (or keep using the
  raw values, which are unchanged).

### Changed

- **Subprocess backstop for the stall-prone live tool-loop test** —
  `liveToolCallingInference` no longer runs the tool session in-process;
  it now spawns the real CLI (`siri-ai ask --tools --no-stream`) as a
  child process and kills it at 150 s. Because the FoundationModels stall
  wedges the *process-level* cooperative thread pool (sampled live: every
  cooperative thread parked inside framework internals, cooperative
  cancellation unobservable), only the process boundary guarantees the
  suite recovers — a wedged child dies with its process, the harness
  never waits. The child's `--max-seconds` deadline (see below) fires
  first (exit 124, recorded as a labeled skip), so the external kill is
  the last resort only.
- **`siri-ai ask --max-seconds`** — new wall-clock deadline option for the
  ask command (GNU-timeout convention: exit 124 on expiry) covering the
  wedged-engine case cooperatively — `nonStream` via `withInferenceDeadline`
  (now public on the SDK), streaming via a wait-to-first-delta race (a late
  finish after deltas arrived is legitimate and never killed). Useful to
  any embedding or script that must not hang on an engine wedge.
- **Tool-schema token trim** — with all four tools attached, the tool-session
  request ran 4,116 tokens against the on-device model's 4,096-token window
  (real overflow, reproduced in the subprocess live run). The two loosest
  tool-argument guides (`basePath` on `list_files` / `read_file`) were
  shortened; a live tool-attached request now completes inside the window.
  Live `liveToolCallingInference` passes through the subprocess path
  (18.8 s), and the deterministic tier keeps both deadline paths covered
  (responsive engine completes; wedged engine exits 124 within the deadline
  — verified at 0.3 s).

### Validated

- **Live-model test run (`LIVE_TESTS=1`)** against the real backends on macOS:
  Apple Intelligence one-shot inference, streaming, availability coherence,
  and the large-directory context-window guard passed; both live Siri AX
  suites passed against the real Siri AI app (AX event pipeline ~21 s/test,
  prompt folding ~19 s); all 26 DecisionSpec and all 15 FastDecision tests
  passed, including the live custom-spec decision, the heuristic-agreement
  corpus run, and the serve-socket integration. **Known issue found
  by the run:** `liveToolCallingInference` hung indefinitely (>7 min, no
  on-device model fault surfaced) when its tool loop ran live — it needs a
  timeout/failure investigation and is not a regression of the offline tool
  path, which stays covered by FastDecision and ToolLayer unit tests.

[0.1.0 and earlier]: not separately tracked; see the git history and the
docs under `docs/guide/`.
