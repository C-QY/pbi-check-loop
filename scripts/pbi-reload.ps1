<#
.SYNOPSIS
    Restart Power BI Desktop so it re-reads a .pbip / TMDL changed on disk,
    and dismiss the sign-in dialog that appears on launch.

.DESCRIPTION
    Terminates the process (no save, no dialog), cleans up the orphaned msmdsrv,
    then reopens the same .pbip with the SAME edition of PBIDesktop.exe.

    WARNING: every unsaved change in Desktop is discarded. That is the point of
      this tool: the TMDL on disk is newer, Desktop holds a stale model in memory,
      and saving would overwrite the disk.

.PARAMETER Path
    Path to the .pbip. Required on first run, remembered afterwards.

.PARAMETER ListOnly
    Report current state only. Changes nothing.

.PARAMETER NoDismiss
    Do not auto-dismiss the sign-in dialog.

.EXAMPLE
    .\pbi-reload.ps1 -Path "D:
epo\my-project.pbip"
    .\pbi-reload.ps1
    .\pbi-reload.ps1 -ListOnly
#>
[CmdletBinding()]
param(
    [string]$Path,
    [int]$Id,
    [switch]$ListOnly,
    [switch]$NoDismiss,
    [switch]$Yes,               # Asserts 'no unsaved changes in Desktop'. Without it the script only warns
    [switch]$Wait,              # Block until the model has finished loading, then return
    [int]$WaitTimeout = 180,
    [int]$DismissTimeout = 120,
    [int]$WatchPid = 0,         # Internal: run as the detached watcher. Do not pass manually
    [string]$RestoreRect = '',  # Internal: "L,T,R,B" - put the window back after reopening
    [switch]$RestoreMax         # Internal: the window was maximized
)

$ErrorActionPreference = 'Stop'
$memFile = Join-Path $PSScriptRoot 'pbi-reload.last.json'
$logFile = Join-Path $PSScriptRoot 'pbi-reload.dialogs.log'

# Sign-in dialog titles to dismiss (prefix match).
#   These are WINDOW TITLES observed in the wild, not UI strings - do not translate them.
#   "Sign in"              - English Desktop, title "Sign in to Power BI" (verified twice)
#   "登录到 Power BI"      - Chinese Desktop (verified)
#   "输入你的电子邮件地址"  - a later step of the sign-in flow, unverified
#   Other locales: append the title you actually observe to this list.
$DialogTitles = @('登录到 Power BI', 'Sign in', '输入你的电子邮件地址')

Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public class PbiWin {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out WRECT r);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
}
public struct WRECT { public int Left, Top, Right, Bottom; }
'@ -ErrorAction SilentlyContinue

# Visible windows owned by the given process whose title matches one of $Titles
function Get-MatchingWindows([int]$TargetPid, [string[]]$Titles) {
    $hits = New-Object System.Collections.ArrayList
    $cb = [PbiWin+EnumWindowsProc]{
        param($h, $l)
        $wp = 0; [void][PbiWin]::GetWindowThreadProcessId($h, [ref]$wp)
        if ($wp -eq $TargetPid -and [PbiWin]::IsWindowVisible($h)) {
            $t = New-Object Text.StringBuilder 512; [void][PbiWin]::GetWindowText($h, $t, 512)
            $title = $t.ToString()
            foreach ($w in $Titles) {
                if ($title.StartsWith($w)) {
                    $c = New-Object Text.StringBuilder 256; [void][PbiWin]::GetClassName($h, $c, 256)
                    [void]$hits.Add([pscustomobject]@{ Handle = $h; Title = $title; Class = $c.ToString() })
                    break
                }
            }
        }
        return $true
    }
    [void][PbiWin]::EnumWindows($cb, [IntPtr]::Zero)
    return $hits
}

# Main window: title ends with "- Power BI Desktop". While loading it reads
# "Untitled - ..." (localized); once loaded it becomes the project name.
function Get-MainWindow([int]$TargetPid) {
    $hit = $null
    $cb = [PbiWin+EnumWindowsProc]{
        param($h, $l)
        $wp = 0; [void][PbiWin]::GetWindowThreadProcessId($h, [ref]$wp)
        if ($wp -eq $TargetPid -and [PbiWin]::IsWindowVisible($h)) {
            $t = New-Object Text.StringBuilder 512; [void][PbiWin]::GetWindowText($h, $t, 512)
            if ($t.ToString() -like '*- Power BI Desktop' -and -not $script:mwHit) {
                $script:mwHit = [pscustomobject]@{ Handle = $h; Title = $t.ToString() }
            }
        }
        return $true
    }
    $script:mwHit = $null
    [void][PbiWin]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:mwHit
}

# ============================================================
#  Watcher mode: runs as a detached process, waiting for the sign-in dialog.
#
#  Why match on the exact title instead of guessing "which one is modal":
#    the titles are values observed in the wild, so this never closes the
#    Options dialog the user opened themselves.
#
#  Why a detached process rather than Start-Job:
#    the dialog is delayed, so the watch lasts minutes; a background job dies
#    with the calling session.
#
#  It closes with PostMessage WM_CLOSE - the same as clicking the X (= Cancel),
#  so it can never hit OK by accident.
# ============================================================
if ($WatchPid -gt 0) {
    $deadline = (Get-Date).AddSeconds($DismissTimeout)
    $closed = 0
    # Exit once the work is done instead of idling until the timeout.
    # Measured: window restored at 3 s, dialog dismissed at 11 s, then 109 s of nothing.
    # Stay $GraceSec seconds past the dismissal in case the dialog pops a second time.
    $GraceSec  = 12
    $doneAfter = $null
    ("[{0}] watch start pid={1} timeout={2}s" -f (Get-Date -Format 'HH:mm:ss'), $WatchPid, $DismissTimeout) |
        Out-File $logFile -Append -Encoding utf8

    # Put the window back as soon as it appears, so the restart does not
    # bounce it onto the primary monitor and take over the external display
    $restored = -not $RestoreRect
    $rc = if ($RestoreRect) { $RestoreRect -split ',' | ForEach-Object { [int]$_ } } else { $null }
    # Only fight Desktop for the window state during this opening window; after that
    # let go, so the user dragging their own window is not yanked back
    $RestoreWindowSec = 45
    $restoreDeadline = (Get-Date).AddSeconds($RestoreWindowSec)
    $loggedOk = $false

    $processGone = $false
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $WatchPid -ErrorAction SilentlyContinue)) { $processGone = $true; break }

        # Desktop resets its own window state while loading, clobbering the restore,
        # so this must be apply-verify-retry rather than a single fire-and-forget call.
        if (-not $restored -and (Get-Date) -lt $restoreDeadline) {
            $main = Get-MainWindow -TargetPid $WatchPid
            if ($main) {
                $r = New-Object WRECT
                [void][PbiWin]::GetWindowRect($main.Handle, [ref]$r)

                # The test is always "final rect ~= original rect", never IsZoomed:
                # SW_MAXIMIZE sets the flag while the window is still at a temporary
                # 800x600, so checking the flag alone yields a false success.
                $tw = $rc[2] - $rc[0]; $th = $rc[3] - $rc[1]
                $cw = $r.Right - $r.Left; $ch = $r.Bottom - $r.Top
                $posOk  = ([Math]::Abs($r.Left - $rc[0]) -lt 20) -and ([Math]::Abs($r.Top - $rc[1]) -lt 20)
                $sizeOk = ([Math]::Abs($cw - $tw) -lt 60) -and ([Math]::Abs($ch - $th) -lt 60)

                # Do not stop on the first success: Desktop adjusts the window once more
                # after loading, so an early verdict captures a mid-flight snapshot
                # (measured 798x600 at 3 s; the settled value was 1508x900).
                # Keep watching until $restoreDeadline and re-apply if it drifts.
                if ($posOk -and $sizeOk) {
                    if (-not $loggedOk) {
                        $loggedOk = $true
                        ("[{0}] window settled L={1} T={2} {3}x{4}{5} (still watching to {6}s)" -f (Get-Date -Format 'HH:mm:ss'),
                            $r.Left, $r.Top, $cw, $ch, $(if ($RestoreMax) { ' maximized' }), $RestoreWindowSec) |
                            Out-File $logFile -Append -Encoding utf8
                    }
                }
                elseif ($RestoreMax) {
                    # Restore to a normal window, move it to the target monitor, then
                    # maximize. Without the RESTORE step, MoveWindow/MAXIMIZE silently
                    # do nothing on a window already flagged as maximized.
                    [void][PbiWin]::ShowWindow($main.Handle, 9)          # SW_RESTORE
                    Start-Sleep -Milliseconds 250
                    [void][PbiWin]::MoveWindow($main.Handle, $rc[0], $rc[1], 800, 600, $true)
                    Start-Sleep -Milliseconds 250
                    [void][PbiWin]::ShowWindow($main.Handle, 3)          # SW_MAXIMIZE
                    Start-Sleep -Milliseconds 400
                }
                else {
                    [void][PbiWin]::MoveWindow($main.Handle, $rc[0], $rc[1], $tw, $th, $true)
                    Start-Sleep -Milliseconds 300
                }

            }
        }
        elseif (-not $restored -and (Get-Date) -ge $restoreDeadline) {
            # Time is up - stop fighting for the window. Log the final state for review.
            $restored = $true
            $fin = Get-MainWindow -TargetPid $WatchPid
            if ($fin) {
                $fr = New-Object WRECT
                [void][PbiWin]::GetWindowRect($fin.Handle, [ref]$fr)
                # Same test as inside the loop: position AND size must both match.
                # Comparing width alone once reported a window parked off-screen as OK.
                $finOk = ([Math]::Abs($fr.Left - $rc[0]) -lt 20) -and ([Math]::Abs($fr.Top - $rc[1]) -lt 20) -and
                         ([Math]::Abs(($fr.Right-$fr.Left)-($rc[2]-$rc[0])) -lt 60) -and
                         ([Math]::Abs(($fr.Bottom-$fr.Top)-($rc[3]-$rc[1])) -lt 60)
                ("[{0}] restore done final L={1} T={2} {3}x{4} target {5}x{6} -> {7}" -f (Get-Date -Format 'HH:mm:ss'),
                    $fr.Left, $fr.Top, ($fr.Right-$fr.Left), ($fr.Bottom-$fr.Top),
                    ($rc[2]-$rc[0]), ($rc[3]-$rc[1]),
                    $(if ($finOk) { 'OK' } else { 'MISMATCH' })) |
                    Out-File $logFile -Append -Encoding utf8
            }
        }

        if (-not $NoDismiss) {
        foreach ($t in (Get-MatchingWindows -TargetPid $WatchPid -Titles $DialogTitles)) {
            [void][PbiWin]::PostMessage($t.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE
            $closed++
            ("[{0}] dismissed title='{1}' class='{2}'" -f (Get-Date -Format 'HH:mm:ss'), $t.Title, $t.Class) |
                Out-File $logFile -Append -Encoding utf8
            Start-Sleep -Milliseconds 600
        }
        }

        # Done when the window has settled AND a dialog was dismissed (or we ignore
        # dialogs): wait $GraceSec more seconds, then stop holding a background process.
        # If no dialog ever appears this falls back to the $DismissTimeout safety net.
        $jobDone = $restored -and ($closed -gt 0 -or $NoDismiss)
        if ($jobDone -and -not $doneAfter) { $doneAfter = (Get-Date).AddSeconds($GraceSec) }
        if ($doneAfter -and (Get-Date) -ge $doneAfter) { break }

        Start-Sleep -Milliseconds 400
    }

    # Three distinct exits: work done / target process gone (user closed Desktop) / timeout
    $how = if ($doneAfter) { 'work done' } elseif ($processGone) { 'target process gone' } else { 'timeout' }
    ("[{0}] watch end ({1}), dismissed {2}" -f (Get-Date -Format 'HH:mm:ss'), $how, $closed) |
        Out-File $logFile -Append -Encoding utf8
    exit
}

# ============================================================
#  Normal mode
# ============================================================
function Write-Step($msg) { Write-Host "  $msg" }

function Start-Watcher([int]$ProcId, [string]$Rect, [bool]$WasMax) {
    if ($NoDismiss -and -not $Rect) { return }
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-WatchPid', $ProcId,
        '-DismissTimeout', $DismissTimeout
    )
    if ($NoDismiss) { $args += '-NoDismiss' }
    if ($Rect)      { $args += @('-RestoreRect', $Rect) }
    if ($WasMax)    { $args += '-RestoreMax' }
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $args | Out-Null
    $what = @()
    if (-not $NoDismiss) { $what += 'dismiss sign-in' }
    if ($Rect)           { $what += 'restore window' }
    Write-Step ("Watcher started ({0}, {1}s)" -f ($what -join ' + '), $DismissTimeout)
}

# Record where the window is so it can be put back; otherwise it bounces to the
# primary monitor and takes over the external display
function Get-Placement([IntPtr]$Hwnd) {
    if ($Hwnd -eq [IntPtr]::Zero) { return $null }
    $r = New-Object WRECT
    if (-not [PbiWin]::GetWindowRect($Hwnd, [ref]$r)) { return $null }
    return [pscustomobject]@{
        Rect  = "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
        IsMax = [PbiWin]::IsZoomed($Hwnd)
    }
}

# Is the recorded rectangle trustworthy? A degenerate size, or one outside every
# screen, means the window was in a strange state (minimized reads -32000; a window
# dragged mostly off-screen once measured -21281,-20853 107x19). Replaying such a
# rectangle only hides the new window off-screen and fights the user for the whole
# restore window.
function Test-RectSane([string]$Rect) {
    $p = $Rect -split ',' | ForEach-Object { [int]$_ }
    if (($p[2] - $p[0]) -lt 200 -or ($p[3] - $p[1]) -lt 150) { return $false }
    Add-Type -AssemblyName System.Windows.Forms
    foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $b = $s.Bounds
        if ($p[0] -lt $b.Right -and $p[2] -gt $b.Left -and $p[1] -lt $b.Bottom -and $p[3] -gt $b.Top) { return $true }
    }
    return $false
}

# Block until the model has finished loading, so a caller does not have to poll.
#
# "Loaded" is detected by the window title becoming the project name. That choice is
# deliberate. The obvious alternative - wait until the title is no longer
# "Untitled - Power BI Desktop" - is broken: that string is localized (zh-CN shows
# a different word entirely), so a negative match against the English one reports
# "ready" the instant any window appears, and the caller then queries a half-loaded
# model. Matching the project name has no such failure mode: only a finished load
# ever produces it, in any language.
function Wait-Loaded([int]$ProcId, [string]$ProjectPath, [int]$TimeoutSec) {
    $stem     = [WildcardPattern]::Escape([IO.Path]::GetFileNameWithoutExtension($ProjectPath))
    $pattern  = "$stem - *"
    $started  = Get-Date
    $deadline = $started.AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        if (-not $p) { return [pscustomobject]@{ State = 'gone'; Seconds = $elapsed } }
        if ($p.MainWindowTitle -like $pattern) {
            return [pscustomobject]@{ State = 'ready'; Seconds = $elapsed }
        }
        Start-Sleep -Milliseconds 800
    }
    return [pscustomobject]@{ State = 'timeout'; Seconds = $TimeoutSec }
}

function Invoke-WaitReport([int]$ProcId, [string]$ProjectPath, [int]$TimeoutSec) {
    Write-Host "`nWaiting for the model to finish loading (timeout ${TimeoutSec}s)..."
    $r = Wait-Loaded -ProcId $ProcId -ProjectPath $ProjectPath -TimeoutSec $TimeoutSec
    switch ($r.State) {
        'ready' {
            Write-Host "Ready after $($r.Seconds)s - the title settled to the project name." -ForegroundColor Green
        }
        'gone' {
            Write-Host "Desktop exited after $($r.Seconds)s without finishing the load." -ForegroundColor Red
        }
        'timeout' {
            Write-Host "Still loading after ${TimeoutSec}s. A dialog may be blocking it - read it with:" -ForegroundColor Yellow
            Write-Host "  pbi-shot.ps1 -Text" -ForegroundColor Yellow
        }
    }
}

# ---------- 1. Resolve the target .pbip ----------
if (-not $Path -and (Test-Path $memFile)) {
    try {
        $Path = (Get-Content $memFile -Raw -Encoding UTF8 | ConvertFrom-Json).Path
        Write-Step "Using remembered path: $Path"
    } catch { }
}

# ---------- 2. Find the running Desktop ----------
$procs = @(Get-Process -Name 'PBIDesktop' -ErrorAction SilentlyContinue)

if ($procs.Count -eq 0) {
    Write-Host "Power BI Desktop is not running."
    if ($ListOnly) { return }
    if (-not $Path) { throw "No path available. Pass -Path <file.pbip>." }
    if (-not (Test-Path $Path)) { throw "Path does not exist: $Path" }
    Write-Step "Opening it..."
    $exe = 'C:\Program Files\Microsoft Power BI Desktop\bin\PBIDesktop.exe'
    $np = Start-Process -FilePath $exe -ArgumentList "`"$Path`"" -PassThru
    @{ Path = $Path } | ConvertTo-Json | Out-File $memFile -Encoding utf8
    Start-Watcher -ProcId $np.Id -Rect '' -WasMax $false
    Write-Host "Started (regular edition)."
    if ($Wait) { Invoke-WaitReport -ProcId $np.Id -ProjectPath $Path -TimeoutSec $WaitTimeout }
    return
}

if ($procs.Count -gt 1 -and -not $Id) {
    # Several agents on one machine: -Path is the identity. Match the project name
    # against window titles; a unique hit means -Id is not needed.
    if ($Path) {
        $stem = [WildcardPattern]::Escape([IO.Path]::GetFileNameWithoutExtension($Path))
        $byTitle = @($procs | Where-Object { $_.MainWindowTitle -like "$stem - *" })
        if ($byTitle.Count -eq 1) { $procs = $byTitle }
    }
    if ($procs.Count -gt 1) {
        Write-Host "Several Desktop instances found. Pass -Id to pick one:`n"
        foreach ($p in $procs) {
            $ver = if ($p.Path -like '*Desktop RS*') { 'Report Server' } else { 'regular' }
            Write-Host ("  -Id {0}   [{1}]  {2}" -f $p.Id, $ver, $p.MainWindowTitle)
        }
        return
    }
}

$target = if ($Id) { $procs | Where-Object { $_.Id -eq $Id } } else { $procs[0] }
if (-not $target) { throw "No Desktop process with PID $Id." }

# One instance, but it does not match -Path: most likely another agent's or session's
# Desktop, so say so before touching it
if ($Path -and $target.MainWindowTitle) {
    $stem = [WildcardPattern]::Escape([IO.Path]::GetFileNameWithoutExtension($Path))
    if ($target.MainWindowTitle -notlike "$stem - *") {
        Write-Host "WARNING: the running instance is '$($target.MainWindowTitle)', which does not match -Path. It will be terminated and $(Split-Path $Path -Leaf) opened instead." -ForegroundColor Yellow
    }
}

$exePath = $target.Path
$edition = if ($exePath -like '*Desktop RS*') { 'Report Server' } else { 'regular' }

# ---------- 3. Report state ----------
Write-Host "`nCurrent instance"
Write-Step "PID       : $($target.Id)"
Write-Step "Edition   : $edition"
Write-Step "Title     : $($target.MainWindowTitle)"
Write-Step "Started   : $($target.StartTime)"

# Is the disk newer than Desktop? This is the direct basis for 'should we reload'.
# Never skip this silently: an absent verdict reads exactly like "nothing changed",
# and a caller would then keep working against a stale Desktop.
if (-not $Path) {
    Write-Host "`nDisk state UNKNOWN - no project path to compare against" -ForegroundColor Yellow
    Write-Step "Pass -Path <file.pbip> to find out whether a reload is needed."
}
elseif (-not (Test-Path $Path)) {
    Write-Host "`nDisk state UNKNOWN - the remembered path no longer exists" -ForegroundColor Yellow
    Write-Step $Path
    Write-Step "Pass -Path <file.pbip> to find out whether a reload is needed."
}
else {
    $projDir = Split-Path $Path -Parent
    $newer = @(Get-ChildItem $projDir -Recurse -File -Include *.tmdl,*.json,*.pbir,*.pbism -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -gt $target.StartTime })
    if ($newer.Count -gt 0) {
        Write-Host "`nDisk changed since Desktop opened - reload needed" -ForegroundColor Yellow
        $newer | Sort-Object LastWriteTime -Descending | Select-Object -First 6 | ForEach-Object {
            Write-Step ("{0:HH:mm:ss}  {1}" -f $_.LastWriteTime, $_.Name)
        }
        if ($newer.Count -gt 6) { Write-Step "... $($newer.Count) files in total" }
    } else {
        Write-Host "`nNo disk changes - Desktop is up to date, no reload needed" -ForegroundColor DarkGray
    }
}

$msmd = @(Get-WmiObject Win32_Process -Filter "Name='msmdsrv.exe'" -ErrorAction SilentlyContinue |
          Where-Object { $_.ParentProcessId -eq $target.Id })
if ($msmd.Count -gt 0) { Write-Step "msmdsrv   : $(($msmd | ForEach-Object { $_.ProcessId }) -join ', ')" }

if ($ListOnly) { Write-Host "`n(-ListOnly - nothing was changed)"; return }

if (-not $Path) { throw "`nNo path available, cannot reopen. Pass -Path <file.pbip>." }
if (-not (Test-Path $Path)) { throw "`nPath does not exist: $Path" }

# ---------- 3.5 Confirmation ----------
#
# Why this cannot be skipped: two opposite situations exist and the tool cannot
# tell them apart from outside.
#   1. TMDL on disk was edited, Desktop's memory is stale -> never save (it would
#      overwrite the disk changes)
#   2. The user just edited in Desktop without saving -> must save first (otherwise
#      terminating discards it)
# Desktop's title bar carries no modified marker and window enumeration exposes no
# dirty state - only a human knows.
#
# No GUI dialog, no blocking Read-Host: without -Yes the script simply stops and
# says so. Confirmation belongs in the conversation, not in the script.
if (-not $Yes) {
    Write-Host "`nWARNING: this will terminate Power BI Desktop. Every unsaved change in its memory is lost." -ForegroundColor Yellow
    Write-Host "   $(Split-Path $Path -Leaf)"
    Write-Host ""
    Write-Host "   Once you have confirmed there are no unsaved changes, re-run with -Yes:" -ForegroundColor Yellow
    Write-Host "     & `"$PSCommandPath`" -Yes"
    Write-Host ""
    Write-Host "Stopped. Nothing was changed."
    return
}

# ---------- 4. Terminate ----------
Write-Host "`nRestarting"

# Record where the window is and whether it is maximized, to restore it after reopening
$placement = Get-Placement -Hwnd $target.MainWindowHandle
if ($placement -and -not (Test-RectSane $placement.Rect)) {
    Write-Step "Recorded window rect looks wrong ($($placement.Rect)); skipping restore, reopening at the default position"
    $placement = $null
}
if ($placement) { Write-Step "Window rect recorded: $($placement.Rect)$(if ($placement.IsMax) { ' (maximized)' })" }

Write-Step "Terminating Desktop (no save)..."
Stop-Process -Id $target.Id -Force

$deadline = (Get-Date).AddSeconds(20)
while ((Get-Process -Id $target.Id -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
}

foreach ($m in $msmd) {
    if (Get-Process -Id $m.ProcessId -ErrorAction SilentlyContinue) {
        Write-Step "Cleaning up orphaned msmdsrv $($m.ProcessId)..."
        Stop-Process -Id $m.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 5. Reopen ----------
Start-Sleep -Milliseconds 500
Write-Step "Reopening [$edition] $(Split-Path $Path -Leaf) ..."
$newProc = Start-Process -FilePath $exePath -ArgumentList "`"$Path`"" -PassThru

@{ Path = $Path } | ConvertTo-Json | Out-File $memFile -Encoding utf8

Start-Watcher -ProcId $newProc.Id `
    -Rect   $(if ($placement) { $placement.Rect }  else { '' }) `
    -WasMax $(if ($placement) { [bool]$placement.IsMax } else { $false })

Write-Host "`nDone. Desktop is loading - a large model takes a while."
Write-Host "Watcher log: $logFile"

if ($Wait) { Invoke-WaitReport -ProcId $newProc.Id -ProjectPath $Path -TimeoutSec $WaitTimeout }
