---
title: Agent skills
description: "Install, update, and use siri-ai as an agent skill and on-device subagent via the Vercel skills CLI (skills.sh)."
---

# Agent skills

siri-ai ships [agent skills](https://skills.sh/) that teach coding-agent
harnesses (Freebuff, Claude Code, Cursor, plain `npx skills` consumers, …)
how to delegate Q&A to the CLI as a **private, on-device subagent** — no API
keys, no cloud calls — and how to consume its local OpenAI-compatible
endpoint.

## Install

The skills live in this repo, in [`skills/`](https://github.com/RabinApps/siri-ai/tree/main/skills):

- **`siri-ai-subagent`** — the delegation playbook: status precondition,
  repo-grounded `ask --repo --tools`, edit delegation, and when to start the
  server instead. Install as `RabinApps/siri-ai@siri-ai-subagent`.
- **`siri-ai-serve`** — the full OpenAI-compatible endpoint spec for the
  server: `POST /v1/chat/completions` (streaming + buffered), model ids and
  aliases, SSE rewrite/failure semantics, and error envelopes. Install as
  `RabinApps/siri-ai@siri-ai-serve`.

```sh
npx skills add RabinApps/siri-ai             # installs every skill in the repo
npx skills add RabinApps/siri-ai@siri-ai-serve   # just the serve-API skill
```

Options you'll likely want:

| Flag | Effect |
| --- | --- |
| `-g` | Install user-level (global) instead of project-level |
| `-y` | Skip confirmation prompts |
| `--copy` | Copy files instead of symlinking |

This project itself installs both skills globally, so its own agents always
have them:

```sh
npx skills add RabinApps/siri-ai -g -y
```

## Update

Updates work like any GitHub-backed skill:

```sh
npx skills check   # compare installed versions with the repo
npx skills update  # pull in newer skill files
npx skills list    # see what's installed and where
```

After changing the skill in this repo, re-run `npx skills update` (or a
fresh `npx skills add`) in each consumer workspace —GitHub-installed skills
do not auto-refresh.

## Using the skill

The SKILL.md is the playbook. In short, it teaches the harness to:

1. **Check the precondition** — `siri-ai status`, and report UNAVAILABLE
   details with a pointer to [Permissions](/guide/permissions) instead of
   guessing.
2. **Delegate one-shot questions** — `siri-ai ask "<q>" --repo <path>
   --tools --max-seconds 60`, capturing stdout only (diagnostics go to
   stderr) and treating exit code **124** as a deadline hit.
3. **Optionally start the server** — `siri-ai serve --port 11434`, then
   POST to `/v1/chat/completions` like any OpenAI-compatible endpoint (see
   [Serve API](/serve/)).

Edit delegation (`ask --edit`) is deliberately interactive (y/N confirm) —
harnesses must not run it unattended.

## Why a skill?

A harness that has the skill can fold siri-ai into its own workflows: local
repo Q&A that never leaves the Mac, a subagent for summarizing/explaining
files, or an OpenAI-compatible localhost endpoint for other tools. The
skill encodes the safe invocation patterns — deadlines, stdout/stderr
separation, status checks — so any agent can do this correctly on the first
try.
