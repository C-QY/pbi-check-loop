<#
.SYNOPSIS
    安装 pbi-check-loop：脚本装到 ~\.claude\tools\，skill 装到 ~\.claude\skills\。

.DESCRIPTION
    这套工具的使用者是 AI agent，不是人。所以「安装」除了放脚本，
    更重要的是把 skill 装好 —— agent 靠它知道这工具存在、什么时候该用、有哪些坑。

.PARAMETER ToolsDir
    脚本安装位置。默认 ~\.claude\tools

.PARAMETER SkillsDir
    skill 安装位置。默认 ~\.claude\skills

.PARAMETER Uninstall
    卸载：删掉装过去的文件（不动本仓库）。

.EXAMPLE
    .\install.ps1
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$ToolsDir  = (Join-Path $env:USERPROFILE '.claude\tools'),
    [string]$SkillsDir = (Join-Path $env:USERPROFILE '.claude\skills'),
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$src        = $PSScriptRoot
$skillName  = 'pbi-check-loop'
$scripts    = @('pbi-reload.ps1', 'pbi-shot.ps1')
$skillDest  = Join-Path $SkillsDir $skillName

function Say($msg, $color = 'Gray') { Write-Host "  $msg" -ForegroundColor $color }

# ---------------- 卸载 ----------------
if ($Uninstall) {
    Write-Host "`n卸载 pbi-check-loop"
    foreach ($s in $scripts) {
        $p = Join-Path $ToolsDir $s
        if (Test-Path $p) { Remove-Item $p -Force; Say "已删 $p" }
    }
    # 运行时产生的附属文件一并清掉
    foreach ($f in @('pbi-reload.last.json', 'pbi-reload.dialogs.log')) {
        $p = Join-Path $ToolsDir $f
        if (Test-Path $p) { Remove-Item $p -Force; Say "已删 $p" }
    }
    if (Test-Path $skillDest) { Remove-Item $skillDest -Recurse -Force; Say "已删 $skillDest" }
    Write-Host "`n卸载完成。" -ForegroundColor Green
    return
}

# ---------------- 前置检查 ----------------
Write-Host "`n安装 pbi-check-loop"

if ($PSVersionTable.PSVersion.Major -lt 5) { throw "需要 PowerShell 5.1 或更高，当前 $($PSVersionTable.PSVersion)" }

$missing = @($scripts | Where-Object { -not (Test-Path (Join-Path $src "scripts\$_")) })
if ($missing) { throw "仓库不完整，缺少: $($missing -join ', ')。请在克隆下来的仓库根目录运行本脚本。" }
if (-not (Test-Path (Join-Path $src 'SKILL.md'))) { throw "缺少 SKILL.md" }

# ---------------- 装脚本 ----------------
New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
Write-Host "`n[1/3] 安装脚本 -> $ToolsDir"
foreach ($s in $scripts) {
    Copy-Item (Join-Path $src "scripts\$s") (Join-Path $ToolsDir $s) -Force
    Say $s
}

# ---------------- 装 skill ----------------
New-Item -ItemType Directory -Path $skillDest -Force | Out-Null
Write-Host "`n[2/3] 安装 skill -> $skillDest"
Copy-Item (Join-Path $src 'SKILL.md') (Join-Path $skillDest 'SKILL.md') -Force
Say "SKILL.md"

# ---------------- 自检 ----------------
Write-Host "`n[3/3] 自检"
$bad = 0
foreach ($s in $scripts) {
    $p = Join-Path $ToolsDir $s

    # 语法能不能解析
    $err = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$err)
    $synOk = -not ($err -and $err.Count -gt 0)

    # 必须是 UTF-8 带 BOM —— 脚本含中文，PS 5.1 缺 BOM 会按 GBK 误读导致解析失败
    $b = [System.IO.File]::ReadAllBytes($p)[0..2]
    $bomOk = ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)

    if ($synOk -and $bomOk) { Say "$s  语法 OK  BOM OK" 'Green' }
    else {
        $bad++
        Say ("$s  语法={0}  BOM={1}" -f $(if($synOk){'OK'}else{'失败'}), $(if($bomOk){'OK'}else{'缺失'})) 'Red'
        if ($err) { $err | ForEach-Object { Say ("    第 " + $_.Extent.StartLineNumber + " 行: " + $_.Message) 'Red' } }
    }
}

if ($bad -gt 0) { throw "自检未通过，装了 $bad 个有问题的文件。" }

# ---------------- 完成 ----------------
Write-Host "`n安装完成。" -ForegroundColor Green
Write-Host @"

  用法（agent 直接按全路径调用即可）：

    & "`$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -ListOnly        # 看状态
    & "`$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -Yes             # 重载
    & "`$env:USERPROFILE\.claude\tools\pbi-shot.ps1" -Out shot.png      # 截图

  重启 Claude Code 后 skill 生效，agent 会在合适时机自动想起来用它。

  卸载：  .\install.ps1 -Uninstall
"@ -ForegroundColor DarkGray
