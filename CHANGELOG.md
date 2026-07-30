# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  - Refuses to act without `-Yes`; confirmation is expected to happen in conversation,
    never via a GUI popup.
- **`pbi-shot.ps1`** — capture the Power BI Desktop window to PNG so an agent can read it.
  - Uses `PrintWindow` with `PW_RENDERFULLCONTENT`; captures non-foreground and occluded windows.
  - Never calls `SetForegroundWindow` — stealing focus would interrupt work on another monitor.
  - Falls back to `CopyFromScreen` with a warning when `PrintWindow` returns a blank bitmap.
- **`skill/SKILL.md`** — Claude Code skill packaging, including trigger conditions, the
  confirmation protocol, and ten empirically discovered pitfalls.
- **`install.ps1`** — installs scripts and skill, verifies PowerShell syntax and UTF-8 BOM
  encoding on every installed file. Supports `-Uninstall`.
- **`agents/openai.yaml`** — manifest so OpenAI-compatible agent runtimes can register the skill,
  declaring `requires.vision: optional` since only Shot mode needs it.
- Bilingual documentation: `README.md` (Chinese) and `README_EN.md` (English).

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
