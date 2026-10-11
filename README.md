# siri-ai

Apple Intelligence and the real Siri AI app from your terminal. One Swift 6
binary — no Python, no TypeScript/Bun bridge, no API keys, nothing leaves your
Mac.

A product of [Rabin Apps LLC](https://www.rabinapps.com) · ☕ Sponsor:
[PayPal](https://www.paypal.com/donate/?hosted_button_id=YEJ37WF4Q3HPC) ·
[Buy Me a Coffee](https://buymeacoffee.com/rabinapps)

## Documentation

The full documentation lives in the [`docs/`](docs/) directory, built with
[VitePress](https://vitepress.dev):

- [Getting Started](docs/guide/getting-started.md) — requirements, build, first steps
- [Embedding in a Swift app](docs/guide/swift-app-integration.md) — use `siri-ai` as a package dependency from macOS apps
- [Code examples](docs/guide/examples.md) — copy-paste-ready snippets for the library surface
- [Agent skills](docs/guide/agent-skills.md) — use siri-ai as an on-device coding-agent subagent (`npx skills add RabinApps/siri-ai@siri-ai-subagent`) and consume its local OpenAI endpoint (`…@siri-ai-serve`)
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

---

siri-ai is a product of **[Rabin Apps LLC](https://www.rabinapps.com)**. Released under the
[MIT License](LICENSE) · 2026. If it's useful to you, consider sponsoring:
[PayPal](https://www.paypal.com/donate/?hosted_button_id=YEJ37WF4Q3HPC) ·
[Buy Me a Coffee](https://buymeacoffee.com/rabinapps).

**More from Rabin Apps LLC:**
[SupDesk](https://supdesk.app/en) — a customer-support platform for small teams
(feedback boards, live chat, help center, ticketing) ·
[kinhin](https://kinhin.dev) — the mindful CI: autoscaling GitHub Actions,
Gitea/Forgejo/GitLab runners that live on your Mac.
