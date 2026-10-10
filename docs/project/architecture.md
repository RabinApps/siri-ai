# Architecture

Everything below lives in the importable library target `SiriAILib` (the
`SiriAILib` package product apps can embed); the executable target (`siri_ai`,
the `siri-ai` binary) is a thin ArgumentParser shell over it.

```
Sources/SiriAILib/
├── Engine/
│   ├── LLMEngine.swift          shared EngineRequest/AgentResponse protocol
│   ├── AppIntelligenceEngine.swift  FoundationModels (LanguageModelSession)
│   ├── SiriAXEngine.swift        AX automation of the Siri AI app (+ AXCleaner)
│   └── FastDecisions/
│       └── FastDecisionEngine.swift  "System 1" typed routing + heuristic fallback
├── Context/
│   ├── RepoScanner.swift        gitignore, binary/vendored filtering
│   └── ContextBuilder.swift     token-budget file selection (~3.5 chars/token)
├── Tools/
│   ├── FileTools.swift          list_files / read_file / search_files
│   └── EditTools.swift          propose_edit with y/N confirm gate
├── Server/OpenAIServer.swift    raw-socket OpenAI-compatible HTTP server
└── Support/                     output helpers, stdin, permissions, exit codes

Sources/siri_ai/           
└── CLI/SiriAICommand.swift      Argument Parser: ask/chat/serve/status/permission
```

The server is deliberately dependency-free (raw BSD sockets) — only
swift-argument-parser is imported. SwiftNIO/Hummingbird can be swapped in
later if concurrency requirements grow; the endpoint semantics will not
change.

Before the heavy inference paths, a "System 1" pass makes a fast typed
decision (schema-constrained `@Generable` output from a single on-device
model call, capped at ~2 s) about whether a query needs tools, repo context,
or is an edit request. The pass is Apple-backend-only and always falls back
to deterministic heuristics on throw, timeout, or `--no-fast-decisions`; see
the [Fast typed decisions guide](/guide/fast-decisions.md).

## Known limits

- The on-device model context window is detected at runtime via
  `SystemLanguageModel.contextSize` (4,096 on macOS 26; a larger window — e.g.
  8,192 — on macOS 27/newer hardware). Large repos get selective context, not
  everything.
- The Siri AX backend drives a UI — it is fragile against macOS updates that
  change the Siri AI app's structure, and cannot stream responses.
- Siri-AX responses are captured by polling the AX tree to stability; the
  cleaner strips double renders, card-title fragments, calculator boxes, and
  the stray AX counter so answers come back as clean blocks. Novel UI shapes
  from future macOS updates may still leak through.
