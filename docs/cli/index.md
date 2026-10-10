# CLI Reference

`siri-ai` is a single Swift 6 binary. Available commands:

| Command | Description |
| --- | --- |
| [`status`](/cli/status) | Diagnose engine availability and permissions |
| [`permission`](/cli/permission) | Check and grant the macOS permissions siri-ai needs |
| [`ask`](/cli/ask) | One-shot question, optionally repo-grounded; includes the fast typed pre-decision pass (see [Fast typed decisions](/guide/fast-decisions)) |
| [`chat`](/cli/chat) | Interactive multi-turn session |
| [`serve`](/cli/serve) | OpenAI-compatible HTTP server |
