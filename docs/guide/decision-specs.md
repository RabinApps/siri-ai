# Custom decision specs

The built-in System 1 verdict (see [Fast typed decisions](/guide/fast-decisions))
uses a fixed schema: `needsTools`, `needsContext`, `isEditRequest`. You can
**fully replace** it with your own typed decision schema and routing rules.

## Supplying a spec

Two ways, the explicit one wins:

```sh
siri-ai ask "..." --repo . --decisions ~/my-decisions.spec
```

…or check a spec into the repo at `.siri-ai/decisions.spec`; it is
auto-discovered for every `ask --repo <root>` run against that root (a
stderr note confirms it). No spec → built-in behavior, unchanged.

::: warning
A spec that exists but fails to parse is a hard error — it exits with the
parser diagnostic rather than silently falling back, because a broken spec
should never quietly change routing behavior. When the model call itself
fails or times out, routing degrades safely to "plain answer" (no false
positives).
:::

## The format

A small line-oriented format — `#` comments, one declaration per line:

```
# Repo triage (example)
name "CodeTriage"

field wantsReview:bool "True when the user wants a code review or audit"
field depth:string[quick|deep] "How thorough the answer should be"
field complexity:int "Difficulty 0-9, your judgment" optional

rule wantsReview==true -> useContext
rule depth==deep, complexity>=5 -> useTools
rule wantsReview==true, depth==deep -> applyEdit
```

The model fills this schema in one constrained call; your rules translate
what it says into routing outcomes.

## Fields

| Kind | Declaration | Notes |
| --- | --- | --- |
| bool | `field gate:bool "desc"` | `optional` + `default(true)` supported |
| string | `field mode:string[a\|b\|c] "desc"` | allowlist rendered as allowed values |
| int | `field depth:int "desc"` | supports `optional` |

Every field needs a quoted description — it is shown to the model and does
the semantic work; phrase it like a reviewer you trust.

## Rules and outcomes

```
rule <conditions> -> <outcomes>
```

- Conditions: `field==value` (any kind, case-insensitive for strings) or
  `field>=n` (int floor). Omitted optional bools read as `false`.
- Outcomes: `useTools` `useContext` `applyEdit` or their negatives
  `noTools` `noContext` `noEdit`.
- Rules run in order; every matching rule applies, later rules win.

Full replacement means **your rules are the whole gate**: the built-in
heuristic verdict and edit pre-gate are bypassed whenever a spec is active.
The CLI `--tools/--edit` flags still widen the outcome when the spec route
dismisses them — explicit user intent always wins.

## Tunables

| Env var | Purpose |
| --- | --- |
| `SIRI_AI_DECISION_TIMEOUT` | Decision-call ceiling in seconds (default 2, max 10). Specs get the same budget by default — raise it if your schema is large. |
| `SIRI_AI_DEBUG_DECISIONS=1` | Print each verdict and whether it came from `model+spec[<name>]` or fell back. |
