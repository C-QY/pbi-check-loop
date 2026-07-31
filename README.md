# pbi-check-loop

> **Power BI Desktop cannot reload a PBIP that changed on disk — there is no such command.**
> This adds it, plus a way for an agent to see what rendered, so AI-assisted Power BI
> development becomes a closed loop instead of one that stops for a human every iteration.

**[中文 →](README.zh-CN.md)** · Windows only · PowerShell 5.1+ · MIT

---

## ✨ What It Does

🔁 **The agent fixes its own mistakes** — writes TMDL, reloads, reads the error as text, corrects it, goes again  
🚦 **Checks before reloading** — no disk change, no reload; a wasted reload costs a full model load  
👀 **Two ways to look** — PNG for vision models, UI Automation text for the rest  
🪟 **Puts the window back** — same monitor, same placement; dismisses the sign-in dialog if it appears  
🤝 **Safe with several agents** — finds its own instance by project name, never kills someone else's

```powershell
irm https://raw.githubusercontent.com/C-QY/pbi-check-loop/main/get.ps1 | iex
```

Restart Claude Code and it is live. [Full install notes ↓](#install)

---

## The Bigger Picture: Where the AI Workflow Breaks

PBIP is the precondition for all of this. Storing a report as a **project** — plain text on
disk, under version control — is what separates the **model layer** (M and DAX) from the
**report layer** (prototype and visual implementation), and it is what makes any of it
scriptable by an agent at all.

Once you have that, an honest look at AI-assisted Power BI development shows four distinct
jobs, at very different levels of maturity:

| Layer | The work | Who verifies it | Loop status |
|---|---|---|---|
| **Structure** | Is the TMDL/PBIR valid? Fields bound, visuals on canvas? | Read the files back | ✅ automatable, long since |
| **Numbers** | Does this measure return the right value? | ADOMD/DAX against the live model | ✅ **already a high-fidelity loop** |
| **Refresh** | Does Desktop actually *see* what was written to disk? | — | ❌ **no such feature exists** |
| **Visual** | Does the rendered page match the prototype? | — | ❌ **a human, every single time** |

**The model layer has had a closed, high-fidelity loop for years.** Point ADOMD at the local
Analysis Services instance, run DAX, compare the number to the source. The agent writes a
measure, queries it, and knows whether it was right. No human required.

**What was missing was everything downstream of the file write.** And it fails in two places.

### 1. Power BI Desktop has no "reload from disk"

This is the gap, stated plainly: **Power BI Desktop ships no way to re-read a PBIP project that
changed on disk.** File → Save writes memory to disk. There is no command anywhere in the
product for the opposite direction.

Sync is one-way, and it is the wrong way for agentic work:

| Direction | Command | Exists? |
|---|---|---|
| Memory → disk | File → Save | ✅ |
| **Disk → memory** | **—** | ❌ **nothing** |

That asymmetry was harmless when a human typed every measure into the UI: memory was always the
newer copy. It becomes the central obstacle the moment an agent writes TMDL directly, because
now **disk is the newer copy and Desktop cannot be told.** Worse, the one sync command that does
exist actively destroys the work — pressing <kbd>Ctrl</kbd>+<kbd>S</kbd> at that moment
**overwrites the new disk content with the stale in-memory model**.

So the natural-language half of the workflow already works: you describe a change, the agent
edits the semantic model on disk, correctly. And then it stops dead — because there is no
supported way to make the running Desktop see it. The only recourse is closing and reopening the
application by hand, every single iteration.

**That is what this fills.** `pbi-reload.ps1` supplies the missing disk → memory direction: it
terminates without saving (so the stale model can never win), cleans up the orphaned `msmdsrv`
process, and reopens the same project with the same edition — restoring the window where it was.

To be precise about the mechanism: this is a **restart, not a hot reload**. The window does
close; what changes is that closing and reopening are no longer a human's job. Each round still
costs a full model load, which remains the dominant expense per iteration.

#### The alternative: write to the live model instead

There *is* a way to change a running model without restarting anything. TOM, connected to the
local Analysis Services instance, writes model metadata directly — this is what the entire
external-tool ecosystem is built on. It is genuinely faster, and worth knowing precisely what it
does and does not cover:

| | Hot write via TOM | Effect |
|---|---|---|
| **DAX measures** | ✅ | Fully live — measures are evaluated at query time, so the next query uses the new definition |
| **Power Query / M** | ⚠️ | The definition changes, but already-loaded data does not re-materialize until a refresh |
| **Report layer** (PBIR, `visual.json`) | ❌ | No live-write API exists at all — layout and visuals are files, only ever files |

So hot-writing works, and for pure DAX work it is the quicker path. **The reason this project
takes the slower one is version control.**

TOM writes into the memory of a running process. Until someone saves, **nothing exists on disk**:
no diff to review, no commit to revert to, no branch, no pull request. Version control does not
become impossible, but it degrades from being the medium of change to being a record made
afterwards — hot-write, then save, then commit, with that middle step a manual action inside
Desktop. Two people hot-writing the same instance is last-write-wins, with no conflict to detect.

That is the actual trade. A full model load per round buys a workflow where **every change is a
reviewable text diff before it is ever applied** — and where the report layer, which has no hot
path at all, works the same way as the model layer instead of needing a second workflow.

### 2. The report layer emits pixels, not files

An agent can write `visual.json` but cannot see what renders. Correct, misaligned, unreadable —
all equally unknowable to it.

The net effect of the two together is that **a human becomes the agent's eyes and hands**. Not
out of habit — the loop was structurally open.

> **Observability is not a loop.** Being able to take a screenshot is not the same as being
> able to judge one — that is having `stdout` but no `assert`. A loop needs an oracle. See
> [Loop 2](#loop-2--report-layer-iterating-toward-the-prototype).

---

## Loop 1 — Model Layer: Edit, Reload, Diagnose, Repeat

This is the loop for semantic-model work: adding measures, editing relationships, reworking M.
You describe the change in natural language, the agent edits the TMDL on disk — and then
**Reload supplies the step Power BI itself does not have**, so the running Desktop picks it up.

```
       ┌─────────────────────────────────────────────────┐
       │                                                 │
   edit TMDL ──▶ Check ──▶ Reload ──▶ load ──▶ error? ───┤
   on disk        │          │                   │       │
                  │          │                   ▼       │
            "no change?"  human OK'd         Shot -Text  │
             stop here    "-Yes"             read it ────┘
```

**Where each piece fits:**

- **Check** answers *did anything actually change on disk?* If not, stop — a needless reload
  costs a full model load
- **Reload** makes Desktop re-read the files. This is the step that used to be manual, every
  single time
- **Shot `-Text`** reads any error dialog **as text** rather than pixels. An agent that can read
  `The column 'Amount' of the table wasn't found` verbatim can usually fix it and go around
  again by itself

That last point is what turns error handling into part of the loop rather than an interruption.
Reading an error off an image is guesswork; reading it as a string is a diagnosis.

> ⚠️ **The numbers still belong to ADOMD.** This skill tells you the model *loaded*; it does
> not tell you the measure is *correct*. For that, query the live model with DAX — that loop
> already worked and this one does not replace it.

**A reload is not a data refresh — and that is the point.** Reopening re-reads the model
definition and recomputes every DAX expression against the cached data, which is exactly what a
measure, relationship or formatting change needs. It never goes back to the source:

| Changed | Needs |
|---|---|
| Measures, relationships, columns, formatting, PBIR | A reload. Seconds |
| Rows in the underlying source | A manual Refresh — minutes, and the user's call |

The distinction matters for the loop. Refreshing on every iteration would take minutes instead
of seconds and could hit a production database, so the skill is explicitly told never to trigger
one. Changing *how* something is calculated is iteration; changing *what data* it runs on is a
new task, and a human decision.

### Two classes of failure, handled in opposite ways

Reopening a project you just edited is exactly when it breaks — and the first move is to
classify, because the two classes want opposite things.

| | **Class A — it will not open** | **Class B — a visual is broken** |
|---|---|---|
| Symptom | Modal error dialog, no project loaded | Report renders, one tile errors or is blank |
| Loop state | **Severed** — nothing downstream runs | **Intact** — Reload and Shot still work |
| Handling | Read the error, **close the instance**, fix on disk, reopen | Diagnose in place, **keep it open** |
| Why | A broken instance holds the project and its `msmdsrv` child; the next reload has to fight both | Closing throws away a working loop for no reason |

Class A is usually TMDL syntax, a reference to something that no longer exists, or an invalid
relationship. Class B is usually a stale `queryRef` pointing at a renamed measure, or a single
table that failed to load while everything else rendered fine.

> ⚠️ **Not every bad edit produces a dialog.** A broken calculated table lets the project open
> normally and fails silently — verified in testing. The absence of an error box is not proof
> the edit was good: check that what you edited actually renders.

---

## Loop 2 — Report Layer: Iterating Toward the Prototype

This is the part that was completely open, and it is the reason the project exists.

**The prototype is not decoration. It is the test oracle.**

An agent cannot answer *"does this look right?"* — that question has no ground truth it can
reach. But it can answer *"does this match the prototype?"* — and that question is decidable
from an image. Supplying a mockup converts an unanswerable question into an answerable one.

```
   prototype (the oracle)
        │
        ▼
   write PBIR ──▶ Reload ──▶ Shot (PNG) ──▶ compare to prototype
        ▲                                          │
        │                                          ▼
        └──────── still off? adjust ◀────── matches? done
```

So the workflow becomes: **design the prototype with a human, then let the agent converge on it
unattended.** The human sets the target; the agent runs the laps.

`SKILL.md` carries this as an explicit checklist the agent works through, so the loop is a
procedure rather than a suggestion:

```
- [ ] 0. Establish the oracle — prototype, or a written spec of "correct"
- [ ] 1. Confirm no unsaved changes (once, up front — not every round)
- [ ] 2. Edit the PBIR/TMDL on disk
- [ ] 3. Reload
- [ ] 4. Wait for the title to settle, then Shot
- [ ] 5. Compare against the oracle; list concrete differences
- [ ] 6. Differences remain and rounds < 2 → back to step 2. Otherwise stop and report.
```

Three rules keep it honest:

- **No oracle, no loop.** With no prototype the agent does one round, shows you the result, and
  lets you judge. It must never invent a standard and then declare success against it
- **Ask about unsaved changes once, not every round.** Re-confirming each iteration would defeat
  the point of running unattended — but if you touch Desktop mid-run, the loop stops and re-asks
- **Stop after two failed rounds.** Each round costs a full model load, and a third rarely finds
  what the first two missed

---

## The Agent Reaches For It Unprompted

A tool that waits to be invoked keeps a human in the loop by construction. So the skill instructs
the agent to act on its own, graded by what each action can destroy:

| Action | Risk | Behaviour |
|---|---|---|
| **Check** | none — read-only | Runs **immediately** after any project file is written. Never asks |
| **Shot** | none — read-only | Runs whenever the agent needs to see the result. Never asks |
| **Reload** | high — terminates Desktop without saving | Consent **once per session**, then announce and proceed |

Both halves live in the skill's `description` — the part every session preloads — not only in
its body. A preloaded instruction to act autonomously, paired with a safety condition that
loads later, is just an instruction to act unsafely.

### Making sure it actually gets used

An installed skill is selected by matching its description against what you asked for. That is
the weak point here: when you say *"change this measure to exclude group purchases"*, nothing in
that sentence mentions reloading or Desktop. The agent can finish the edit and consider the task
done — with the change sitting on disk, invisible.

The description is therefore written around **working on a `.pbip` at all**, not around the word
"reload", and it states plainly that *an edit is not finished until the reload runs*.

For a project you work on daily, make it a standing rule. One line in the repository's
`CLAUDE.md` is more reliable than any phrasing in a description:

```markdown
After editing any .tmdl / .pbir / visual.json, reload with pbi-check-loop before
reporting the task complete. A disk change that Desktop has not re-read is not done.
```

A `PostToolUse` hook could enforce this mechanically, but it fires on every edit — including
files that have nothing to do with Power BI — and removes the agent's judgement entirely. The
standing rule gets most of the reliability at none of that cost.

The reload asymmetry matters. Asking every single time would put the human back in the inner
loop — the exact cost this project exists to remove. Asking *never* would gamble with unsaved
work. So consent is taken once, up front:

> I'll reload Desktop to verify this, and do the same after each further edit. That discards
> anything unsaved in Desktop — please don't edit there while I work. OK?

After that the agent **announces and proceeds without waiting** — one line, then the reload. It
does not block for a reply each round, but it never goes silent either: a reload blanks Desktop
for tens of seconds, and silence reads as a hang. Consent is re-taken when the premise breaks —
you say you edited in Desktop, you take over the window, or you tell it to stop.

---

## What Stays Human, On Purpose

Some parts of the loop are deliberately left open. Not because the tooling is immature —
because closing them would be wrong:

- **"Any unsaved changes in Desktop?"** — Two opposite situations exist and the tool **cannot
  tell them apart from outside**:

  | Situation | Correct action |
  |---|---|
  | TMDL on disk was edited, Desktop's memory is stale | Never save — it would overwrite the disk |
  | Someone edited in Desktop without saving | Must save first — otherwise the kill discards it |

  Desktop's title bar carries no modified marker and window enumeration exposes no dirty state.
  **This is information asymmetry, not a capability gap.** So the script refuses to act without
  `-Yes`, and that confirmation happens in conversation — never in a popup

- **Business semantics.** Whether "revenue" excludes intercompany is not a question a screenshot
  can settle
- **The last mile of taste.** The agent can reach the prototype. Deciding the prototype was
  right is yours

---

## Three Modes

| Mode | Purpose | Command | Works without vision |
|---|---|---|---|
| **Check** | Are disk files newer than the running instance? Reports PID, edition, title | `pbi-reload.ps1 -ListOnly` | ✅ |
| **Reload** | Terminate, clean up `msmdsrv`, reopen the same edition, restore the window | `pbi-reload.ps1 -Yes` | ✅ |
| **Shot** | Window to PNG, or `-Text` for plain text via UI Automation | `pbi-shot.ps1` | ✅ with `-Text` |

`-Text` is not a downgrade. It reaches dialog text, the table/field tree, and the report canvas
itself — visual titles, matrix headers, cell values — through the embedded WebView's
accessibility tree. It is often *more* precise than the image: a name the capture truncates to
`SALES_DETAIL_BY_RE…` comes back whole. The real boundary is **semantics vs. presentation**:
text tells you what the report *says*, only an image tells you how it *looks*.

> ⚠️ **Only image mode needs vision.** A text-only model that calls it and then describes the
> report is inventing content — worse than no capture at all. The skill requires such models to
> use `-Text` or hand the path to a human.

---

## Preview

**Check** — should we reload at all?

```
Current instance
  PID       : 36292
  Edition   : regular
  Title     : Sales Analysis - Power BI Desktop
  Started   : 07/30/2026 15:45:03

Disk changed since Desktop opened - reload needed
  15:07:50  measures.tmdl
  14:55:27  relationships.tmdl
```

**Reload** — returns in ~2 s; a detached watcher finishes the job:

```
Restarting
  Window rect recorded: -8,-8,2568,1400 (maximized)
  Terminating Desktop (no save)...
  Cleaning up orphaned msmdsrv 30512...
  Reopening [regular] Sales Analysis.pbip ...
  Watcher started (dismiss sign-in + restore window, 120s)
```

**Watcher log** — exits as soon as the work is done, not when the timeout expires:

```
[16:34:22] watch start pid=24868 timeout=120s
[16:34:25] window settled L=-8 T=-8 2576x1408 maximized (still watching to 45s)
[16:34:29] dismissed title='Sign in to Power BI'
[16:35:07] restore done final L=-8 T=-8 2576x1408 target 2576x1408 -> OK
[16:35:19] watch end (work done), dismissed 1
```

*(Real output; project names replaced.)*

---

## Install

```powershell
irm https://raw.githubusercontent.com/C-QY/pbi-check-loop/main/get.ps1 | iex
```

Scripts land in `~\.claude\tools\`, the skill in `~\.claude\skills\pbi-check-loop\`. The
installer verifies PowerShell syntax and UTF-8 BOM on every file it writes. Restart Claude Code
to activate the skill. Run the same command again to update.

<details>
<summary>Manual install</summary>

```powershell
git clone https://github.com/C-QY/pbi-check-loop
cd pbi-check-loop
.\install.ps1
```

Uninstall: `.\install.ps1 -Uninstall`
</details>

**Several agents on one machine** (each on its own report): always pass `-Path`. The script
matches the project name against window titles to find *your* instance, so it never touches
another agent's Desktop; `-Id` is the fallback when no title matches.
**Several agents on one report** is a different problem — two writers on the same TMDL/PBIR, a
file-layer conflict this tool cannot serialize. Don't structure work that way.

---

## What It Does Not Do

- **It does not make loading faster.** Desktop's model load is untouched, and that remains the
  dominant cost per iteration
- **The agent cannot operate the report** — no scrolling, clicking, or page switching. If the
  problem is not on the current screen, a human has to navigate there first
- **It does not verify numbers.** That is ADOMD's job, and that loop already existed
- It closes the loop on *seeing* the report layer, not on *judging* it — that needs the oracle

---

## Design Principles

**Fast · Lightweight · Universal** — the scripts collect metadata only, never file content.

| Layer | Content | Token cost |
|---|---|---|
| L1 | `SKILL.md` frontmatter | ~255 tokens per session, used or not |
| L2 | `SKILL.md` body | ~1900 tokens, loaded only when triggered |
| L3 | `scripts/*.ps1` | Executed, never read — zero tokens |

---

## What This Actually Is

Stated as narrowly as it can honestly be stated: **this automates the stretch between "the agent
edited the file" and "the agent can see what that did."**

That framing is deliberately small, and it is the reason two short scripts are enough. The gap
was never wide — editing already worked, judging already worked. Only the segment in the middle
had nothing in it, and it happened to sit where every iteration must pass.

In practice that means one thing above all: **an agent that edits TMDL can now recover from its
own mistakes.** Write a measure, reload, read the error as text, fix it, go again — without a
human relaying what the screen said. Everything else here is in service of that.

### A guess, offered as a guess

The same shape may exist elsewhere. A GUI tool that keeps state in memory rather than on disk,
emits pixels rather than files, and assumes edits happen *inside the application* would break an
agent's loop the same way once that agent starts editing its files from outside. The fix would
presumably be the same two moves — mechanize the state refresh, open a viewing channel.

**But that is a conjecture from a single case.** Power BI is the one instance I have actually
worked through; I have not verified it against Figma, Unity, or anything else. Treat it as a
hypothesis worth testing, not a finding.

---

## An Honest Note

These two scripts are a few hundred lines of PowerShell and contain **no clever code**. The time
went into the empirical findings — the sign-in dialog appears on an 11-second delay, the watcher
must be detached or it dies with the calling session, `IsZoomed` returns `True` for a window that
was never actually expanded. **Anyone rebuilding this hits the same walls.**

The value is in the eleven findings in [`docs/FINDINGS.md`](docs/FINDINGS.md), not the code.

---

## Requirements

| Platform | Status |
|---|---|
| Windows | ✅ PowerShell 5.1+, Power BI Desktop installed, a `.pbip` project |
| macOS / Linux | ❌ Power BI Desktop does not exist there — nothing to support |

## License

MIT
