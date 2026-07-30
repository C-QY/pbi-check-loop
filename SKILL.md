---
name: pbi-check-loop
description: >-
  Closes the feedback loop that breaks when an AI develops Power BI reports, so the model iterates
  by itself instead of a human repeatedly closing, reopening and eye-checking Desktop after every
  edit. Checks whether files on disk are newer than the running instance. Reloads Desktop so it
  re-reads changed TMDL and PBIR, restoring window placement and dismissing the sign-in dialog
  when the environment shows one (signed-in users never see it).
  Captures the window as a PNG, or with -Text reads it through UI Automation as plain text so a
  model without vision works too. Use when editing TMDL, measures or PBIR; when the user says
  “重开一下 Desktop”, “让 Desktop 重新读盘”, “重载一下”, “reload pbi”; on “Desktop 是最新的吗”, “需要重载吗”, “check pbi state”;
  on “看看现在报表”, “截个图”, “show me the report”; or whenever the user reports an error or rendering problem.
  Runs Check before any Reload. Windows and PowerShell only.

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
auto-detected → a detached watcher restores window placement and, if your environment shows a
sign-in dialog at launch, dismisses it (some environments never show one; that branch simply
does nothing).
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
& "$env:USERPROFILE\.claude\tools\pbi-shot.ps1" -Out "<scratch>\pbi.png"   # image
& "$env:USERPROFILE\.claude\tools\pbi-shot.ps1" -Text                      # plain text
```

Image mode uses `PrintWindow`, capturing non-foreground and even occluded windows without
stealing focus; read the PNG with the Read tool. **If a dialog is open, its text is printed
automatically alongside the image** — an error read as text beats reading it off pixels.

| Parameter | Meaning |
|---|---|
| `-Out` | Output path. Default `%TEMP%\pbi-shot.png` |
| `-Text` | Read the window via UI Automation instead of capturing pixels |
| `-Id` | Which instance, when several run |
| `-FullScreen` | All monitors instead of the window — privacy-sensitive, avoid by default |

**Pick the channel by what you are asking:**

| Question | Use |
|---|---|
| What does this error say? | `-Text` |
| Which visuals are on the page, with what columns? What value is in this cell? | `-Text` |
| Which tables and relationships exist? | `-Text` |
| Do the numbers tie out? | ADOMD DAX against the live model (not this skill) |
| Are fields bound / visuals off-canvas? | read back the PBIR JSON you just wrote |
| **Layout, colours, spacing — does it match the mockup?** | **image + vision** |

The boundary is **semantics vs. presentation**: text gives what the report *says*, only an image
gives how it *looks*. Text is sometimes the more precise of the two — a name the capture
truncated to `PUR_DAILY_STOCK_DE…` comes back whole as `PUR_DAILY_STOCK_DETAIL`.

🔴 **If you cannot read images, never call image mode and then describe the report** — you would
be inventing content. Use `-Text`, or hand the PNG path to the user and ask what they see.

🔴 **`-Text` output is business data** — real material codes, company names, amounts. Handle it
exactly like a capture: never publish, never commit, quote only what the question needs.

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

**Compare against something.** A capture on its own is not a verdict. If a prototype or
mockup exists, compare to it and name the differences. If none exists, report what you observe
and let the user judge — do not invent a standard.

**Stop after two failed rounds.** If two edit → reload → shot cycles have not converged, stop
and tell the user what you tried and what you are seeing. Iterating further burns a full model
load each time and rarely finds a problem the third pass will.

**Do NOT read the scripts into context — execute them.** `pbi-reload.ps1` is ~330 lines,
`pbi-shot.ps1` ~130. This document states everything needed to call them. Read the source only
to modify it.

**Treat captures as confidential.** A Power BI window shows live business data —
revenue, supplier names, part numbers, customers. Therefore:

- Write captures to a temporary/scratch path, never into the user's project or a git repo
- Never publish one to an artifact, a web page, or any external service
- Quote only the values the question requires; do not transcribe the screen
- Error dialogs may expose connection strings, server names, or credentials —
  never echo those verbatim and never commit them

**Do NOT expose secrets, tokens, or passwords** found in config files, logs, or captures.

**Be proactive.** After editing TMDL, offer the reload yourself; do not wait to be asked.

**Several agents, one machine.** `pbi-reload.last.json` (the remembered path) is shared across
every user of the tool, so always pass `-Path` explicitly: your instance is then identified by
matching the project name against window titles, and you cannot kill another agent's instance.
`-Id` remains the fallback when no title matches. **Several agents on ONE report is a different
problem** — the conflict lives at the file layer (two writers on the same TMDL/PBIR), which this
tool cannot serialize. Don't do it.

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

## Maintaining these scripts

Eleven empirically discovered pitfalls (dialog timing, detached watcher, `IsZoomed` lying about
maximized state, verifying too early, BOM requirements) and the unresolved sign-in-dialog root
cause live in [`docs/FINDINGS.md`](docs/FINDINGS.md). **Read it only if you are modifying the
scripts** — calling them does not require it.
