$ErrorActionPreference = 'Stop'

# pbi-check-loop bootstrap installer
# Usage: irm https://raw.githubusercontent.com/C-QY/pbi-check-loop/main/get.ps1 | iex
#
# This file exists because `iex` evaluates its input as an EXPRESSION, and a script
# with [CmdletBinding()] / param() is only valid as a FILE. So install.ps1 cannot be
# piped into iex directly - it is downloaded to a temp file and invoked from there.
#
# The first line is deliberately a statement, not a comment: if a BOM survives the
# download, iex would otherwise parse U+FEFF plus '#' as a command name and fail.

$repo = 'https://github.com/C-QY/pbi-check-loop'
$tmp  = Join-Path $env:TEMP ('pbi-check-loop-' + [guid]::NewGuid().ToString('N').Substring(0,8))

Write-Host ''
Write-Host '  Fetching pbi-check-loop...' -ForegroundColor Gray

try {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        git clone --depth 1 --quiet $repo $tmp 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    }
    else {
        # No git: fall back to the source tarball GitHub serves for any repo
        $zip = "$tmp.zip"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "$repo/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        Remove-Item $zip -Force
        # Archive unpacks into <repo>-main\ - lift its contents up one level
        $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
        if ($inner) {
            Get-ChildItem $inner.FullName -Force | Move-Item -Destination $tmp -Force
            Remove-Item $inner.FullName -Recurse -Force
        }
    }

    $installer = Join-Path $tmp 'install.ps1'
    if (-not (Test-Path $installer)) { throw "install.ps1 not found in the downloaded copy" }

    & $installer
}
finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
