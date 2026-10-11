---
name: siri-ai-serve
description: Use the siri-ai serve OpenAI-compatible API — run or call the local HTTP server backed by Apple Intelligence. Use when the user needs a localhost OpenAI endpoint (POST /v1/chat/completions, GET /v1/models, GET /health), SDK examples, model ids, SSE streaming semantics, or error envelopes from siri-ai serve.
---

# siri-ai serve — OpenAI-compatible API

Run a dependency-free, loopback-only OpenAI-compatible HTTP server over Apple
Intelligence. Any OpenAI SDK or HTTP client can consume it; nothing leaves
the Mac.

## Start the server

```sh
siri-ai serve --port 11434   # default port 11434; Ctrl-C to stop
```

On startup it prints `Serving Apple Intelligence on http://127.0.0.1:<port>`.
The bind fails with `Could not bind port <n>` if something else is listening
— pick another port. Before assuming model/service problems, confirm the
backend with `siri-ai status` (this skill assumes a running server; see the
`siri-ai-subagent` skill for the status/permissions playbook).

A harness should start it detached (stdin off, logs redirected) and poll
`GET /health` until it answers before sending requests.

## Endpoints

| Endpoint | Method | Response |
| --- | --- | --- |
| `/health` | GET | `200` — `{"status":"ok"}` |
| `/v1/models` | GET | `200` — OpenAI models-list shape |
| `/v1/chat/completions` | POST | `200` — buffered JSON, or SSE when `"stream": true` |
| anything else | * | `404` — `{"error":{"message":"not found"}}` |

The server is loopback-only (raw BSD sockets, no framework) and caps request
bodies at 1 MB.

## Models (`GET /v1/models` + request routing)

| Model id | Aliases (case-insensitive) | `owned_by` | Notes |
| --- | --- | --- | --- |
| `apple-intelligence` | `apple` | `local` | Default for ANY unrecognized name. On buffered requests a fast typed pre-decision pass may attach the file-tool layer (parity with `ask --tools`; the server resolves no repo root, so it is generic file tools, not repo-scoped). |
| `siri-ai` | `siri`, `openai/siri-ai` | `apple` | Routes through the real Siri AI app via Accessibility (macOS 27). No tool calling. Streaming is emulated from the app's AX tree; see the rewrite marker below. |

## `POST /v1/chat/completions`

Request (all supported fields — others are not accepted by the parser):

```json
{
  "model": "apple-intelligence",
  "messages": [
    { "role": "system", "content": "You are a terse coding assistant." },
    { "role": "user", "content": "Hello" }
  ],
  "stream": false,
  "temperature": 0.7
}
```

| Field | Type | Behavior |
| --- | --- | --- |
| `model` | string | Routed per the table above; unknown → `apple-intelligence` |
| `messages` | array | `system` message becomes the system prompt; the **last non-system message** is the prompt; up to **6 prior turns** are rendered as context. `role`/`content` strings only. |
| `stream` | boolean (optional) | `true` → SSE `text/event-stream`; `false`/omitted → buffered JSON |
| `temperature` | number (optional) | Passed to the engine |

There is **no `max_tokens`** support — `EngineRequest.maxTokens` is always
nil over HTTP. A malformed body returns `400` (see Errors).

### Buffered response

Standard OpenAI chat-completion JSON: `id` (`chatcmpl-…`), `created`,
`model` (echoes the requested name), `choices[0].message.content`,
`finish_reason: "stop"`.

### Streaming (SSE)

`stream: true` sends `Transfer-Encoding: chunked` `data: <json>` events of
`chat.completion.chunk` shape; each event's `delta.content` is one engine
delta, and the stream ends with a delta whose `finish_reason` is `"stop"`.

Two cases harnesses must handle:

1. **Mid-stream failure** arrives as an SSE error event, not a second HTTP
   status (the 200 is already on the wire):
   `data: {"error":{"message":"…","type":"engine_unavailable|engine_timeout|backend_error"}}`
   then the terminating chunk. Accumulate whatever completed and surface the
   error to the user.
2. **Siri rewrite marker** (model `siri-ai` only): when the Siri app
   re-renders earlier text, the server closes the obsolete rendering with a
   `finish_reason: "length"` chunk and then streams the replacement as a
   **new choice index** (index+1). A client that accumulates every delta and
   **drops its buffer on any non-empty rewrite event** reproduces the final
   answer exactly.

### Errors

| Status | `error.type` | Cause |
| --- | --- | --- |
| `400` | *(no `type` field)* | Malformed JSON body: `{"error":{"message":"invalid request body"}}` |
| `404` | — | Unknown route |
| `503` | `engine_unavailable` | Backend capability missing (e.g. model unavailable) |
| `504` | `engine_timeout` | Engine timed out — work may or may not have completed |
| `500` | `backend_error` / `internal_error` | Engine fault / unknown error (no raw error leaks) |

## Client examples

curl (buffered):

```sh
curl localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"apple-intelligence","messages":[{"role":"user","content":"Hello"}]}'
```

OpenAI TypeScript SDK:

```ts
import OpenAI from "openai";
const client = new OpenAI({ baseURL: "http://localhost:11434/v1", apiKey: "not-needed" });
const r = await client.chat.completions.create({
  model: "apple-intelligence",
  messages: [{ role: "user", content: "What is the capital of Austria?" }],
});
console.log(r.choices[0].message.content);
```

The API key is a placeholder — no auth is enforced (the server is
loopback-only, so only local processes can reach it; do not expose it).

References: serve CLI flags →
[docs/cli/serve](https://siri-ai.rabinapps.com/cli/serve/) · full
request/response spec →
[Serve API](https://siri-ai.rabinapps.com/serve/)
