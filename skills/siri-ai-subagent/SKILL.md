---
name: siri-ai-subagent
description: Use siri-ai (Apple Intelligence + the Siri AI app on macOS) as a private, on-device subagent from any coding harness. Use when the user wants repo-grounded Q&A, one-shot answers, or a local OpenAI-compatible endpoint via siri-ai ask/serve without API keys or cloud calls.
---

# siri-ai as a subagent

Delegate work to the `siri-ai` CLI — a Swift 6 binary that fronts Apple
Intelligence and the Siri AI app entirely on-device. No API keys, no network
egress from the model itself.

## When to delegate to siri-ai

- Repo-grounded questions where privacy matters ("how does X flow through
  this repo?") and nothing should leave the machine.
- One-shot, self-contained subtasks (summarize a file, explain a diff).
- A local OpenAI-compatible endpoint other tools in the workspace can call.

Not for: multi-step agentic coding with your own tools — siri-ai is a
one-shot answerer (its `--edit` path waits for an interactive y/N confirm,
unsuitable for unattended harnesses).

## Step 0 — precondition check

Run first, every session:

```sh
siri-ai status
```

- `apple: OK` → proceed with the default backend.
- `siri: OK` → the Siri AI app backend is also available (macOS 27).
- `UNAVAILABLE` → report the probe's detail line and stop; classic fixes are
  [Permissions](https://siri-ai.rabinapps.com/guide/permissions/)
  (Accessibility & Screen Recording, or `siri-ai permission`), Apple
  Intelligence enabled, and macOS 26+/Apple Silicon.

## Pattern 1 — one-shot Q&A over a repo (most common)

```sh
siri-ai ask "Where is the token bucket implemented?" --repo /path/to/repo --tools
```

- `--repo` grounds the answer in the repo (honors `.gitignore`, skips
  binaries, ranks files by relevance under the on-device context budget).
- `--tools` lets the model call `list_files` / `read_file` / `search_files`
  itself; a `Tools used:` note goes to stderr.
- `--max-seconds 60` adds a wall-clock deadline — recommended for harness
  calls; exits with code **124** when the engine wedges.
- `--no-stream` buffers the whole answer for scripted capture.
- The answer streams to **stdout**; all diagnostics (`Context:` / `Tools
  used:` notes, errors) go to **stderr** — keep stdout clean for capture.

Sample the result and surface it to the user verbatim.

## Pattern 2 — edit proposals (interactive only)

```sh
siri-ai ask "Add error handling to connect() in net.swift" --repo . --edit
```

`--edit` exposes `propose_edit` and renders a block diff that **waits for a
y/N keystroke**. Only use this when a human is on the other end; never in an
unattended pipeline — the process will block forever on the prompt.

## Pattern 3 — long-running server for the whole harness

Start once per session (background, detached):

```sh
siri-ai serve --port 11434
```

Then call it like OpenAI:

- Health: `GET /health`
- Models: `GET /v1/models`
- Chat: `POST /v1/chat/completions` with the standard OpenAI body; `stream:
  true` gives SSE, buffered otherwise.

```sh
curl localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"apple-intelligence","messages":[{"role":"user","content":"Hello"}],"stream":true}'
```

Model ids: `apple-intelligence` (default; buffered requests get a fast
typed pre-decision pass that may attach the file-tool layer, parity with
`ask --tools`) or `siri-ai` (routes through the real Siri AI app; requires
macOS 27 + Accessibility; no tool calling). Any OpenAI SDK works by pointing
`baseURL` at `http://localhost:11434/v1` — the API key can be any
placeholder such as `not-needed`.

Prefer Pattern 1 per call; use Pattern 3 when your harness protocol speaks
OpenAI or many components need the endpoint.

## Error handling

| Signal | Meaning | Action |
| --- | --- | --- |
| exit 124 | `--max-seconds` deadline hit (wedged engine) | Retry once with a larger budget, then surface to the user |
| `UNAVAILABLE` in `status` | Missing permission/model | Link the [Permissions guide](https://siri-ai.rabinapps.com/guide/permissions/), run `siri-ai permission` |
| empty stdout | No query reached the engine | Check the stderr diagnostic; `No candidate files found` means the repo root was wrong |

Full docs: [CLI Reference](https://siri-ai.rabinapps.com/cli/) ·
[Serve API](https://siri-ai.rabinapps.com/serve/) ·
[Repository Q&A & Editing](https://siri-ai.rabinapps.com/guide/repo-editing)
