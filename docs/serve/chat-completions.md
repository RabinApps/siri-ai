# POST /v1/chat/completions

OpenAI-compatible chat completions, streaming (SSE) and buffered.

## Request

```json
{
  "model": "apple-intelligence",
  "messages": [{ "role": "user", "content": "Hello" }],
  "stream": true
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `model` | string | `apple-intelligence` (default), `apple`, `siri-ai`, `siri`, or `openai/siri-ai`. Case-insensitive; any unrecognized name resolves to `apple-intelligence`. |
| `messages` | array | Standard OpenAI chat messages |
| `stream` | boolean | SSE streaming when `true`; buffered response when `false` |

## Models

- **`apple-intelligence`** (default) — the on-device FoundationModels model.
  Private, streaming, tool-capable. On buffered (non-`stream`) requests, a
  fast typed pre-decision pass decides whether to attach a file tool layer,
  giving HTTP clients parity with `siri-ai ask --tools`.
- **`siri-ai`** — routes the request through the real Siri AI chat app via the
  macOS Accessibility API. No tool calling. Streaming is emulated: every
  growth of the app's AX tree is emitted as a settle-progress delta, and a
  final convergence delta guarantees the concatenated stream equals the
cleaned answer (a raw vertical-tab (\u000B) re-render marker appears if Siri
rewrites earlier text; the server escapes it in the JSON payload). Requires
the Siri AI app (macOS 27) and Accessibility permission.

## Other endpoints

| Endpoint | Description |
| --- | --- |
| `GET /health` | Liveness probe |
| `GET /v1/models` | Model list |
