<#
.SYNOPSIS
    Capture the Power BI Desktop window to a PNG so an agent can see what rendered.

.DESCRIPTION
    The report layer renders to pixels: the .pbip sources say nothing about how a
    visual actually looks. This captures the Desktop window to a PNG that an agent
    can open with the Read tool, closing the edit -> look -> edit loop for the
    report layer too.

    Prefers PrintWindow (captures non-foreground and partially occluded windows);
    falls back to CopyFromScreen when the result comes back near-blank, which does
    require the window to be visible and unobstructed.

    When a dialog is open its text is printed alongside the capture. Reading an
    error as text is far more reliable than reading it off pixels, and detection
    costs 20-130 ms against a ~1100 ms capture. Nothing is printed when no dialog
    is up.

.PARAMETER Out
    Output PNG path. Defaults to %TEMP%\pbi-shot.png

.PARAMETER Id
    PBIDesktop process id, for when several instances run.

.PARAMETER FullScreen
    Capture the whole virtual screen instead of just the Desktop window.
    WARNING: this records everything on screen. Privacy-sensitive; avoid by default.

.PARAMETER Text
    Read the window as plain text through UI Automation instead of capturing pixels.
    Intended for models WITHOUT vision, which cannot see an image but can read text.
    Reachable: dialog text, the field/table tree, and the report canvas itself -
        visual titles, matrix column headers and cell values are all exposed
        through the embedded WebView's accessibility tree.
    Not reachable: layout, colour, spacing. It tells you what the report SAYS,
        never how it LOOKS.
    WARNING: the output contains real business data. Treat it exactly like a
        capture: never publish it, never commit it.

.EXAMPLE
    .\pbi-shot.ps1
    .\pbi-shot.ps1 -Out D:	mp.png
    .\pbi-shot.ps1 -Text
#>
[CmdletBinding()]
param(
    [string]$Out = (Join-Path $env:TEMP 'pbi-shot.png'),
    [int]$Id,
    [switch]$FullScreen,
    [switch]$Text
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public struct RECT { public int Left, Top, Right, Bottom; }
public class Shot {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
}
'@ -ErrorAction SilentlyContinue

function Get-TargetPid {
    $procs = @(Get-Process -Name 'PBIDesktop' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { throw 'Power BI Desktop is not running.' }
    if ($Id) { $procs = @($procs | Where-Object { $_.Id -eq $Id }) }
    if ($procs.Count -eq 0) { throw "No process with PID $Id." }
    return $procs[0].Id
}

# ============================================================
#  UI Automation: read the window as text
# ============================================================
function Get-TopWindows([int]$ProcId) {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction SilentlyContinue
    $rootEl = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcId)
    $tops = $rootEl.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)

    $main = $null; $dialogs = @()
    foreach ($w in $tops) {
        if ($w.Current.Name -like '*Power BI Desktop') { $main = $w } else { $dialogs += $w }
    }
    return [pscustomobject]@{ Main = $main; Dialogs = $dialogs }
}

# When $Only is non-empty, keep only these ControlTypes. With no dialog up this
# filters out ribbon buttons, groups and tabs - static noise that is identical every
# time and would waste dozens of lines of context.
function Write-UiaTree($el, [int]$Cap, $Only) {
    $kids = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                        [System.Windows.Automation.Condition]::TrueCondition)
    $seen = @{}; $n = 0
    foreach ($e in $kids) {
        $nm = $e.Current.Name
        if (-not $nm -or $nm.Trim() -eq '') { continue }
        if ($seen.ContainsKey($nm)) { continue }
        $seen[$nm] = $true
        $ct = $e.Current.ControlType.ProgrammaticName -replace 'ControlType\.', ''
        if ($Only -and ($Only -notcontains $ct)) { continue }
        if ($nm.Length -gt 200) { $nm = $nm.Substring(0, 200) + '…' }
        Write-Output ("    [{0,-11}] {1}" -f $ct, $nm)
        $n++
        if ($n -ge $Cap) { Write-Output "    ...truncated (cap $Cap reached)"; break }
    }
    if ($n -eq 0) { Write-Output '    (no readable text)' }
}

# Print the text of any open dialog. Returns whether one was found.
function Show-DialogText($wins) {
    if ($wins.Dialogs.Count -eq 0) { return $false }
    Write-Output ""
    Write-Output ("WARNING: " + $wins.Dialogs.Count + " dialog(s) detected. Text follows:")
    foreach ($d in $wins.Dialogs) {
        $t = $d.Current.Name; if (-not $t) { $t = '(untitled)' }
        Write-Output ""
        Write-Output ("=== Dialog: " + $t + " ===")
        Write-UiaTree $d 120 $null
    }
    return $true
}

# ============================================================
#  -Text: plain-text mode
# ============================================================
if ($Text) {
    $tp = Get-TargetPid
    $wins = Get-TopWindows $tp
    Write-Output ("PID         : " + $tp)
    Write-Output ("Main window : " + $(if ($wins.Main) { $wins.Main.Current.Name } else { '(not found - may still be loading)' }))

    if (-not (Show-DialogText $wins)) {
        if ($wins.Main) {
            Write-Output ""
            Write-Output "No dialog. Listing content elements only (ribbon buttons and other static noise filtered out):"
            Write-Output ""
            Write-UiaTree $wins.Main 40 @('TreeItem', 'Edit', 'Document', 'DataItem', 'ListItem')
        }
    }
    Write-Output ""
    Write-Output "Note: to see how the report LOOKS, capture an image (drop -Text) - that requires a vision-capable model."
    return
}

# ============================================================
#  Capture
# ============================================================
function Save-Png($bmp, $path) {
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
}

# Is the bitmap nearly all one colour? Used to tell whether PrintWindow actually drew
function Test-Blank($bmp) {
    $step = [Math]::Max(1, [int]($bmp.Width / 40))
    $seen = @{}
    for ($x = 0; $x -lt $bmp.Width; $x += $step) {
        for ($y = 0; $y -lt $bmp.Height; $y += $step) {
            $c = $bmp.GetPixel($x, $y)
            $seen["$($c.R),$($c.G),$($c.B)"] = $true
            if ($seen.Count -gt 8) { return $false }
        }
    }
    return $true
}

# ---------- Full screen ----------
if ($FullScreen) {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
    $g.Dispose()
    Save-Png $bmp $Out
    Write-Output ("full screen {0}x{1} -> {2}" -f $bmp.Width, $bmp.Height, $Out)
    $bmp.Dispose()
    return
}

# ---------- Locate the main window ----------
$targetPid = [uint32](Get-TargetPid)

$found = New-Object System.Collections.ArrayList
$cb = [Shot+EnumWindowsProc]{
    param($h, $l)
    $wp = 0; [void][Shot]::GetWindowThreadProcessId($h, [ref]$wp)
    if ($wp -eq $targetPid -and [Shot]::IsWindowVisible($h)) {
        $t = New-Object Text.StringBuilder 512; [void][Shot]::GetWindowText($h, $t, 512)
        if ($t.ToString() -like '*Power BI Desktop') {
            [void]$found.Add([pscustomobject]@{ Handle = $h; Title = $t.ToString() })
        }
    }
    return $true
}
[void][Shot]::EnumWindows($cb, [IntPtr]::Zero)
if ($found.Count -eq 0) {
    # Say which PID was searched and what else is running. The old message ("main window
    # not found, it may still be loading") sends the caller to wait when the real cause
    # is often a different instance, or a reload whose window has not been rebuilt yet.
    $all = @(Get-Process -Name 'PBIDesktop' -ErrorAction SilentlyContinue |
             ForEach-Object { "    PID $($_.Id)  '$($_.MainWindowTitle)'" })
    $detail = if ($all.Count) {
        "`n  Desktop processes running right now:`n" + ($all -join "`n")
    } else {
        "`n  No PBIDesktop process is running at all."
    }
    throw ("No capturable window for PID $targetPid." + $detail +
           "`n  If a reload just happened, wait for `"pbi-reload.ps1 -Wait`" to report Ready -" +
           "`n  it now also waits for the model engine, not just the window title.")
}

$win = $found[0]
$hwnd = $win.Handle

# Never call SetForegroundWindow: the user may be working on another monitor, and
# stealing focus yanks Desktop to the front and interrupts them. PrintWindow already
# handles non-foreground and even occluded windows. Only a minimized window is
# restored, because it has no usable size to capture.
if ([Shot]::IsIconic($hwnd)) {
    [void][Shot]::ShowWindow($hwnd, 4)   # SW_SHOWNOACTIVATE: restore without activating or stealing focus
    Start-Sleep -Milliseconds 700
}

$r = New-Object RECT
[void][Shot]::GetWindowRect($hwnd, [ref]$r)
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
if ($w -le 0 -or $h -le 0) { throw "Bad window size: ${w}x${h}" }

# ---------- Capture: PrintWindow first, fall back to CopyFromScreen if blank ----------
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [Shot]::PrintWindow($hwnd, $hdc, 2)   # 2 = PW_RENDERFULLCONTENT
$g.ReleaseHdc($hdc)
$g.Dispose()

$method = 'PrintWindow'
if (-not $ok -or (Test-Blank $bmp)) {
    $bmp.Dispose()
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
    $g.Dispose()
    $method = 'CopyFromScreen (fallback)'
    Write-Warning "PrintWindow failed; fell back to CopyFromScreen. That captures raw screen pixels, so anything covering the window appears in the image. Treat an odd-looking capture accordingly."
}

Save-Png $bmp $Out
Write-Output ("{0}  {1}x{2}  method={3}" -f $win.Title, $w, $h, $method)
Write-Output $Out
$bmp.Dispose()

# ---------- Report any dialog text alongside the capture ----------
# Reading an error as text beats recognizing it in an image, and detection costs
# 20-130 ms against a ~1100 ms capture. Nothing is printed when no dialog is up.
try { [void](Show-DialogText (Get-TopWindows $targetPid)) } catch { }
