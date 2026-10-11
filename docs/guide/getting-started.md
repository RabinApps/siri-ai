# Getting Started

Apple Intelligence and the real Siri AI app from your terminal. One Swift 6
binary — no Python, no TypeScript/Bun bridge, no API keys, nothing leaves your
Mac.

## Requirements

- macOS 26 (Tahoe) or later — macOS 27 for the Siri AI backend
- Apple Silicon
- Apple Intelligence enabled (System Settings → Apple Intelligence & Siri)
- Swift 6.4+ / Xcode 26+

## Install

### Option A: Homebrew (installs from this repo, no separate tap required)

Homebrew can tap this repository directly — brew recognizes a `Formula/`
directory inside it and builds the formula from source, so no separate
`homebrew-*` tap repository is needed:

```sh
brew tap rabinapps/siri-ai https://github.com/RabinApps/siri-ai.git
brew install --HEAD rabinapps/siri-ai/siri-ai
```

The formula builds the SwiftPM package in release mode and installs the CLI as
`siri-ai`; upgrades (`brew upgrade --fetch-HEAD siri-ai`) rerun the release
build automatically. While the repo has no version tags yet the formula is
HEAD-only (hence `--HEAD`); once the first tag lands a plain
`brew install rabinapps/siri-ai/siri-ai` works and pins that release.

Verify:

```sh
siri-ai status
```

> Note: building the Siri AI backend into the brew sandbox requires Homebrew
> 4.4+; on older brew versions fall back to Option B (build from source).

### Option B: build and install the CLI from source

The package builds straight from this repository — no Homebrew formula or
shell installer needed:

```sh
git clone https://github.com/RabinApps/siri-ai.git
cd siri-ai
swift build -c release
mkdir -p ~/.local/bin
ln -sf "$(pwd)/.build/release/siri_ai" ~/.local/bin/siri-ai
```

```sh
# ensure ~/.local/bin is on PATH (zsh default shell):
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Verify:

```sh
siri-ai status
```

The built binary is `siri_ai` (SwiftPM derives the underscore name from the
executable target); installing it as `siri-ai` on your PATH gives you the
spelled-out command used throughout these docs.

### Option C: as a Swift package dependency (apps, not the CLI)

Until the first tagged release, depend on the `main` branch (SwiftPM pins it
to the current commit at resolve time):

```swift
.package(url: "https://github.com/RabinApps/siri-ai.git", branch: "main")
```

Your consuming package needs `swift-tools-version: 6.2`+ and
`platforms: [.macOS(.v26)]` (or later). After the first tag, switch to a
version pin: `.package(url: …, from: "0.1.0")`.

See [Embedding in a Swift app](/guide/swift-app-integration).

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
