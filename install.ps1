<#
.SYNOPSIS
    Install pbi-check-loop: scripts into ~\.claude	ools\, skill into ~\.claude\skills\.

.DESCRIPTION
    The consumer of these tools is an AI agent, not a human. So "installing" is mostly about
    placing the skill: that is how an agent learns the tools exist, when to reach for them,
    and which pitfalls to avoid.

.PARAMETER ToolsDir
    Where the scripts go. Default ~\.claude	ools

.PARAMETER SkillsDir
    Where the skill goes. Default ~\.claude\skills

.PARAMETER Uninstall
    Remove the installed files. Leaves this repository alone.

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

# ---------------- Uninstall ----------------
if ($Uninstall) {
    Write-Host "`nUninstalling pbi-check-loop"
    foreach ($s in $scripts) {
        $p = Join-Path $ToolsDir $s
        if (Test-Path $p) { Remove-Item $p -Force; Say "removed $p" }
    }
    # Clean up files produced at runtime as well
    foreach ($f in @('pbi-reload.last.json', 'pbi-reload.dialogs.log')) {
        $p = Join-Path $ToolsDir $f
        if (Test-Path $p) { Remove-Item $p -Force; Say "removed $p" }
    }
    if (Test-Path $skillDest) { Remove-Item $skillDest -Recurse -Force; Say "removed $skillDest" }
    Write-Host "`nUninstalled." -ForegroundColor Green
    return
}

# ---------------- Preflight ----------------
Write-Host "`nInstalling pbi-check-loop"

if ($PSVersionTable.PSVersion.Major -lt 5) { throw "PowerShell 5.1 or newer required; found $($PSVersionTable.PSVersion)" }

# One-line install: irm https://raw.githubusercontent.com/C-QY/pbi-check-loop/main/install.ps1 | iex
# Piped into iex there are no repo files alongside this script ($PSScriptRoot is empty),
# so clone to a temp directory first and run the real install from there.
if (-not $src -or -not (Test-Path (Join-Path $src 'scripts\pbi-reload.ps1'))) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git is required for the one-line install. Install git, or clone the repo and run .\install.ps1 manually."
    }
    $tmp = Join-Path $env:TEMP 'pbi-check-loop-install'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Say "Cloning the repository..."
    git clone --depth 1 https://github.com/C-QY/pbi-check-loop $tmp 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Clone failed. Check your network, or clone manually and run .\install.ps1." }
    & (Join-Path $tmp 'install.ps1') -ToolsDir $ToolsDir -SkillsDir $SkillsDir
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return
}

$missing = @($scripts | Where-Object { -not (Test-Path (Join-Path $src "scripts\$_")) })
if ($missing) { throw "Incomplete repository, missing: $($missing -join ', '). Run this from the root of a cloned repo." }
if (-not (Test-Path (Join-Path $src 'SKILL.md'))) { throw "SKILL.md not found" }

# ---------------- Install scripts ----------------
New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
Write-Host "`n[1/3] Scripts -> $ToolsDir"
foreach ($s in $scripts) {
    Copy-Item (Join-Path $src "scripts\$s") (Join-Path $ToolsDir $s) -Force
    Say $s
}

# ---------------- Install skill ----------------
New-Item -ItemType Directory -Path $skillDest -Force | Out-Null
Write-Host "`n[2/3] Skill -> $skillDest"
Copy-Item (Join-Path $src 'SKILL.md') (Join-Path $skillDest 'SKILL.md') -Force
Say "SKILL.md"

# ---------------- Self-check ----------------
Write-Host "`n[3/3] Self-check"
$bad = 0
foreach ($s in $scripts) {
    $p = Join-Path $ToolsDir $s

    # Does it parse?
    $err = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$err)
    $synOk = -not ($err -and $err.Count -gt 0)

    # Must be UTF-8 WITH BOM: these scripts contain non-ASCII dialog titles, and without a
    # BOM PowerShell 5.1 reads them in the system ANSI codepage and parsing breaks
    $b = [System.IO.File]::ReadAllBytes($p)[0..2]
    $bomOk = ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)

    if ($synOk -and $bomOk) { Say "$s  syntax OK  BOM OK" 'Green' }
    else {
        $bad++
        Say ("$s  syntax={0}  BOM={1}" -f $(if($synOk){'OK'}else{'FAILED'}), $(if($bomOk){'OK'}else{'MISSING'})) 'Red'
        if ($err) { $err | ForEach-Object { Say ("    line " + $_.Extent.StartLineNumber + ": " + $_.Message) 'Red' } }
    }
}

if ($bad -gt 0) { throw "Self-check failed on $bad file(s)." }

# ---------------- Done ----------------
Write-Host "`nInstalled." -ForegroundColor Green
Write-Host @"

  Usage (an agent calls these by full path):

    & "`$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -ListOnly    # check state
    & "`$env:USERPROFILE\.claude\tools\pbi-reload.ps1" -Yes         # reload
    & "`$env:USERPROFILE\.claude\tools\pbi-shot.ps1" -Out shot.png  # capture

  Restart Claude Code to activate the skill; the agent will reach for it on its own.

  Uninstall:  .\install.ps1 -Uninstall
"@ -ForegroundColor DarkGray
