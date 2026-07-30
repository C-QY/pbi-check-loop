# pbi-check-loop

Power BI Desktop control tools **for AI agents**. Closes the feedback loop that breaks when an
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

| Tool | Closes |
|---|---|
| `pbi-reload.ps1` | Gap 1 — automates close → reopen → dismiss login dialog → restore window |
| `pbi-shot.ps1` | Gap 2 — turns on-screen pixels into a PNG the agent can read |

Previously, each iteration required six human actions: notice the agent finished → close Desktop
(correctly deciding whether to save) → wait for reload → dismiss the login dialog → drag the
window back if it jumped monitors → look at the result and **describe it back to the agent**.

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
git clone https://github.com/<user>/pbi-check-loop.git
cd pbi-check-loop
.\install.ps1
```

This installs two things:

| From | To |
|---|---|
| `bin\*.ps1` | `~\.claude\tools\` |
| `skill\SKILL.md` | `~\.claude\skills\pbi-check-loop\` |

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

## The generalizable part

> Any GUI development tool that ① keeps state in its own memory rather than on disk, and
> ② produces visual rather than textual output, will sever an agent's feedback loop the same way.
> The remedy is always the same two moves: **mechanize the state refresh**, and **give the agent a
> screen-capture channel.**

Nothing about that is specific to Power BI. It holds for Figma, Unity, CAD, or any IDE plugin.

## An honest note

These scripts total ~400 lines of PowerShell and contain **no clever engineering**. What actually
took time was the empirical findings — the login dialog appears on an ~11 second delay, the watcher
must be a detached process or it dies with the calling session, `IsZoomed` can return `True` while
the window was never actually expanded. **Anyone rebuilding this hits the same walls.**

The value is in the ten findings at the end of [`skill/SKILL.md`](skill/SKILL.md), not in the code.

## License

MIT
