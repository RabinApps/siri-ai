# Release workflow

The repeatable verification a release needs before it can be tagged. Every
step here has been run at least once end-to-end; the exact commands, the
expected exit codes, and the known transient states are all captured so a
release is a checklist, not an adventure.

## Step 0 — clean tree

```sh
swift build >/dev/null 2>&1; echo $?       # expect 0
pgrep -fl "siri_aiTests|swiftpm-testing-helper"   # expect only unrelated projects
```

A leftover `swiftpm-testing-helper` pointing at **this** package's
`siri_aiTests.xctest` path is a wedged live-test harness from an earlier run
(see the FoundationModels stall note in the changelog) — kill it before
proceeding, otherwise live results can interleave with a hung session.

## Step 1 — deterministic tier (must be exit 0, no exceptions)

```sh
swift build; echo "build EXIT=$?"
swift test;   echo "suite EXIT=$?"
```

> **This gate is automated:** [.github/workflows/ci.yml](https://github.com/RabinApps/siri-ai/blob/main/.github/workflows/ci.yml)
> runs the deterministic tier and the docs build on every push to `main` and
> every pull request, so a red check means the same thing as a failed Step 1
> here. The live tier (Step 3) and the orphaned-process check (Step 0) stay
> manual — they need hardware with the real Siri app and Apple Intelligence.

At the current count this is **214 tests in 35 suites**. The run includes the
API-surface guard (no test seam leaks into the public SDK) and the
docs-snippet guard (every ```swift block in `docs/**/*.md` typechecks
against the built module). Exit 1 here is a release blocker; there is no
tier below this one.

Also run the docs site build — the snippet guard typechecks code blocks, but
the VitePress build is the only thing that catches prose/structure breakage:

```sh
cd docs && npm run build; echo "docs EXIT=$?"
```

## Step 2 — coherence audit (changelog ↔ repo ↔ docs)

Files to eyeball in order (a release that's coherent is a release someone
can reproduce):

| Check | Where | What to verify |
| --- | --- | --- |
| changelog ↔ repos | `CHANGELOG.md` ↔ `docs/changelog.md` | Every bullet you added matches between root and mirror (only the internal link targets differ — that's the documented mirror convention) |
| changelog ↔ code | top-level sections | Each claimed fix/flag/behavior exists in source at the named path or parameter |
| version declaration | `Package.swift` / tagging step | No version field in the package (source release via git tag); confirm naming of the intended tag matches the changelog heading you're about to write |
| no stale doc content | `medical` infra pages | Architecture tree matches actual `Sources/` layout; CLI options tables list every shipped flag |

The changelog's `[Unreleased]` section is what gets renamed to the version
at tag time; everything under `### Fixed` / `### Added` / `### Changed` /
`### Validated` should already read accurately.

## Step 3 — live spot-check (needs a real Siri + Apple Intelligence machine)

```sh
LIVE_TESTS=1 swift test --filter "E2ETests" --filter "ChallengingPromptsTests"
```

What this covers, in order:

- Apple Intelligence one-shot inference, streaming availability, serve + HTTP
  round-trip (fast, seconds)
- the agentic tool loop citing a seeded repo marker (runs via the CLI child
  process; can't wedge the harness — see the backstop notes in the changelog)
- **the two known-flaky Siri AX tests** (`siri: system-prompt compliance /
  persona constraint`, `live: Siri AX E2E — respond shape`)

### Known transient states (do NOT block release on these, but also do not silently ignore them)

The two Siri AX tests occasionally time out at the engine's 30 s settle
window — the documented model-fatigue/AX-stall signature. The rule, learned
over two release gates:

- **First failure:** retry the test filtered to just it. If it passes on the
  immediate retry (typical: 20–35 s), the flake is confirmed and the tier
  counts as green. Both tests cleared on retry in the last two gates.
- **Two consecutive failures of the same test in one session:** treat as a
  candidate regression. Before assuming backend fatigue, verify the failure
  signature matches (timeout on settle across both tests at 30–50 s; single
  test stuck indefinitely into the minutes — i.e. not the subprocess
  backstop exit-124 skip — is the wedge pattern and needs investigation).
- **The `agentic tool loop` test skipping on tool-layer absence** is a valid
  labeled skip by design; it does not count as a run failure.

Expected wall-clock for the whole tier: roughly 60–120 s on a healthy
machine. If the persona test alone exceeds ~60 s, something is off; kill it
rather than waiting (the subprocess-run live tool test self-kills at 150 s
regardless).

## Step 4 — changelog final edit

Once steps 1–3 are all accounted for, promote `[Unreleased]` in BOTH
`CHANGELOG.md` and `docs/changelog.md` to the release version (keep the
mirror convention: docs-site links stay `/guide/...`, docs/changelog links
to the repo for anything non-mirrored). Rerun the docs build after renaming
— the built site must still render.

## Step 5 — tag

```sh
git status                            # the working tree should be clean or deliberate
git tag vX.Y.Z -m "siri-ai vX.Y.Z: <one-line summary from the changelog>"
```

Run `git log --oneline -5` before committing/tagging to make sure the
commit the tag lands on is the one after your release prep — tags on a
stale commit are a common enough mistake to make the checklist explicit.

Tag is pushed with the source release; the docs site deploys separately
(these gates cover the docs content, not the publishing pipeline — that is
whatever platform VitePress is hosted on, not part of this checklist).
