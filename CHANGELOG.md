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
- Bilingual documentation: `README.md` (English) and `README.zh-CN.md` (Chinese).

### Known limitations

- The agent cannot interact with the report — no scrolling, clicking, or page switching.
- Model load time is unchanged; it remains the dominant cost per iteration.
- Each restart leaves a stale folder under `AnalysisServicesWorkspaces\`. Not cleaned
  automatically, since removing one still in use would be destructive.
- The root cause of the recurring sign-in dialog was not identified. Sensitivity-label,
  Translytical task flow, and Copilot preview features were all ruled out. Dismissal works
  regardless of cause, since it matches on window title.

[1.0.0]: https://github.com/
