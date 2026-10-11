# siri-ai

Apple Intelligence and the real Siri AI app from your terminal. One Swift 6
binary — no Python, no TypeScript/Bun bridge, no API keys, nothing leaves your
Mac.

## Documentation

The full documentation lives in the [`docs/`](docs/) directory, built with
[VitePress](https://vitepress.dev):

- [Getting Started](docs/guide/getting-started.md) — requirements, build, first steps
- [Embedding in a Swift app](docs/guide/swift-app-integration.md) — use `siri-ai` as a package dependency from macOS apps
- [Code examples](docs/guide/examples.md) — copy-paste-ready snippets for the library surface
- [Permissions](docs/guide/permissions.md) — Accessibility & Screen Recording setup
- [Repository Q&A & Editing](docs/guide/repo-editing.md) — `--repo`, `--tools`, `--edit`
- [Fast typed decisions](docs/guide/fast-decisions.md) — the fast "System 1" routing pass
- [Custom decision specs](docs/guide/decision-specs.md) — replace the routing verdict with your own schema
- [Chat](docs/guide/chat.md) — multi-turn sessions, Siri memory
- [Testing & Fixtures](docs/guide/testing.md) — recorded fixtures, `LIVE_TESTS`, API-surface guard
- [Release workflow](docs/guide/release-workflow.md) — the pre-tag checklist contributors run
- [CLI Reference](docs/cli/index.md) — `ask`, `chat`, `serve`
- [Serve API](docs/serve/index.md) — local OpenAI-compatible HTTP server
- [Architecture](docs/project/architecture.md) & [Privacy](docs/project/privacy.md)
- [Changelog](CHANGELOG.md) — notable changes per release

Read the docs locally:

```sh
cd docs && npm install && npm run dev
```

## Quick start

Install the CLI with Homebrew (builds from this repo — no separate tap needed):

```sh
brew tap rabinapps/siri-ai https://github.com/RabinApps/siri-ai.git
brew install --HEAD rabinapps/siri-ai/siri-ai
siri-ai status
```

Or build from source:

```sh
swift build
.build/debug/siri_ai status
```

See [Getting Started](docs/guide/getting-started.md) for all install options.

Requires macOS 26+ (macOS 27 for the Siri AI backend), Apple Silicon, Apple
Intelligence enabled, and Swift 6.4+ / Xcode 26+. See
[Getting Started](docs/guide/getting-started.md) for details.
