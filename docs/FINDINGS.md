# Findings

## Design constraints

🔴 **No GUI prompts inside the scripts** (`Popup`, `MessageBox`, `Read-Host`). Confirmation
belongs in the conversation. A popup version was built and rejected twice, then removed.
Do not reintroduce it.

🔴 **Never call `SetForegroundWindow`.** The user may be working on another monitor; stealing
focus interrupts them. `PrintWindow` does not need it.

🔴 **Shared state on multi-agent machines.** `pbi-reload.last.json` is one file per machine —
an agent passing `-Path` for its own project overwrites what another agent remembered. Callers
must pass `-Path`; the instance is then identified by matching the project name against window
titles (implemented 2026-07-30), with `-Id` as fallback. Several agents on ONE report is a
file-layer conflict (two writers on the same TMDL/PBIR) that this tool cannot serialize —
don't do it.


Notes for anyone modifying `scripts/*.ps1`. Not needed to *call* the tools — kept out of
SKILL.md so it does not load into an agent's context on every invocation.

## Empirical findings

Read before modifying the scripts. Each cost a debugging cycle; several describe bugs already
fixed — do not reintroduce them.

1. **The sign-in dialog appears on an ~11 second delay**, not at launch. Logic that exits once
   "the main window has been responsive for 3 seconds" never catches it.
2. **Its window title is exactly `登录到 Power BI`** (Chinese locale) / **`Sign in to Power BI`**
   (English locale — empirically captured and auto-dismissed twice on 2026-07-30; matched by the
   `Sign in` prefix), class `WindowsForms10.Window.20008.app.*`.
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
11. **The recorded window rect can be garbage.** Observed: `-21281,-20853` at 107×19 (window
    tucked off a screen edge; a minimized window reports `-32000,-32000`). Replaying that rect
    parks the reopened window off-screen, and the restore loop keeps dragging it back there —
    fighting the user's clicks — for the whole restore window. Sanity-check at record time
    (minimum size + must intersect some screen) and skip restoration on failure. The
    end-of-restore verdict must compare position *and* size: a width-only check once printed
    `OK` for a window sitting off-screen.
12. 🔴 **Never detect "loading finished" by a negative match on `Untitled`.** The loading title is
    localized — a zh-CN Desktop shows a different word entirely — so `title -notlike "*Untitled*"`
    passes the instant any window appears, and the caller queries a model that is still loading.
    Observed 2026-08-04: a hand-written poll reported ready mid-load; only a follow-up `-ListOnly`
    revealed the truth. Match the **project name** (`"$stem - *"`) instead — only a finished load
    can produce it, in any language. This is what `-Wait` does.
13. 🔴 **Reloading after a partition's M expression changed leaves that table empty.** The cached
    data is invalidated, so the table comes back with 0 rows, and every table whose M references
    it goes empty too (observed: a fact table and the date table built from it, both 0 rows;
    pages bound to them rendered blank). This is indistinguishable from a broken edit unless you
    know to expect it — it was diagnosed as one on 2026-08-04 before the cause was found. A
    manual user Refresh is required, and the tool must not attempt it: refreshing re-queries the
    source, takes minutes, and may hit production.
14. 🔴 **The window title settles before the model engine is up.** Once it reads the project
    name the load looks finished, but `msmdsrv` may still be starting — a DAX query issued at
    that instant returns "table not found", which is indistinguishable from an edit that broke
    the model. Observed twice in one session (a failed query, and `pbi-shot` finding no window
    right after a `Ready`). Wait for the instance's `msmdsrv` child as well; that is what
    `-Wait` now does.
15. 🔴 **Never locate the AS port via `msmdsrv.port.txt`.** With two Desktops open, the newest
    port file belongs to whichever project loaded last, so a caller reading it can connect to
    the *other* project's model. Querying a table that exists only in the project being edited
    then fails with "table not found" — and the obvious reading of that error ("my edit broke
    something") is wrong, which is worse than not connecting at all. Resolve
    parent PID → child `msmdsrv` (`Win32_Process.ParentProcessId`) → `netstat -ano` LISTENING
    port instead. `-Wait` and `-ListOnly` print it.
16. **A minimized window is not why a capture fails.** `pbi-shot` already restores minimized
    windows with `SW_SHOWNOACTIVATE`. When it reports no window, the cause is almost always a
    different instance, or a reload whose window has not been rebuilt yet — so the error now
    lists every running Desktop with its title instead of blaming "still loading".
17. **`Select-String` cannot read UTF-8 files containing CJK text under PowerShell 5.1** — it
    decodes as the ANSI codepage and silently matches nothing, which reads exactly like "the
    edit did not land". Verify such files with `[System.IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)`
    instead. Relevant when checking the scripts' own Chinese dialog titles.

## Unresolved

The root cause of the sign-in dialog appearing on every launch was **not identified**.
Ruled out: sensitivity-label preview feature, Translytical task flow, all Copilot preview
features. `FeatureSwitches.xml` stores GUIDs with no name mapping; trace logs stay empty unless
the registry value `TracingEnabled` is set to 1 first (not attempted).

**Usage is unaffected** — dismissal matches on window title and is indifferent to cause.
