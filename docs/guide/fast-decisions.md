---
title: Fast typed decisions
description: "The fast typed System-1 routing pass: what it decides, where it applies, fallback chain, custom schemas."
---

# Fast typed decisions (System 1)

Before the slow "System 2" generation, siri-ai makes a fast, schema-constrained
"System 1" decision: one typed call to the on-device Apple Intelligence model
that answers small routing questions about your query. The slow answer pass
then runs only the machinery that verdict demands.

## What it decides

One typed verdict per query, covering:

| Field | Meaning |
| --- | --- |
| `needsTools` | Answering well requires inspecting repository files (list/read/search), not knowledge alone. |
| `needsContext` | Stuffing relevant repo text into the prompt would materially help. |
| `isEditRequest` | The user asks to change, write, fix, or create code. |

The verdict is produced as a **schema-constrained** output (`FoundationModels`
`@Generable`) — the small on-device model cannot ramble, and a cheaper
yes/no `EditGate` verdict re-confirms edit mode when it would engage purely
on the model's say-so. In practice a decision costs a fraction of a second;
it is capped with a ~2 s timeout so a slow model call can never dominate.

## Where it applies

- **`ask --repo ...`** — the verdict picks the tools / stuffed-context /
  plain branch for the query.
- **`ask` edit pre-gate** — when edit mode would engage from the decision
  alone (no explicit `--edit`), the cheap edit gate confirms so a y/N prompt
  is never raised for clearly non-edit queries.
- **serve (buffered `apple-intelligence` requests)** — the verdict decides
  whether to attach a file tool layer, giving HTTP clients parity with
  `ask --tools`.

Explicitly **not** covered (deliberate scope):

- the `chat` per-turn loop (interactive latency matters most),
- any decision path through the Siri AX backend (no structured-output
  guarantee, latency is already seconds),
- streaming server requests (the decision would sit in the hot path).

## Rule: CLI flags only widen the decision

CLI flags are explicit user intent. The decision pass can only ever *add*
tool layers or context — it never narrows what the user asked for:
`--tools` still guarantees tool access even if the verdict says "plain".

## Fallback chain

Never a hard dependency — if anything goes wrong, a deterministic heuristic
router decides instead:

1. typed model call (schema-constrained, ~2 s timeout),
2. on throw/timeout/unavailability → keyword/signal heuristics (edit verbs,
   file nouns, path/extension regexes) — pure, instant, table-tested,
3. `--no-fast-decisions` / `SIRI_AI_NO_FAST_DECISIONS` → always heuristic,
   skipping the model call entirely.

## Custom schemas

The built-in verdict can be fully replaced by a user-supplied decision spec
(own fields + own routing rules) — see [Custom decision specs](/guide/decision-specs).

## Debugging

Set `SIRI_AI_DEBUG_DECISIONS=1` to print every verdict to stderr, including
its source (`model` or `heuristic`), so you can see whether the pass steered
the route:

```sh
SIRI_AI_DEBUG_DECISIONS=1 siri-ai ask "how does payment work" --repo .
```
