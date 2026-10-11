---
title: permission
description: "siri-ai permission: check and grant the macOS permissions the CLI and app need."
---

# permission

Check and grant the macOS permissions siri-ai needs.

```sh
siri-ai permission            # interactive walk-through with live checks
siri-ai permission --check-only
siri-ai permission --accessibility-only
```

## Options

| Flag | Description |
| --- | --- |
| `--check-only` | Only print the current permission status and exit (no wizard). Exits non-zero if anything is missing. |
| `--accessibility-only` | Skip Screen Recording (only needed for diagnostics/OCR fallback). |

## What gets checked

| Permission | Why | System Settings path |
| --- | --- | --- |
| **Accessibility** | Read Siri AI's answers from its UI tree | Privacy & Security → Accessibility |
| **Screen Recording** | Power the diagnostics and OCR fallback surfaces | Privacy & Security → Screen Recording |

Permissions are granted to the **app that runs siri-ai** — Terminal, iTerm, or
your IDE's embedded terminal.

## The wizard

For each missing permission:

1. It prints why the permission is needed.
2. Prompts `Open System Settings → <pane> now? [Y/n]` and opens the exact
   settings pane if you confirm. Declining exits non-zero with a note to rerun
   the command when ready.
3. Live-polls once per second and prints `[✓] … granted` the moment the switch
   flips — macOS usually applies the grant within a second or two.
4. If nothing lands after **5 minutes**, it exits non-zero and tells you to
   rerun when ready.

Already-granted permissions are skipped with `[✓] … already granted`. When
everything is granted the wizard ends:

```text
All required permissions granted.
Try: siri-ai ask "hello" --backend siri
```

Ctrl-C stops the wait at any point.

## Related

- [`status`](/cli/status) — diagnose both backends in one shot
- [Permissions guide](/guide/permissions)
