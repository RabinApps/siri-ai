# Chat

`siri-ai chat` starts an interactive multi-turn session — see the
[chat CLI reference](/cli/chat) for session commands and options.

## How context carries across turns

The session embeds the transcript (last **8** messages, roles + contents)
into each prompt, so the model sees the conversation within its small
context window. `/history` marks messages older than that window with a `·`
— handy for debugging context carry.

With `--siri` the same transcript mechanism carries context, but Siri may
*also* consult (and store into) its own on-device memory — personal notes,
the user profile, previous conversations — which is outside siri-ai's
control. Pass `--no-memory` to forbid that: Siri is instructed to treat the
session transcript as its only context, never recall facts from stored
memory, and never save anything from the conversation.

The chat loop deliberately skips the fast typed decision pass (see
[Fast typed decisions](/guide/fast-decisions)): interactive latency matters
most there, and the transcript prompt already encodes what the user asked.
