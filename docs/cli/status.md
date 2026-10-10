# status

Diagnose engine availability and permissions.

```sh
siri-ai status
```

## Example output

```text
system: macOS 26.1 on Mac
apple:  OK — Apple Intelligence on-device model available
window: 4096 tokens for repo-grounded context
siri:   OK — Siri AI app reachable via Accessibility

All good. Try: siri-ai ask "explain this repo" --repo .
```

## What it checks

| Line | Description |
| --- | --- |
| `system` | Host summary: macOS version and machine model (`Host.current().localizedName`). |
| `apple` | Whether the Apple Intelligence on-device model is available. `OK` is followed by "Apple Intelligence on-device model available"; on failure the detail names the reason: device not eligible, Apple Intelligence not enabled, or the on-device model still downloading. |
| `window` | The on-device model's real context window in tokens (`SystemLanguageModel.contextSize` — macOS 26 reports 4,096, macOS 27/newer hardware 8,192). Repo-grounded answers are budgeted against this. |
| `siri` | Whether the Siri AI backend is usable: app presence and Accessibility permission. |

When either backend is ready, the command prints the `All good.` note with a
suggested first command.

## Related

- [`permission`](/cli/permission) — fix the permissions `status` reports as missing
- [Permissions guide](/guide/permissions)
