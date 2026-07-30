# pbi-check-loop

Power BI Desktop control tools **for AI agents** — **loop engineering** for Power BI
development: give the agent back the edit → observe → judge → iterate loop that breaks when an
LLM develops Power BI reports.

**[中文 →](README.md)** · Windows only · PowerShell 5.1+

> The consumer is an **agent**, not a human. That is why this ships as a Claude Code **skill**
> rather than as shell aliases for someone to type.

## The problem

Agentic coding works because the model can **verify its own work** — run tests, read output,
iterate. Power BI development structurally severs that loop in two places:

**1. The model layer has two sources of truth.**
TMDL lives on disk; Power BI Desktop holds a separate copy in memory. When an agent edits
the files, Desktop has no idea — and pressing <kbd>Ctrl</kbd>+<kbd>S</kbd> at that moment
**overwrites the new disk content with the stale in-memory model**. Every iteration therefore
requires a human to close and reopen Desktop.

**2. The report layer emits pixels, not files.**
An agent can write `visual.json`, but it cannot see what renders. Whether the change is correct,
misaligned, or unreadable is simply unknowable to it.

The net effect: **a human becomes the agent's eyes and hands.** That is not a matter of
preference; it is structural.

## What this does

Together the three modes close a loop: **agent edits on disk → reload → self-check the capture →
compare against the oracle (prototype/expectation) → next round of edits.** The human stays
outside the loop, answering a single question: "any unsaved changes in Desktop?"

Three modes:

| Mode | Purpose | Script | Text-only model |
|---|---|---|---|
| **Check** | Report whether Desktop is stale — **are files on disk newer than the running instance** — plus PID, edition, workspace | `pbi-reload.ps1 -ListOnly` | ✅ |
| **Reload** | Restart Desktop so it re-reads disk: close → reopen → restore window placement (also dismisses the sign-in dialog — only some environments show one) | `pbi-reload.ps1 -Yes` | ✅ |
| **Shot** | Capture the window to PNG so the agent sees what rendered | `pbi-shot.ps1` | ❌ **needs vision** |

**Check gates Reload.** If nothing changed on disk, reloading only costs the user a full model
load for nothing.

> ⚠️ **Only Shot depends on a multimodal model.** A text-only model that calls it cannot see the
> image yet may invent its contents — worse than having no screenshot. SKILL.md requires such a
> model to hand over the file path and ask the user instead of describing the image itself.

Previously, each iteration required six human actions: notice the agent finished → close Desktop
(correctly deciding whether to save) → wait for reload → dismiss the login dialog (absent in
environments that don't show one) → drag the window back if it jumped monitors → look at the
result and **describe it back to the agent**.

Now the human does only the first: answer "no unsaved changes" in chat. Steps 2–5 are automated;
step 6 the agent does itself.

## What this does *not* do

- **No speed-up of model load.** Desktop still takes just as long to load a large model — which is
  the dominant cost.
- **The agent cannot interact with the report.** No scrolling, clicking, or page switching. If the
  problem is not on the current screen, a human must navigate there first.
- **It does not remove the human from the decision** — deliberately. See [`-Yes`](#the-yes-flag).
- Solves *seeing* the report layer, not *editing* it.

## Install

Requires Windows, PowerShell 5.1+, and Power BI Desktop.

```powershell
git clone https://github.com/C-QY/pbi-check-loop.git
cd pbi-check-loop
.\install.ps1
```

This installs two things:

| From | To |
|---|---|
| `scripts\*.ps1` | `~\.claude\tools\` |
| `SKILL.md` (repo root) | `~\.claude\skills\pbi-check-loop\` |

The installer verifies PowerShell syntax and UTF-8 BOM encoding on every installed script.
Restart Claude Code afterwards so the skill is picked up.

Uninstall with `.\install.ps1 -Uninstall`.

## Usage

```powershell
& "$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -ListOnly       # report state only
& "$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -Yes            # reload
& "$env:USERPROFILE\.claude\tools\pbi-shot.ps1"  -Out shot.png    # capture window
```

### The `-Yes` flag

`-Yes` asserts that **a human has confirmed there are no unsaved changes in Desktop**.
Without it the script prints a warning and does nothing.

This matters because two opposite situations exist and the tool **cannot tell them apart from
the outside**:

| Situation | Correct action |
|---|---|
| Disk TMDL was edited, Desktop memory is stale | Never save — saving overwrites the disk edits |
| A human just edited in Desktop without saving | Must save first — otherwise the kill discards it |

Desktop's title bar carries no modified marker and window enumeration exposes no dirty state.
**Only a human knows.** So the confirmation cannot be skipped — and it should not be a GUI popup
either (that interrupts); it belongs in the conversation.

> **Several agents on one machine** (each on its own report): always pass `-Path` — the script
> matches the project name against window titles and finds *your* instance, never touching
> another agent's Desktop; `-Id` is only the fallback when no title matches.
> `pbi-reload.last.json` is shared machine-wide, so omitting `-Path` may reuse what another
> agent remembered. **Several agents on ONE report** is a different matter — the conflict is at
> the file layer (two writers on the same TMDL/PBIR), which this tool cannot serialize.
> Don't split work that way.

## The generalizable part

> Any GUI development tool that ① keeps state in its own memory rather than on disk, and
> ② produces visual rather than textual output, will sever an agent's feedback loop the same way.
> The remedy is always the same two moves: **mechanize the state refresh**, and **give the agent a
> screen-capture channel.**

Nothing about that is specific to Power BI. It holds for Figma, Unity, CAD, or any IDE plugin.

## An honest note

These scripts total ~660 lines of PowerShell and contain **no clever engineering**. What actually
took time was the empirical findings — the login dialog appears on an ~11 second delay, the watcher
must be a detached process or it dies with the calling session, `IsZoomed` can return `True` while
the window was never actually expanded. **Anyone rebuilding this hits the same walls.**

The value is in the eleven findings in [`docs/FINDINGS.md`](docs/FINDINGS.md), not in the code.

## License

MIT
