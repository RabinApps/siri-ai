# ask

One-shot question to a backend.

```sh
siri-ai ask "Explain async/await in two sentences"
cat main.swift | siri-ai ask "What does this code do?"
siri-ai ask "How does payment processing flow through this repo?" --repo ~/src/payments
siri-ai ask "Where is the token bucket implemented?" --repo . --tools
siri-ai ask "Add error handling to connect() in net.swift" --repo . --edit
siri-ai ask "..." --backend siri       # ask the real Siri AI app instead
siri-ai ask "..." --no-stream          # buffer the whole answer before printing
siri-ai ask "..." --temperature 0.9 --max-tokens 512
siri-ai ask "..." --max-seconds 60     # bail out with exit 124 if the engine wedges
```

The question can be passed as an argument or piped via stdin (`cat main.swift | siri-ai ask "What does this code do?"`). With `--repo`, a fast typed pre-decision pass routes the query (see [Fast typed decisions](/guide/fast-decisions); add `--no-fast-decisions` to force the deterministic heuristic verdict instead).

## Options

| Flag | Description |
| --- | --- |
| `--repo <path>` | Repository root to ground the answer in (defaults to the current working directory). Files are scanned (honoring `.gitignore`, skipping binaries/vendored dirs), ranked by relevance, and rendered into the prompt under the model's runtime-detected context budget. A stderr `Context:` note lists which files were included. |
| `--tools` | Show the model the files it asks for, via real tool calls (`list_files`, `read_file`, `search_files`). A stderr `Tools used:` note lists which tools ran. |
| `--edit` | Allow the model to propose file edits with a y/N confirmation (implies `--tools`). |
| `--backend <backend>` | `apple` (default) or `siri` for the Siri AI app. |
| `--no-stream` | Disable streaming; buffer the full answer before printing. Applies to the context-stuffing path, not the agentic `--tools` path, which always answers in one buffered response. |
| `--temperature <t>` | Sampling temperature, 0.0–2.0. |
| `--max-tokens <n>` | Maximum response tokens. |
| `--no-fast-decisions` | Skip the fast typed pre-decision pass (query routing + edit gate) and use CLI flags/heuristics only. |
| `--max-seconds <n>` | Wall-clock deadline in seconds for the model answer; exits 124 with a diagnostic when exceeded. Guards against the rare case where the on-device engine wedges and cooperative cancellation cannot break it. |
| `--decisions <path>` | Use a user-defined decision spec that fully replaces the built-in routing verdict. See [Custom decision specs](/guide/decision-specs). Auto-discovered from `<repo>/.siri-ai/decisions.spec` when present. |

With `--repo`, the routing pass may engage tools or edit mode even without the
flags (CLI flags only *widen* the decision, never narrow it). Edit mode
engaged this way passes through a cheap edit gate first, so a y/N prompt is
never raised for clearly non-edit queries.

With `--decisions` (or a discovered `.siri-ai/decisions.spec`), the user's
schema and rules fully replace the built-in verdict and pre-gate — the spec
is the gate. See [Custom decision specs](/guide/decision-specs).

See [Repository Q&A & Editing](/guide/repo-editing) for the details of
grounding, tool use, and edit proposals.
