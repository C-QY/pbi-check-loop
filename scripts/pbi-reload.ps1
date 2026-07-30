<#
.SYNOPSIS
    重启 Power BI Desktop，让它重新读取磁盘上已被修改的 pbip / TMDL，
    并自动关掉启动时弹出的登录框。

.DESCRIPTION
    直接结束进程（= 不保存、不弹对话框），清理残留的 msmdsrv，
    再用「原来那个版本」的 PBIDesktop.exe 重新打开同一个 .pbip。

    ⚠ 会丢弃 Desktop 里所有未保存的改动。这正是本工具的目的：
      磁盘上有改过的 TMDL，Desktop 内存里是旧模型，保存反而会覆盖。

.PARAMETER Path
    .pbip 文件路径。首次需指定，之后会记住；再次运行可省略。

.PARAMETER ListOnly
    只报告当前状态，不做任何操作。

.PARAMETER NoDismiss
    不自动关闭登录弹窗。

.EXAMPLE
    .\pbi-reload.ps1 -Path "D:\repo\我的项目.pbip"
    .\pbi-reload.ps1
    .\pbi-reload.ps1 -ListOnly
#>
[CmdletBinding()]
param(
    [string]$Path,
    [int]$Id,
    [switch]$ListOnly,
    [switch]$NoDismiss,
    [switch]$Yes,               # 确认「Desktop 里没有未保存的改动」。不给就只提示、不动手
    [int]$DismissTimeout = 120,
    [int]$WatchPid = 0,         # 内部用：以「守候模式」运行，勿手动指定
    [string]$RestoreRect = '',  # 内部用："L,T,R,B"，重开后把窗口放回原位
    [switch]$RestoreMax         # 内部用：原来是最大化的
)

$ErrorActionPreference = 'Stop'
$memFile = Join-Path $PSScriptRoot 'pbi-reload.last.json'
$logFile = Join-Path $PSScriptRoot 'pbi-reload.dialogs.log'

# 要自动关掉的弹窗标题（前缀匹配）
#   "登录到 Power BI"      —— 中文版登录框，2026-07-30 实测抓到
#   "Sign in"              —— 英文版登录框 "Sign in to Power BI"，2026-07-30 英文版实测两次抓到
#   "输入你的电子邮件地址"  —— 登录流程的另一步，未实测，先放着
#   其他语言的 Desktop：把实测到的窗口标题加进这个列表即可
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

# 找出属于指定进程、且标题命中 $Titles 的可见窗口
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

# 主窗口：标题以 "- Power BI Desktop" 结尾（加载中是「无标题 - 」，加载完变项目名）
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
#  守候模式：作为独立进程运行，盯着登录弹窗并关掉
#
#  为什么按标题精确匹配，而不是猜「哪个是模态框」：
#    标题是实测抓到的确定值，绝不会误伤你自己打开的「选项」等对话框。
#
#  为什么要独立进程而不是 Start-Job：
#    弹窗是延迟出现的，得守两分钟；后台 job 会随着调用方会话结束而死。
#
#  关法是 PostMessage WM_CLOSE，等同于点右上角 ×（＝取消），不会误触确定。
# ============================================================
if ($WatchPid -gt 0) {
    $deadline = (Get-Date).AddSeconds($DismissTimeout)
    $closed = 0
    # 活干完就收工，别空转到超时。设计原则「轻量」：会不会增加额外负担？会就不做。
    # 实测时间线：第 3 秒还原窗口、第 11 秒关掉弹窗 —— 剩下 109 秒纯粹空转。
    # 关掉弹窗后再多守 $GraceSec 秒，防它二次弹出（复制 visual 时出现过连弹）。
    $GraceSec  = 12
    $doneAfter = $null
    ("[{0}] 守候开始 PID={1} 超时={2}s" -f (Get-Date -Format 'HH:mm:ss'), $WatchPid, $DismissTimeout) |
        Out-File $logFile -Append -Encoding utf8

    # 主窗口一出现就把它放回原位，免得重启后蹦回主屏抢走外接大屏
    $restored = -not $RestoreRect
    $rc = if ($RestoreRect) { $RestoreRect -split ',' | ForEach-Object { [int]$_ } } else { $null }
    # 只在开头这段时间里跟 Desktop 抢窗口状态；之后就撒手，免得用户自己拖窗口被我们拽回去
    $RestoreWindowSec = 45
    $restoreDeadline = (Get-Date).AddSeconds($RestoreWindowSec)
    $loggedOk = $false

    $processGone = $false
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $WatchPid -ErrorAction SilentlyContinue)) { $processGone = $true; break }

        # 加载期间 Desktop 会自己重设窗口状态，把我们的还原盖掉，
        # 所以要「做完再验、没成就重来」，不能一次性设完就当成功。
        if (-not $restored -and (Get-Date) -lt $restoreDeadline) {
            $main = Get-MainWindow -TargetPid $WatchPid
            if ($main) {
                $r = New-Object WRECT
                [void][PbiWin]::GetWindowRect($main.Handle, [ref]$r)

                # 🔴 判据一律是「最终矩形 ≈ 原矩形」，不看 IsZoomed —— 实测 SW_MAXIMIZE 会把
                #    状态标志置上但窗口没被撑开（停在临时的 800×600），只查标志会得到假成功。
                $tw = $rc[2] - $rc[0]; $th = $rc[3] - $rc[1]
                $cw = $r.Right - $r.Left; $ch = $r.Bottom - $r.Top
                $posOk  = ([Math]::Abs($r.Left - $rc[0]) -lt 20) -and ([Math]::Abs($r.Top - $rc[1]) -lt 20)
                $sizeOk = ([Math]::Abs($cw - $tw) -lt 60) -and ([Math]::Abs($ch - $th) -lt 60)

                # 🔴 达标了也不收工 —— Desktop 加载完还会自己再调一次窗口，
                #    早早判定成功就会把「过程中的快照」当最终结果（实测踩过：
                #    启动后 3 秒量到 798×600，等加载完其实是 1508×900）。
                #    所以持续盯到 $restoreDeadline，中途漂了就再摆正。
                if ($posOk -and $sizeOk) {
                    if (-not $loggedOk) {
                        $loggedOk = $true
                        ("[{0}] 窗口就位 L={1} T={2} {3}x{4}{5}（继续盯到 {6}s）" -f (Get-Date -Format 'HH:mm:ss'),
                            $r.Left, $r.Top, $cw, $ch, $(if ($RestoreMax) { ' 最大化' }), $RestoreWindowSec) |
                            Out-File $logFile -Append -Encoding utf8
                    }
                }
                elseif ($RestoreMax) {
                    # 先还原成普通窗口，再挪到目标屏，再最大化 —— 少了 RESTORE 这步，
                    # 窗口已被标记为最大化时后续 MoveWindow/MAXIMIZE 都不会真正生效。
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
            # 时间到，撒手不再跟用户抢窗口。记一笔最终状态，方便事后核对。
            $restored = $true
            $fin = Get-MainWindow -TargetPid $WatchPid
            if ($fin) {
                $fr = New-Object WRECT
                [void][PbiWin]::GetWindowRect($fin.Handle, [ref]$fr)
                # 判定跟循环内同标准：位置+尺寸都对才算 OK
                # （只比宽度曾把落在屏幕外的窗口误报成 OK，2026-07-30 实测）
                $finOk = ([Math]::Abs($fr.Left - $rc[0]) -lt 20) -and ([Math]::Abs($fr.Top - $rc[1]) -lt 20) -and
                         ([Math]::Abs(($fr.Right-$fr.Left)-($rc[2]-$rc[0])) -lt 60) -and
                         ([Math]::Abs(($fr.Bottom-$fr.Top)-($rc[3]-$rc[1])) -lt 60)
                ("[{0}] 守窗结束 最终 L={1} T={2} {3}x{4} 目标 {5}x{6} → {7}" -f (Get-Date -Format 'HH:mm:ss'),
                    $fr.Left, $fr.Top, ($fr.Right-$fr.Left), ($fr.Bottom-$fr.Top),
                    ($rc[2]-$rc[0]), ($rc[3]-$rc[1]),
                    $(if ($finOk) { 'OK' } else { '不符' })) |
                    Out-File $logFile -Append -Encoding utf8
            }
        }

        if (-not $NoDismiss) {
        foreach ($t in (Get-MatchingWindows -TargetPid $WatchPid -Titles $DialogTitles)) {
            [void][PbiWin]::PostMessage($t.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE
            $closed++
            ("[{0}] 已关闭 title='{1}' class='{2}'" -f (Get-Date -Format 'HH:mm:ss'), $t.Title, $t.Class) |
                Out-File $logFile -Append -Encoding utf8
            Start-Sleep -Milliseconds 600
        }
        }

        # 收工判定：窗口已就位 + 弹窗已关过（或本来就不管弹窗）
        #   → 再宽限 $GraceSec 秒就退出，不再占着一个后台进程。
        # 弹窗若始终没出现，则自然回退到 $DismissTimeout 超时（安全兜底）。
        $jobDone = $restored -and ($closed -gt 0 -or $NoDismiss)
        if ($jobDone -and -not $doneAfter) { $doneAfter = (Get-Date).AddSeconds($GraceSec) }
        if ($doneAfter -and (Get-Date) -ge $doneAfter) { break }

        Start-Sleep -Milliseconds 400
    }

    # 三种收工方式分开记：提前收工=活干完；目标进程已退出=用户自己关了 Desktop；等到超时=兜底
    $how = if ($doneAfter) { '提前收工' } elseif ($processGone) { '目标进程已退出' } else { '等到超时' }
    ("[{0}] 守候结束（{1}），共关闭 {2} 个`r`n" -f (Get-Date -Format 'HH:mm:ss'), $how, $closed) |
        Out-File $logFile -Append -Encoding utf8
    exit
}

# ============================================================
#  正常模式
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
    if (-not $NoDismiss) { $what += '关登录弹窗' }
    if ($Rect)           { $what += '还原窗口位置' }
    Write-Step ("守候进程已启动（{0}，{1} 秒）" -f ($what -join ' + '), $DismissTimeout)
}

# 记下窗口位置，重开后放回去 —— 否则会蹦回主屏，抢走外接大屏的工作区
function Get-Placement([IntPtr]$Hwnd) {
    if ($Hwnd -eq [IntPtr]::Zero) { return $null }
    $r = New-Object WRECT
    if (-not [PbiWin]::GetWindowRect($Hwnd, [ref]$r)) { return $null }
    return [pscustomobject]@{
        Rect  = "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
        IsMax = [PbiWin]::IsZoomed($Hwnd)
    }
}

# 记下的矩形可信吗 —— 退化尺寸或不在任何屏幕内，说明窗口当时处于奇怪状态
# （最小化会量到 -32000；被拖到屏幕边缘只露一角时实测量到过 -21281,-20853 107x19）。
# 把这种矩形照搬给重开后的窗口，只会把它藏到屏幕外，还跟用户抢满整个守窗期。
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

# ---------- 1. 确定目标 .pbip ----------
if (-not $Path -and (Test-Path $memFile)) {
    try {
        $Path = (Get-Content $memFile -Raw -Encoding UTF8 | ConvertFrom-Json).Path
        Write-Step "沿用上次路径: $Path"
    } catch { }
}

# ---------- 2. 找运行中的 Desktop ----------
$procs = @(Get-Process -Name 'PBIDesktop' -ErrorAction SilentlyContinue)

if ($procs.Count -eq 0) {
    Write-Host "Power BI Desktop 未运行。"
    if ($ListOnly) { return }
    if (-not $Path) { throw "没有可用路径。请用 -Path 指定 .pbip。" }
    if (-not (Test-Path $Path)) { throw "路径不存在: $Path" }
    Write-Step "直接打开..."
    $exe = 'C:\Program Files\Microsoft Power BI Desktop\bin\PBIDesktop.exe'
    $np = Start-Process -FilePath $exe -ArgumentList "`"$Path`"" -PassThru
    @{ Path = $Path } | ConvertTo-Json | Out-File $memFile -Encoding utf8
    Start-Watcher -ProcId $np.Id -Rect '' -WasMax $false
    Write-Host "已启动（常规版）。"
    return
}

if ($procs.Count -gt 1 -and -not $Id) {
    # 多 agent 共用一机：-Path 就是身份。按项目名匹配窗口标题，命中唯一就不再要求 -Id
    if ($Path) {
        $stem = [WildcardPattern]::Escape([IO.Path]::GetFileNameWithoutExtension($Path))
        $byTitle = @($procs | Where-Object { $_.MainWindowTitle -like "$stem - *" })
        if ($byTitle.Count -eq 1) { $procs = $byTitle }
    }
    if ($procs.Count -gt 1) {
        Write-Host "发现多个 Desktop 实例，请用 -Id 指定要重启哪个：`n"
        foreach ($p in $procs) {
            $ver = if ($p.Path -like '*Desktop RS*') { 'RS版' } else { '常规版' }
            Write-Host ("  -Id {0}   [{1}]  {2}" -f $p.Id, $ver, $p.MainWindowTitle)
        }
        return
    }
}

$target = if ($Id) { $procs | Where-Object { $_.Id -eq $Id } } else { $procs[0] }
if (-not $target) { throw "找不到 PID $Id 的 Desktop 进程。" }

# 单实例但与 -Path 的项目不符 —— 多半是别的 agent/会话的 Desktop，动手前先喊一声
if ($Path -and $target.MainWindowTitle) {
    $stem = [WildcardPattern]::Escape([IO.Path]::GetFileNameWithoutExtension($Path))
    if ($target.MainWindowTitle -notlike "$stem - *") {
        Write-Host "⚠ 运行中的实例是「$($target.MainWindowTitle)」，与 -Path 的项目不一致 —— 将结束它并打开 $(Split-Path $Path -Leaf)" -ForegroundColor Yellow
    }
}

$exePath = $target.Path
$edition = if ($exePath -like '*Desktop RS*') { 'RS版' } else { '常规版' }

# ---------- 3. 报告状态 ----------
Write-Host "`n当前实例"
Write-Step "PID      : $($target.Id)"
Write-Step "版本     : $edition"
Write-Step "窗口标题 : $($target.MainWindowTitle)"
Write-Step "启动于   : $($target.StartTime)"

# 磁盘是否比 Desktop 更新 —— 判断「该不该重载」的直接依据
if ($Path -and (Test-Path $Path)) {
    $projDir = Split-Path $Path -Parent
    $newer = @(Get-ChildItem $projDir -Recurse -File -Include *.tmdl,*.json,*.pbir,*.pbism -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -gt $target.StartTime })
    if ($newer.Count -gt 0) {
        Write-Host "`n磁盘已变更（Desktop 打开之后）—— 需要重载" -ForegroundColor Yellow
        $newer | Sort-Object LastWriteTime -Descending | Select-Object -First 6 | ForEach-Object {
            Write-Step ("{0:HH:mm:ss}  {1}" -f $_.LastWriteTime, $_.Name)
        }
        if ($newer.Count -gt 6) { Write-Step "... 共 $($newer.Count) 个文件" }
    } else {
        Write-Host "`n磁盘无变更 —— Desktop 已是最新，其实不用重载" -ForegroundColor DarkGray
    }
}

$msmd = @(Get-WmiObject Win32_Process -Filter "Name='msmdsrv.exe'" -ErrorAction SilentlyContinue |
          Where-Object { $_.ParentProcessId -eq $target.Id })
if ($msmd.Count -gt 0) { Write-Step "关联 msmdsrv : $(($msmd | ForEach-Object { $_.ProcessId }) -join ', ')" }

if ($ListOnly) { Write-Host "`n(-ListOnly，未做任何操作)"; return }

if (-not $Path) { throw "`n没有可用路径，无法重开。请用 -Path 指定 .pbip。" }
if (-not (Test-Path $Path)) { throw "`n路径不存在: $Path" }

# ---------- 3.5 确认 ----------
#
# 为什么非问不可：有两种方向相反的情况，工具从外部分不出来
#   ① 磁盘 TMDL 被改过、Desktop 内存是旧的  → 绝不能保存（保存会覆盖磁盘改动）
#   ② 你刚在 Desktop 里改了还没存           → 必须先保存（不然杀掉就没了）
# Desktop 的标题栏不带修改标记，枚举窗口也拿不到「脏」状态 —— 只有人知道。
#
# 不弹 GUI 对话框、也不用 Read-Host 阻塞等待（2026-07-30 用户要求：
# 他装了 Clawd 桌宠，对话里问就看得到，别再额外弹窗打扰）。
# 改成：没给 -Yes 就直接停下并提示。确认这件事发生在对话里，不在脚本里。
if (-not $Yes) {
    Write-Host "`n⚠ 即将结束 Power BI Desktop，它内存里未保存的改动会全部丢失。" -ForegroundColor Yellow
    Write-Host "   $(Split-Path $Path -Leaf)"
    Write-Host ""
    Write-Host "   确认 Desktop 里没有未保存的改动后，加 -Yes 重跑：" -ForegroundColor Yellow
    Write-Host "     & `"$PSCommandPath`" -Yes"
    Write-Host ""
    Write-Host "已停下，什么都没动。"
    return
}

# ---------- 4. 杀掉 ----------
Write-Host "`n重启中"

# 杀之前记下窗口在哪、是不是最大化，重开后放回去
$placement = Get-Placement -Hwnd $target.MainWindowHandle
if ($placement -and -not (Test-RectSane $placement.Rect)) {
    Write-Step "记下的窗口位置异常（$($placement.Rect)），放弃还原，重开用默认位置"
    $placement = $null
}
if ($placement) { Write-Step "记下窗口位置 $($placement.Rect)$(if ($placement.IsMax) { ' (最大化)' })" }

Write-Step "结束 Desktop（不保存）..."
Stop-Process -Id $target.Id -Force

$deadline = (Get-Date).AddSeconds(20)
while ((Get-Process -Id $target.Id -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
}

foreach ($m in $msmd) {
    if (Get-Process -Id $m.ProcessId -ErrorAction SilentlyContinue) {
        Write-Step "清理残留 msmdsrv $($m.ProcessId)..."
        Stop-Process -Id $m.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 5. 重开 ----------
Start-Sleep -Milliseconds 500
Write-Step "重新打开 [$edition] $(Split-Path $Path -Leaf) ..."
$newProc = Start-Process -FilePath $exePath -ArgumentList "`"$Path`"" -PassThru

@{ Path = $Path } | ConvertTo-Json | Out-File $memFile -Encoding utf8

Start-Watcher -ProcId $newProc.Id `
    -Rect   $(if ($placement) { $placement.Rect }  else { '' }) `
    -WasMax $(if ($placement) { [bool]$placement.IsMax } else { $false })

Write-Host "`n完成。Desktop 正在加载，模型大的话等一会儿。"
Write-Host "弹窗处理记录: $logFile"
