---
title: serve
description: "siri-ai serve: run the local OpenAI-compatible HTTP server on a port you choose."
---

# serve

Run a local OpenAI-compatible HTTP server so any OpenAI SDK or tool can use
Apple Intelligence.

```sh
siri-ai serve --port 11434
```

## Options

| Flag | Description |
| --- | --- |
| `--port <n>` | Port to listen on (default: `11434`). |

## Endpoints

| Endpoint | Description |
| --- | --- |
| `GET /health` | Liveness probe |
| `GET /v1/models` | Model list |
| `POST /v1/chat/completions` | Chat completions, streaming (SSE) and buffered |

The server is backed by Apple Intelligence only — the `siri-ai` model on the
[Serve API](/serve/) pages can also be selected per request, but `serve` itself
constructs the Apple Intelligence engine.

See the [Serve API](/serve/) section for request/response details.

::: tip
The server is deliberately dependency-free (raw BSD sockets). SwiftNIO or
Hummingbird can be swapped in later if concurrency requirements grow; the
endpoint semantics will not change.
:::
