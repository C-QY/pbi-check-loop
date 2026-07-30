---
name: pbi-check-loop
description: Control Power BI Desktop on this machine to close the feedback loop that breaks when an AI develops Power BI reports. Two capabilities - (1) restart Desktop so it re-reads TMDL/PBIR files changed on disk, auto-dismissing the sign-in dialog and restoring window placement; (2) capture the Desktop window to PNG so the agent can see what actually rendered. Trigger - reload - after editing TMDL/measures/PBIR when the user needs to see the effect in Desktop, "reload pbi", "restart Power BI Desktop", "let Desktop re-read the files", "重开一下 Desktop", "让 Desktop 重新读盘", "重载一下". Trigger - screenshot - when you need to see how the report looks, "看看现在报表", "截个图", "show me the report", or when the user reports an error or rendering problem in Desktop. Windows + PowerShell only.
version: 1.0.0
license: MIT
allowed_tools: [PowerShell, Read]
---

# Power BI Desktop control

## Why this exists

Agentic development of Power BI reports has its feedback loop severed in two places:

1. **The model layer has two sources of truth.** TMDL lives on disk; Desktop holds a separate
   copy in memory. Your edits to disk are invisible to Desktop — and if the user presses
   <kbd>Ctrl</kbd>+<kbd>S</kbd> at that moment, **the stale in-memory model overwrites your
   disk changes**.
2. **The report layer emits pixels, not files.** You can write `visual.json` but cannot see
   what renders.

Without tooling a human has to be your eyes and hands. With it, they don't.

---

## 1. Reload: `pbi-reload.ps1`

```powershell
& "$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -Path "...\x.pbip"   # first run
& "$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -Yes                 # afterwards (path remembered)
& "$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -ListOnly            # report state, change nothing
```

Flow: `Stop-Process` (= no save, no dialog) → clean up the associated `msmdsrv` → reopen with
**the same edition** it was running (regular vs. Report Server, auto-detected) → a detached
watcher process dismisses the sign-in dialog and restores window placement.
The script returns in ~2 seconds; the watcher runs in the background and does not block.

| Parameter | Meaning |
|---|---|
| `-Path` | `.pbip` path, remembered in `pbi-reload.last.json` beside the script |
| `-Yes` | **Asserts the user confirmed there are no unsaved changes.** Without it the script only warns |
| `-Id` | Which instance to restart when several are running |
| `-ListOnly` | Report state only |
| `-NoDismiss` | Do not auto-dismiss the sign-in dialog |

### 🔴 Required before every call

**Ask the user in conversation whether Desktop has unsaved changes. Pass `-Yes` only after
they say no.**

Two opposite situations exist and the tool **cannot distinguish them from outside** — Desktop's
title bar carries no modified marker, and window enumeration exposes no dirty state:

| Situation | Correct action |
|---|---|
| Disk TMDL was edited, Desktop memory is stale | Never save — saving overwrites the disk edits |
| User just edited in Desktop without saving | Must save first — otherwise the kill discards it |

⚠️ **Do not assume "the user never edits in Desktop."** That assumption was empirically
falsified — polishing the report layer is the user's job by design.

🔴 **No GUI prompts inside the script** (`Popup`, `MessageBox`, `Read-Host` are all forbidden).
Confirmation belongs in the conversation. A popup version was built and rejected twice; it has
been removed. Do not reintroduce it.

### Be proactive

When you finish editing TMDL and the user needs to see the effect, **offer the reload yourself** —
do not wait to be asked.

---

## 2. Screenshot: `pbi-shot.ps1`

```powershell
& "$env:USERPROFILE\.claude\tools\pbi-shot.ps1" -Out "D:\tmp\a.png"   # capture the window
& "$env:USERPROFILE\.claude\tools\pbi-shot.ps1" -FullScreen           # capture all monitors
```

Then read the PNG with the Read tool to see the rendered result.

- Uses `PrintWindow(hwnd, hdc, 2)` — **captures non-foreground and even occluded windows**.
- 🔴 **Never calls `SetForegroundWindow`.** The user may be working on another monitor;
  stealing focus interrupts them.
- If the bitmap comes back near-uniform it is treated as a failure and falls back to
  `CopyFromScreen` — which captures raw screen pixels, so an occluding window would appear
  in the image instead. A warning is printed when this happens.
- ⚠️ `-FullScreen` captures everything on the user's screens. Privacy-sensitive.
  **Default to window capture.**

### What you can and cannot see

**Can see:** layout, colours, values, field list, and **the text of error dialogs** — so the user
no longer needs to copy-paste error messages to you.

**Cannot do:** interact. No scrolling, clicking, page switching, or expanding filters. You only
see the current screen. If the problem is elsewhere, ask the user to navigate there first.
If an error dialog's details pane is collapsed, you cannot read it either.

---

## Rules

**Do NOT read the scripts into context — execute them.** `pbi-reload.ps1` is ~330 lines and
`pbi-shot.ps1` ~130. This document already states everything you need to call them. Read the
source only when you intend to modify it.

**Treat captured screenshots as confidential.** A Power BI window contains live business data —
revenue, supplier names, part numbers, customer records. Consequently:

- Write captures to a temporary/scratch path, never into the user's project or a git repo
- Never publish one to an artifact, a web page, or any external service
- Do not transcribe values wholesale into your reply; quote only what the question requires
- Error dialogs may expose connection strings, server names, or credentials —
  **never echo those back verbatim, and never commit them**

**Do NOT expose secrets, tokens, or passwords** read from config files, logs, or screenshots.

**Match the user's language.** Reply in Chinese to Chinese prompts, English to English ones.

## Typical combination

```
edit TMDL/PBIR → ask about unsaved changes → pbi-reload.ps1 -Yes
              → wait for load (large models take a while) → pbi-shot.ps1 → Read the PNG
              → not right? edit again
```

---

## Empirical findings

Read these before modifying the scripts. Each one cost a debugging cycle to discover; several
describe bugs that were fixed, so do not reintroduce them.

1. **The sign-in dialog appears on an ~11 second delay**, not at launch. Logic that exits once
   "the main window has been responsive for 3 seconds" never catches it.
2. **The dialog's window title is exactly `登录到 Power BI`**, class
   `WindowsForms10.Window.20008.app.*`. Match on title — it never misfires on the user's own
   Options dialog. Close it with `PostMessage WM_CLOSE`, equivalent to clicking ×, i.e. Cancel.
3. **The watcher must be a detached process**
   (`Start-Process powershell -File $PSCommandPath -WatchPid`). `Start-Job` dies with the calling
   session, and an agent's every invocation is its own session — so a job always fails here.
4. **Window restoration cannot be applied once.** Desktop resets its own window state while
   loading, clobbering the restore. It must be reapplied in a loop.
5. **`IsZoomed` returning `True` does not mean the window is actually maximized.** Observed:
   the flag was set while the window sat at the temporary 800×600 size. Judge by
   "final rectangle ≈ original rectangle", never by the state flag.
6. **Do not verify too early.** Measured 798×600 three seconds after launch; the settled value
   was 1508×900. That was a snapshot of a transient state. Watch for the full restore window
   (45 s by default) before concluding.
7. Maximize retry must be **`SW_RESTORE` → `MoveWindow` → `SW_MAXIMIZE`**. Without the restore
   step the latter two silently do nothing.
8. While loading, the main window title is `无标题 - Power BI Desktop`; it becomes the project
   name only once loading completes.
9. **Scripts containing non-ASCII text must be saved as UTF-8 *with* BOM.** Without it,
   PowerShell 5.1 misreads them as GBK and parsing fails. Write them with Python's `utf-8-sig`.
10. Every restart leaves a stale folder under
    `%LOCALAPPDATA%\Microsoft\Power BI Desktop\AnalysisServicesWorkspaces\`. These accumulate.
    Not cleaned automatically — deleting one still in use would be destructive.

## Unresolved

The root cause of Desktop showing the sign-in dialog on every launch was **not identified**.
Ruled out: sensitivity-label preview feature, Translytical task flow, all Copilot preview
features. `FeatureSwitches.xml` stores GUIDs with no name mapping; trace logs are empty unless
the registry value `TracingEnabled` is set to 1 first (not attempted).

**This does not affect usage** — dismissal matches on window title and is indifferent to cause.
