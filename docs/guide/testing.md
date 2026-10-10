# Testing & Fixtures

There are two kinds of tests against the real backends (Apple Intelligence
on-device model and the Siri AI app via Accessibility):

## Recorded-fixture tests (always run)

The AX layer drives the real Siri AI app and extracts answers from the macOS
AX tree, but the live capture is kept in
`Tests/siri_aiTests/Fixtures/ax-sessions.json`. The fixture tests replay each
poll through `AXCleaner` and assert that:

- no Siri chrome survives cleaning (calculator boxes, card fragments,
  activity noise, the stray `0` counter),
- the settled poll still reproduces Siri's recorded answer.

They run as part of normal `swift test` and are the regression safety net for
the AX pipeline.

## Fast decision tests (always run)

The "System 1" routing pass is covered by `FastDecisionTests`, which run on
CI without any model: table-driven heuristic-routing cases, `@Generable`
schema decode from canned JSON, and the timeout/fallback contract (a decision
that hangs or throws must never block or break a request). These also enforce
the CLI contract that scriptable `ask` branch tests are deterministic — the
`--no-fast-decisions` kill switch forces the heuristic verdict so branch
assertions don't depend on model consent.

One opt-in live case verifies a real on-device typed verdict conforms to the
schema (runs with `LIVE_TESTS=1`).

## API-surface guard (always run)

The library keeps its test hooks (routing overrides, TTY probes, AX capture
sinks, fixture listeners) at `internal` and reaches them via
`@testable import SiriAILib`. Nothing re-checks that at compile time — until
someone flips a seam to `public` (often to "fix" a test) and it silently
ships in the SDK.

`APISurfaceGuardTests` guards against that at the language level. It writes
small one-line consumer fixtures that import SiriAILib **without**
`@testable` and typecheck them against the already-built debug module with
`swiftc -typecheck`. Two tests run as part of normal `swift test`:

- **seam inaccessibility** — every entry in `guardedSeams` must fail to
  compile from a plain import. If a seam compiles, it became public (or
  gained a public accessor), the test fails with the seam name and a fix
  hint, and CI breaks before release.
- **public-surface control** — the inverse check: the documented SDK entry
  points (`AppIntelligenceEngine`, `EngineRequest`, `FastDecisions.route`,
  `Backend`) must still compile from a plain import. If this fails after an
  unrelated refactor, the guard environment itself broke — not the API.

### Running the guard

```sh
swift test --filter APISurfaceGuardTests
```

Unlike the other suites this one does not import the module into the test
process — it compiles against the build products on disk, so it only sees
what was there at the last `swift build`. The usual flow is safe because
`swift test` builds first; a standalone guard run on a stale tree can
misreport. When needed:

```sh
SIRI_AI_PACKAGE_ROOT=/path/to/package swift test --filter APISurfaceGuardTests
```

### Adding a new seam

When a new test hook appears in `SiriAILib` (a `*ForTesting` method, an
injected probe, a mutable override global), add one line to
`APISurfaceGuardTests.guardedSeams`: the display name and the exact
expression a consumer would write to reach it. Wrap async calls in the
given `func consumer() async` fixture body (`try await ...` is fine there).
Members of internal types surface as `cannot find` rather than
`inaccessible due to` — the expectation accepts both, so no special
casing is needed.

Carve-outs: symbols that are deliberately public are documented inline and
excluded from the list (`ContextBuilder.estimateTokens` is the current
example — it is public by design for app integrations). Keep them marked in
the comment block above `guardedSeams` so the intent survives.

## Docs-snippet guard (always run)

Prose rots faster than code. `DocSnippetGuardTests` extracts every ```swift
block from `docs/**/*.md` (skipping VitePress internals), wraps bare-statement
fragments in an async fixture with the small set of context names the prose
introduces (`engine`, `query`, `useSiriApp`, `question`, `root`, `mySpec`,
`showOnboarding`, an implicit `import SiriAILib` + SwiftUI for view snippets),
and typechecks each against the built module — same `swiftc -typecheck`
environment as the API-surface guard. A snippet that no longer compiles fails
CI, naming the page, section heading, and block index:

```sh
swift test --filter DocSnippetGuardTests
```

Scope notes: the `Package.swift` manifest snippet (`import
PackageDescription`) is out of scope — it documents packaging, not library
use. Snippets are intentionally compiled with a **plain** import, so anything
showing a `@testable`-only API would fail here too. When you add an example
that uses a name not in the fixture set, add it to `defaultFixtures` (one
line) — keep the fixture set small so the guard keeps forcing docs to match
the real API.

## End-to-end suite (deterministic tier always runs)

`E2ETests` — composed flows across process/socket/pipeline boundaries:

- **CLI process**: spawns the real built `siri-ai` binary and asserts real
  boundaries (no-query error + exit 1, the ArgumentParser usage-error exit 64,
  `status` output, `--help`). Red-proof: a fake binary fails these tests.
- **HTTP server through CLI wiring**: a real loopback server whose engine is
  injected via `setRoutingOverride` (the CLI's routing seam), driven by the
  in-process BSD-socket HTTP client (the same proven client as
  `ServerSocketTests` — do not shell out to `nc` from tests; it proved flaky
  under the runner).
- **Composed library pipeline**: RepoScanner → ContextBuilder over a scratch
  repo with `.gitignore` semantics asserted end to end, and the chat
  transcript prompt-folding contract.
- **Live tier (LIVE_TESTS=1)**: real CLI `ask` inference, real serve+HTTP
  round-trip, real Siri AX respond. Intentionally **single-attempt** for
  model inference — back-to-back retries visibly degraded the on-device
  session (9 s → 17 s → 40 s → 500); a known model-fatigue signature is
  recorded as a skip, not a hammer-red. The Siri AX test also records a skip
  on the known "composer text field" AX drift (tracked in the live
  ChatAndEvent suites).

```sh
swift test --filter E2ETests          # deterministic tiers, CI-safe
LIVE_TESTS=1 swift test --filter E2ETests   # + live tier
```

## Live-model tests (opt-in)

These hit the real Apple Intelligence model and/or drive the real Siri AI app
for real (one-shot inference, streaming, tool calling, AX event pipeline,
prompt folding). They are **disabled by default everywhere** — on CI and on
any machine without the flag — and only run when `LIVE_TESTS=1` is set:

```sh
LIVE_TESTS=1 swift test --filter "AppIntelligenceEngine|SiriAX"
```

This keeps CI green without a Siri session or Apple Intelligence, while
letting developers with both still run the real-backend coverage locally.

## Regenerating fixtures

To (re)write `ax-sessions.json` from a live Siri AI session (needs local Siri,
Accessibility permission granted to the test binary, and takes a couple of
minutes — each question is asked for real):

```sh
CAPTURE_FIXTURES=1 swift test --filter recordAXFixtures
```

Recording is intentionally separate from `LIVE_TESTS`: you can regenerate
fixtures on a machine that has Siri even when live-model tests are otherwise
disabled. When the fixture file is absent the fixture tests silently skip, so
CI and machines without Siri still get a clean green run — but CI should have
the fixture checked in so those tests actually exercise the recorded sessions.
