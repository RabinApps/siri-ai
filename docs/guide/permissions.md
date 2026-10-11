---
title: Permissions
description: "Diagnose and grant the macOS Accessibility and Screen Recording permissions siri-ai needs."
---

# Permissions

`siri-ai permission` checks the macOS permissions both backends need, opens
the matching System Settings pane for anything missing, and polls live until
the grant lands — so you see it flip the moment you flip the switch.

```sh
siri-ai permission            # interactive walk-through with live checks
siri-ai permission --check-only
siri-ai permission --accessibility-only   # skip Screen Recording
```

## What gets checked

| Permission | Needed for |
| --- | --- |
| **Accessibility** | Driving the Siri AI app through the AX API |
| **Screen Recording** | Reading on-screen content for AX capture |

## Diagnosis

For a full rundown of both backends — on-device model availability,
Accessibility permission, and whether the Siri AI app can be launched — run:

```sh
siri-ai status
```
