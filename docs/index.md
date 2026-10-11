---
layout: home

hero:
  name: siri-ai
  text: Apple Intelligence & Siri AI in your terminal
  tagline: One Swift 6 binary — no Python, no TypeScript bridge, no API keys. Inference runs on-device; nothing leaves your Mac.
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: CLI Reference
      link: /cli/

features:
  - icon: 🍎
    title: Fully on-device
    details: Apple Intelligence runs on the Neural Engine. The Siri backend drives the same local app Siri uses. No network calls of its own.
  - icon: 💬
    title: Ask & chat
    details: One-shot questions or multi-turn sessions, streaming by default, grounded on a repo context or the real Siri AI app.
  - icon: 🧰
    title: Repo-aware tools
    details: Give the model list_files / read_file / search_files so it fetches what it needs — and propose edits with a y/N confirm gate.
  - icon: 🚀
    title: OpenAI-compatible server
    details: "siri-ai serve spins up a dependency-free HTTP server: /v1/chat/completions works with any OpenAI SDK, streaming included."
  - icon: 🔐
    title: Permission doctor
    details: "siri-ai permission checks Accessibility & Screen Recording, opens the right System Settings pane, and polls until the grant lands."
  - icon: 🧪
    title: Recorded fixtures
    details: AX session fixtures replay through the cleaner as regression tests — live-model tests stay opt-in via LIVE_TESTS=1.
---

siri-ai is from **Rabin Apps LLC** · MIT License · 2026
