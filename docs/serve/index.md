# Serve API

`siri-ai serve` exposes a local, OpenAI-compatible HTTP API backed by Apple
Intelligence.

```sh
siri-ai serve --port 11434
```

## Endpoints

| Endpoint | Description |
| --- | --- |
| `GET /health` | Liveness probe |
| `GET /v1/models` | Model list |
| `POST /v1/chat/completions` | Chat completions, streaming (SSE) and buffered |

## Models

| Model id | Aliases | `owned_by` | Description |
| --- | --- | --- | --- |
| `apple-intelligence` | `apple` | `local` | The on-device FoundationModels model. Private, streaming, tool-capable. The default: any unrecognized model name resolves here. Buffered requests get a fast typed tool-routing decision. |
| `siri-ai` | `siri`, `openai/siri-ai` | `apple` | Routes the request through the real Siri AI chat app via the macOS Accessibility API. No tool calling. |

### The `siri-ai` model

Requires the Siri AI app (macOS 27) and Accessibility permission. Streaming
is **emulated**: every growth of the app's AX tree is emitted as a
settle-progress delta, and a final convergence delta guarantees the
concatenated stream equals the cleaned answer (a `\v` re-render marker
appears if Siri rewrites earlier text).

Model-name matching is case-insensitive.

::: info
The app's true bundle ID on macOS 27 is `com.apple.campo` — it displays as
"Siri AI" but runs under that internal name; the engine automates it via that
ID.
:::

## Example

Quick check with curl:

```sh
curl localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"apple-intelligence","messages":[{"role":"user","content":"Hello"}],"stream":true}'
```

With the OpenAI TypeScript SDK:

```ts
import OpenAI from "openai";
const client = new OpenAI({
  baseURL: "http://localhost:11434/v1",
  apiKey: "not-needed",
});
const r = await client.chat.completions.create({
  model: "siri-ai",
  messages: [{ role: "user", content: "What is the capital of Austria?" }],
});
console.log(r.choices[0].message.content);
```
