# Findings

## Design constraints

🔴 **No GUI prompts inside the scripts** (`Popup`, `MessageBox`, `Read-Host`). Confirmation
belongs in the conversation. A popup version was built and rejected twice, then removed.
Do not reintroduce it.

🔴 **Never call `SetForegroundWindow`.** The user may be working on another monitor; stealing
focus interrupts them. `PrintWindow` does not need it.


Notes for anyone modifying `scripts/*.ps1`. Not needed to *call* the tools — kept out of
SKILL.md so it does not load into an agent's context on every invocation.

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
