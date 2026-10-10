# Getting Started

Apple Intelligence and the real Siri AI app from your terminal. One Swift 6
binary — no Python, no TypeScript/Bun bridge, no API keys, nothing leaves your
Mac.

## Requirements

- macOS 26 (Tahoe) or later — macOS 27 for the Siri AI backend
- Apple Silicon
- Apple Intelligence enabled (System Settings → Apple Intelligence & Siri)
- Swift 6.4+ / Xcode 26+

## Build

```sh
swift build
swift test
```

The binary lands at `.build/debug/siri_ai` (release: add `-c release`).

## First steps

Diagnose your setup:

```sh
siri-ai status
```

Then grant any missing permissions:

```sh
siri-ai permission            # interactive walk-through with live checks
siri-ai permission --check-only
```

Ask your first question:

```sh
siri-ai ask "Explain async/await in two sentences"
```

Or run a multi-turn chat:

```sh
siri-ai chat -s "You are a terse coding assistant"
```
