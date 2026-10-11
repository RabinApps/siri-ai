---
title: Repository Q&A & Editing
description: "Ask grounded on your repository: --repo context, --tools file tools, and --edit with a y/N confirm gate."
---

# Repository Q&A & Editing

`siri-ai ask` can ground its answer in your repository, search it with tools,
and even propose edits.

## Repo grounding

```sh
siri-ai ask "How does payment processing flow through this repo?" --repo ~/src/payments
```

With `--repo <path>`:

- files are scanned, honoring `.gitignore` and skipping binaries and vendored
  directories,
- files are ranked by relevance to the question,
- a fast typed pre-decision pass routes the query (tools vs. context vs.
  plain answer; see [Fast typed decisions](/guide/fast-decisions) — and
  [Custom decision specs](/guide/decision-specs) to replace the verdict with
  your own schema),
- relevant files are rendered into the prompt under the model's
  runtime-detected context budget (`SystemLanguageModel.contextSize` — 4,096
  tokens on macOS 26; larger on newer systems).

A stderr `Context:` note lists which files were included. If no candidate
files are found under the root, the command falls back to a plain query.

The on-device model's context window is small for a codebase, so large repos
get **selective context**: the highest-scoring slice, not everything.

## Tool use

```sh
siri-ai ask "Where is the token bucket implemented?" --repo . --tools
```

`--tools` gives the model real tool calls so it can fetch what it needs
itself:

| Tool | Purpose |
| --- | --- |
| `list_files` | list repository files |
| `read_file` | read the contents of a file |
| `search_files` | search across tracked files |

## Proposing edits

```sh
siri-ai ask "Add error handling to connect() in net.swift" --repo . --edit
```

`--edit` (implies `--tools`) additionally exposes the `propose_edit` tool: the
model inspects the repo with `list_files` / `read_file` / `search_files`, then
proposes either a minimal find/replace or a whole-file rewrite.

The proposal is rendered as a block diff in your terminal and **waits for
explicit y/N confirmation** before writing anything to disk. Declined edits
never touch the filesystem. Literal `\n` sequences emitted by the small
on-device model are unescaped to real newlines before the diff is shown.

When edit mode would engage from the routing decision alone (no explicit
`--edit`), a cheap edit pre-gate first confirms the query really asks for
code changes, so the y/N prompt is never raised for non-edit questions.
