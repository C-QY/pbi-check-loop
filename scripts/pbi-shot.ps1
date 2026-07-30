<#
.SYNOPSIS
    截取 Power BI Desktop 窗口为 PNG，供 Claude 直接查看渲染结果。

.DESCRIPTION
    报表层（visual 渲染）在 pbip 源文件上看不出效果，只能看实际画面。
    这个脚本把 Desktop 窗口抓成 PNG，Claude 用 Read 工具能直接看图，
    从而对报表层也形成「改 → 看 → 再改」的闭环。

    优先用 PrintWindow（可抓被部分遮挡的窗口），拿到空白图则退回
    CopyFromScreen（抓屏幕像素，要求窗口可见不被挡）。

.PARAMETER Out
    输出 PNG 路径。默认 %TEMP%\pbi-shot.png

.PARAMETER Id
    指定 PBIDesktop 进程 PID（多实例时用）。

.PARAMETER FullScreen
    截整个虚拟屏幕，而不是只截 Desktop 窗口。

.EXAMPLE
    .\pbi-shot.ps1
    .\pbi-shot.ps1 -Out D:\tmp\a.png
    .\pbi-shot.ps1 -FullScreen
#>
[CmdletBinding()]
param(
    [string]$Out = (Join-Path $env:TEMP 'pbi-shot.png'),
    [int]$Id,
    [switch]$FullScreen
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

function Save-Png($bmp, $path) {
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
}

# 图是不是几乎全白/全黑 —— 用来判断 PrintWindow 有没有真的画上东西
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

# ---------- 整屏 ----------
if ($FullScreen) {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
    $g.Dispose()
    Save-Png $bmp $Out
    Write-Output ("整屏 {0}x{1} -> {2}" -f $bmp.Width, $bmp.Height, $Out)
    $bmp.Dispose()
    return
}

# ---------- 找 Desktop 主窗口 ----------
$procs = @(Get-Process -Name 'PBIDesktop' -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) { throw "Power BI Desktop 未运行。" }
if ($Id) { $procs = @($procs | Where-Object { $_.Id -eq $Id }) }
if ($procs.Count -eq 0) { throw "找不到 PID $Id。" }
$targetPid = [uint32]$procs[0].Id

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
if ($found.Count -eq 0) { throw "找不到 PBIDesktop 主窗口（可能还在加载）。" }

$win = $found[0]
$hwnd = $win.Handle

# 🔴 绝不主动置前（SetForegroundWindow）—— 用户可能正在外接屏上干别的事，
#    抢焦点会把 Desktop 拽到前台打断他。PrintWindow 本来就能抓非前台、
#    甚至被遮挡的窗口，2026-07-30 实测一次成功、没走回退。
#    只有最小化时才恢复（最小化状态下窗口没有有效尺寸，抓不了）。
if ([Shot]::IsIconic($hwnd)) {
    [void][Shot]::ShowWindow($hwnd, 4)   # SW_SHOWNOACTIVATE：还原但不激活、不抢焦点
    Start-Sleep -Milliseconds 700
}

$r = New-Object RECT
[void][Shot]::GetWindowRect($hwnd, [ref]$r)
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
if ($w -le 0 -or $h -le 0) { throw "窗口尺寸异常: ${w}x${h}" }

# ---------- 抓图：先 PrintWindow，空白则退回 CopyFromScreen ----------
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
    $method = 'CopyFromScreen(回退)'
    Write-Warning "PrintWindow 失败，已回退 CopyFromScreen —— 它抓的是屏幕像素，若窗口被别的东西挡住，图里就是那个东西。看到不对劲请以此为准。"
}

Save-Png $bmp $Out
Write-Output ("{0}  {1}x{2}  方式={3}" -f $win.Title, $w, $h, $method)
Write-Output $Out
$bmp.Dispose()
