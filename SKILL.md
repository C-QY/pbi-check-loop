---
name: pbi-check-loop
description: >-
  Close the feedback loop that breaks when an AI develops Power BI reports.
  Three modes — Check: report whether Desktop is stale, i.e. whether files on disk are newer
  than the running instance, plus edition, PID and workspace. Reload: restart Desktop so it
  re-reads changed TMDL/PBIR, auto-dismissing the sign-in dialog and restoring window placement.
  Shot: capture the Desktop window to PNG so the agent can see what actually rendered.
  Trigger — check: "Desktop 是最新的吗", "需要重载吗", "看下 pbi 状态", "is Desktop stale",
  "check pbi state". Also run this automatically before any reload.
  Trigger — reload: after editing TMDL/measures/PBIR when the effect must be seen in Desktop,
  "重开一下 Desktop", "让 Desktop 重新读盘", "重载一下", "reload pbi", "restart Power BI Desktop".
  Trigger — shot: "看看现在报表", "截个图", "show me the report", or whenever the user reports
  an error, a rendering problem, or asks what something looks like in Desktop.
  Match longest trigger first — "重载一下" before "重载".
  Output language follows the user's: Chinese in, Chinese out.
  Windows + PowerShell only.
version: 1.0.0
license: MIT
allowed_tools: [PowerShell, Read]
resources:
  - scripts/pbi-reload.ps1
  - scripts/pbi-shot.ps1
---

## Why this exists

Agentic development works because the model can **verify its own work**. Power BI severs that
loop in two places:

1. **The model layer has two sources of truth.** TMDL lives on disk; Desktop holds a separate
   in-memory copy. Your edits are invisible to it — and if the user presses
   <kbd>Ctrl</kbd>+<kbd>S</kbd> then, **the stale model overwrites your disk changes**.
2. **The report layer emits pixels, not files.** You can write `visual.json` but cannot see
   what rendered.

## Model requirements

| Mode | Output | Usable by a text-only model |
|---|---|---|
| Check | text | ✅ yes |
| Reload | text | ✅ yes |
| **Shot** | **PNG image** | ❌ **no — requires vision** |

🔴 **If you cannot read images, do not call Shot and then describe the report.** You would be
inventing content, which is worse than having no screenshot at all. Instead either:

- run it anyway, tell the user the file path, and ask them what they see; or
- skip Shot and work from Check plus the user's own description.

Probed 2026-07-30: UI Automation exposes the ribbon, menus, buttons, page tabs and **dialog
text** as elements, but the report canvas is an embedded WebView whose accessibility tree yields
nothing useful (1185 descendants, all chrome). So *error text* is in principle readable as text,
while *what the report looks like* is not.

## Workflow

### Step 1 — Pick the mode

| Situation | Mode | Section |
|---|---|---|
| Need to know if Desktop is stale / which instance is running | **Check** | Step 2 |
| Disk was changed and the user must see the effect | **Reload** | Step 3 |
| Need to see what rendered, or diagnose a reported error | **Shot** | Step 4 |

**Always run Check before Reload.** If it reports no disk change, say so and stop — a reload
costs the user a full model load for nothing.

### Step 2 — Check

```powershell
& "$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -ListOnly
```

Changes nothing. Reports: PID, edition (regular vs. Report Server), window title, start time,
associated `msmdsrv` PID, and **whether any `*.tmdl / *.json / *.pbir / *.pbism` under the
project is newer than the running instance**.

That last line is the decision: *newer on disk* → reload is warranted; *no change* → it is not.

### Step 3 — Reload

**Before calling, ask the user in conversation: "Desktop 里有没有未保存的改动？"**
Pass `-Yes` only after they answer no. See [Rules](#rules) for why this cannot be skipped.

```powershell
& "$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -Yes                  # path remembered
& "$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -Path "...\x.pbip" -Yes   # first run
```

`Stop-Process` (no save, no dialog) → clean up `msmdsrv` → reopen with **the same edition**,
auto-detected → a detached watcher dismisses the sign-in dialog and restores window placement.
Returns in ~2 s; the watcher continues in the background.

| Parameter | Meaning |
|---|---|
| `-Path` | `.pbip` path, remembered in `pbi-reload.last.json` |
| `-Yes` | Asserts the user confirmed no unsaved changes. Without it the script only warns |
| `-Id` | Which instance to restart when several run |
| `-ListOnly` | Check mode (Step 2) |
| `-NoDismiss` | Leave the sign-in dialog alone |
| `-DismissTimeout` | Watcher lifetime, default 120 s |

Then **wait for the load to finish** before capturing — a large model takes tens of seconds.
The main window title reads `无标题 - Power BI Desktop` while loading and becomes the project
name when done.

### Step 4 — Shot

```powershell
& "$env:USERPROFILE\.claude\tools\pbi-shot.ps1" -Out "<scratch>\pbi.png"
```

Then read the PNG with the Read tool. Uses `PrintWindow`, so it captures non-foreground and
even occluded windows without stealing focus.

| Parameter | Meaning |
|---|---|
| `-Out` | Output path. Default `%TEMP%\pbi-shot.png` |
| `-Id` | Which instance, when several run |
| `-FullScreen` | All monitors instead of the window — privacy-sensitive, avoid by default |

### Step 5 — Report back

Keep it to the shape below. Do not narrate the mechanics.

**Check:**
```
Desktop  PID {pid} · {edition} · {title}
磁盘     {已变更，{N} 个文件 / 无变更}
结论     {建议重载 / 不用重载}
```

**Reload:** state the outcome in one line, then what you observed — window landed where,
dialog dismissed or not. Quote the watcher log only if something went wrong.

**Shot:** describe what the image actually shows and answer the user's question from it.
Do not dump the whole screen contents.

## Rules

**Ask before every reload.** Two opposite situations exist and the tool **cannot tell them
apart from outside** — Desktop's title bar carries no modified marker and window enumeration
exposes no dirty state:

| Situation | Correct action |
|---|---|
| Disk TMDL was edited, Desktop memory is stale | Never save — saving overwrites the disk edits |
| User just edited in Desktop without saving | Must save first — otherwise the kill discards it |

⚠️ **Do not assume "the user never edits in Desktop."** That assumption was empirically
falsified — polishing the report layer is the user's job by design.

🔴 **No GUI prompts inside the scripts** (`Popup`, `MessageBox`, `Read-Host`). Confirmation
belongs in the conversation. A popup version was built and rejected twice, then removed.
Do not reintroduce it.

🔴 **Never call `SetForegroundWindow`.** The user may be working on another monitor; stealing
focus interrupts them. `PrintWindow` does not need it.

**Do NOT read the scripts into context — execute them.** `pbi-reload.ps1` is ~330 lines,
`pbi-shot.ps1` ~130. This document states everything needed to call them. Read the source only
to modify it.

**Treat captured screenshots as confidential.** A Power BI window shows live business data —
revenue, supplier names, part numbers, customers. Therefore:

- Write captures to a temporary/scratch path, never into the user's project or a git repo
- Never publish one to an artifact, a web page, or any external service
- Quote only the values the question requires; do not transcribe the screen
- Error dialogs may expose connection strings, server names, or credentials —
  never echo those verbatim and never commit them

**Do NOT expose secrets, tokens, or passwords** found in config files, logs, or screenshots.

**Be proactive.** After editing TMDL, offer the reload yourself; do not wait to be asked.

**Match the user's language.** Chinese in, Chinese out.

## Failure handling

| Symptom | Meaning | Do this |
|---|---|---|
| `Power BI Desktop 未运行` | Nothing to reload | Ask whether to open the project, or just open it with `-Path` |
| `发现多个 Desktop 实例` | Several instances | Show the listed PIDs and editions, ask which, pass `-Id` |
| `没有可用路径` | No `-Path` and nothing remembered | Ask for the `.pbip` path |
| `已停下，什么都没动` | `-Yes` was omitted | Correct behaviour — confirm with the user first, then retry |
| Shot warns `PrintWindow 失败，已回退` | Captured raw screen pixels | The image may show an occluding window — say so rather than trusting it |
| `找不到 PBIDesktop 主窗口` | Still loading | Wait and retry; do not conclude the reload failed |
| Watcher log shows `守窗结束 … 不符` | Window restore did not settle | Report it; the reload itself still succeeded |

Watcher log: `~\.claude\tools\pbi-reload.dialogs.log`. Read it only when diagnosing.

## What this cannot do

- **No interaction.** No scrolling, clicking, page switching, expanding filters. You see only
  the current screen — if the problem is elsewhere, ask the user to navigate there first.
  A collapsed error-details pane stays unreadable to you.
- **No speed-up of model load** — still the dominant cost per iteration.
- **Report-layer editing is unaffected**; this solves *seeing*, not *changing*.

## Empirical findings

Read before modifying the scripts. Each cost a debugging cycle; several describe bugs already
fixed — do not reintroduce them.

1. **The sign-in dialog appears on an ~11 second delay**, not at launch. Logic that exits once
   "the main window has been responsive for 3 seconds" never catches it.
2. **Its window title is exactly `登录到 Power BI`**, class `WindowsForms10.Window.20008.app.*`.
   Match on title — it never misfires on the user's own Options dialog. Close with
   `PostMessage WM_CLOSE`, equivalent to clicking × i.e. Cancel.
3. **The watcher must be a detached process**
   (`Start-Process powershell -File $PSCommandPath -WatchPid`). `Start-Job` dies with the
   calling session, and an agent's every invocation is its own session.
4. **Window restoration cannot be applied once.** Desktop resets its own window state while
   loading, clobbering the restore. Reapply in a loop.
5. **`IsZoomed` returning `True` does not mean the window is maximized.** Observed: flag set
   while the window sat at the temporary 800×600. Judge by "final rectangle ≈ original
   rectangle", never by the state flag.
6. **Do not verify too early.** Measured 798×600 three seconds after launch; the settled value
   was 1508×900. Watch the full restore window (45 s) before concluding.
7. Maximize retry must be **`SW_RESTORE` → `MoveWindow` → `SW_MAXIMIZE`**. Without the restore
   step the latter two silently do nothing.
8. **Restoration is monitor-agnostic** — it records and replays the actual rectangle, so it
   works on any display. Verified on a 2560×1440 external monitor and a 1493×933 laptop panel.
9. **Scripts containing non-ASCII text must be saved as UTF-8 *with* BOM**, or PowerShell 5.1
   misreads them as GBK and parsing fails. Write them with Python's `utf-8-sig`.
10. Every restart leaves a stale folder under
    `%LOCALAPPDATA%\Microsoft\Power BI Desktop\AnalysisServicesWorkspaces\`. These accumulate;
    not cleaned automatically, since deleting one still in use would be destructive.

## Unresolved

The root cause of the sign-in dialog appearing on every launch was **not identified**.
Ruled out: sensitivity-label preview feature, Translytical task flow, all Copilot preview
features. `FeatureSwitches.xml` stores GUIDs with no name mapping; trace logs stay empty unless
the registry value `TracingEnabled` is set to 1 first (not attempted).

**Usage is unaffected** — dismissal matches on window title and is indifferent to cause.
