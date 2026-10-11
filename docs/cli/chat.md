---
title: chat
description: "siri-ai chat: interactive multi-turn session with /history, /clear, /quit and system prompts."
---

# chat

Interactive multi-turn session.

```sh
siri-ai chat -s "You are a terse coding assistant"
siri-ai chat --siri             # through the real Siri AI app
siri-ai chat --siri --no-memory # Siri answers from the transcript only
```

## Session commands

| Command | Action |
| --- | --- |
| `/quit` or `/exit` | Exit |
| `/clear` | Reset history (keeps the session system prompt) |
| `/history` | Print the stored transcript (`·` marks messages that will NOT be sent with the next prompt, i.e. older than the last-8 window) |

## Options

| Flag | Description |
| --- | --- |
| `--siri` | Use the Siri AI app instead of Apple Intelligence. |
| `--no-memory` | Siri backend only: ignore Siri's own on-device memory; context comes from this session's transcript alone. |
| `-s, --system <prompt>` | System prompt for the session (default: "You are a concise assistant."). |

The prompt line shows `[turn N · last Xms > ]` once a turn has completed,
including the last turn's latency.

With `--siri`, the settled final answer is used for display and history
(streaming would bake mid-generation Siri chrome into the transcript and
compound it across turns). How the transcript carries context — and the
deliberate absence of the fast decision pass in this loop — is covered in
the [Chat guide](/guide/chat).
