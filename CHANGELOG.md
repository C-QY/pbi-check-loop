# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Changes driven by real agent use on a ~670k row model. Every item is something that
actually cost time — the second batch came from using the first batch all day.

### Second batch — what using `-Wait` all day exposed

- **`Ready` now means the model engine is up, not just the window title.** The title flips
  to the project name *while `msmdsrv` is still starting*; a DAX query fired at that moment
  returns "table not found", which is indistinguishable from an edit that broke the model.
  `-Wait` now also waits for the instance's `msmdsrv` child. Observed twice in one session:
  once as a failed query, once as `pbi-shot` finding no window.
- **`-Wait` and `-ListOnly` now print the Analysis Services endpoint** (`localhost:<port>`,
  resolved parent PID → child `msmdsrv` → listening port).

  This closes the last gap in the loop. A capture proves a visual *rendered*; only a DAX query
  proves a number is *right* — so something must tell the caller where to send it. The obvious
  source, `msmdsrv.port.txt`, is a trap with two projects open: the newest file belongs to
  whichever loaded last, so the agent silently queries the **wrong model**, asks for a table
  that lives in the project it was editing, and gets "table not found". That reads like a
  broken edit and sends the investigation the wrong way. Happened during the session; the
  workaround was hand-rolling the PID→port mapping, which every caller would otherwise repeat.
- **`pbi-shot` no longer says "main window not found (it may still be loading)"** when the real
  cause is a different instance. It now names the PID it searched and lists every running
  Desktop with its title.
- **`SKILL.md`: do not save reloads up to do them together.** The tempting version — *finish
  investigating, then reload everything at once* — sounds efficient and loses work: while the
  agent is away, a user Ctrl+S writes Desktop's in-memory model over the edits on disk.
  Observed exactly that. Reload after each edit, even when the next step is only a lookup.

### First batch

### Added

- **`pbi-reload.ps1 -Wait`** — block until the model has finished loading, then return.
  Reports `Ready after Ns`, `Desktop exited …`, or a timeout pointing at `pbi-shot.ps1 -Text`.
  `-WaitTimeout` sets the limit (default 180 s).

  Without it every caller has to poll the window title, and **the intuitive way to poll is
  silently wrong**: waiting for the title to stop being `Untitled - Power BI Desktop` fails on a
  localized Desktop — zh-CN shows a different word entirely — so the check passes the instant any
  window appears, and the agent then queries a half-loaded model. Observed live: a hand-written
  poll reported "ready" while the model was still loading. `-Wait` matches the *project name*,
  which only a finished load can produce, in any language.

### Changed

- **`SKILL.md` / both READMEs — the "reload is not a refresh" table gained its missing third row.**
  Changing a **partition's M expression** needs a reload *and* a manual Refresh: reloading
  invalidates that table's cached data, so it comes back **empty**, and every table whose M
  references it goes empty too. Pages bound to them render blank — which looks exactly like a
  broken edit and was diagnosed as one during the session before the cause was found. The agent
  is now told to recognise the symptom, say so, and hand the Refresh back to the user.
- **`SKILL.md` — the session-scoped reload consent now ships with a line to say.**
  "Announce and proceed" was too abstract to hold under pressure: when a reload costs the user a
  long refresh, an agent re-opens the consent it already has ("…OK?"), which is the exact failure
  mode this skill exists to remove. The rule now supplies a statement to copy, and names the
  hedging impulse so it can be recognised and skipped.
- **`SKILL.md` — failure-handling table** gained the two `-Wait` outcomes (timeout → read the
  dialog; process exited → Class A).

## [1.0.0] - 2026-07-30

First release. Both tools verified end to end on a dual-monitor Windows 11 machine
against Power BI Desktop with a ~910k row model.

### Added

- **`pbi-reload.ps1`** — restart Power BI Desktop so it re-reads TMDL/PBIR changed on disk.
  - Terminates the process (no save, no dialog), cleans up the associated `msmdsrv` child.
  - Reopens with the **same edition** it was running (regular vs. Report Server), auto-detected.
  - Detached watcher process dismisses the `登录到 Power BI` sign-in dialog by title match.
  - Restores the window to its previous rectangle and maximized state, on whichever monitor
    it was on. Verified on both an external 2560×1440 display and a 1493×933 laptop panel.
  - Reports whether files on disk are newer than the running instance.
  - With `-Path` given, the target instance is identified by matching the project name against
    window titles — safe on multi-agent machines without a manual `-Id`. Warns when the single
    running instance's project does not match `-Path` (likely another agent's Desktop).
  - Refuses to act without `-Yes`; confirmation is expected to happen in conversation,
    never via a GUI popup.
- **`pbi-shot.ps1`** — capture the Power BI Desktop window to PNG so an agent can read it.
  - Uses `PrintWindow` with `PW_RENDERFULLCONTENT`; captures non-foreground and occluded windows.
  - Never calls `SetForegroundWindow` — stealing focus would interrupt work on another monitor.
  - Falls back to `CopyFromScreen` with a warning when `PrintWindow` returns a blank bitmap.
- **`SKILL.md`** (repo root) — Claude Code skill packaging, including trigger conditions, the
  confirmation protocol, and ten empirically discovered pitfalls.
- **`install.ps1`** — installs scripts and skill, verifies PowerShell syntax and UTF-8 BOM
  encoding on every installed file. Supports `-Uninstall`.
- **`agents/openai.yaml`** — manifest so OpenAI-compatible agent runtimes can register the skill,
  declaring `requires.vision: optional` since only Shot mode needs it.
- Bilingual documentation: `README.md` (English) and `README.zh-CN.md` (Chinese).
- All script output is English; the Chinese strings that remain are observed Windows dialog
  titles used for matching, not UI text.

### Fixed

- Sign-in dialog dismissal matched only the Chinese title (`登录到 Power BI`). Added the
  English `Sign in` prefix so English-locale Desktop installs are covered; further locales
  can be appended to the same list.
- Window restoration no longer trusts a degenerate recorded rectangle. A rect that is tiny
  or off every screen (recorded e.g. while the window was tucked at a screen edge) is now
  discarded — restoring it used to park the reopened window off-screen and fight the user's
  clicks for the whole 45 s restore window. The end-of-restore verdict now compares position
  and size instead of width only, which had reported a false `OK` for that same case.

### Notes

- The watcher exits 12 s after both of its jobs finish rather than idling until the timeout.
  Measured before the change: window restored at 3 s, dialog dismissed at 11 s, then 109 s of
  nothing. It still falls back to the timeout when no dialog ever appears.
- Documented that **only Shot requires a vision-capable model**. A text-only model must hand the
  file path to the user rather than describe an image it cannot see.
- **`pbi-shot.ps1 -Text`** reads the window through UI Automation instead of capturing pixels,
  so a model without vision can still work. It reaches dialog text, the field/table tree, and —
  contrary to a first shallow probe — **the report canvas as well**: visual titles, matrix column
  headers and cell values are all exposed through the embedded WebView's accessibility tree.
  The real boundary is semantics vs. presentation: text tells you what the report *says*, only an
  image tells you how it *looks*.
- Screenshot runs now **append dialog text automatically when a dialog is present**. Detection
  costs 20–130 ms against a ~1100 ms capture, and error text read as text beats reading it off
  an image. Nothing is printed when no dialog is up.

### Known limitations

- The agent cannot interact with the report — no scrolling, clicking, or page switching.
- Model load time is unchanged; it remains the dominant cost per iteration.
- Each restart leaves a stale folder under `AnalysisServicesWorkspaces\`. Not cleaned
  automatically, since removing one still in use would be destructive.
- The root cause of the recurring sign-in dialog was not identified. Sensitivity-label,
  Translytical task flow, and Copilot preview features were all ruled out. Dismissal works
  regardless of cause, since it matches on window title.

[1.0.0]: https://github.com/C-QY/pbi-check-loop/releases/tag/v1.0.0
