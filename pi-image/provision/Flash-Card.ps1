<#
.SYNOPSIS
    Flash one fleet SD card and inject its per-unit identity, on Windows.

.DESCRIPTION
    Renders firstrun.sh.template with values from fleet.env plus the -Hostname
    argument, then hands it to rpi-imager's CLI, which writes the image, copies
    firstrun.sh onto the FAT partition, and appends the systemd.run= tokens to
    cmdline.txt. No WSL, no block-device passthrough, no secrets in the image.

    Run from an elevated PowerShell (rpi-imager needs Administrator to write a
    raw device).

.PARAMETER Hostname
    Per-unit hostname, e.g. z-left-rear. The only value that differs per card.

.PARAMETER Disk
    Target device, e.g. \\.\PhysicalDrive2. Find it with:
        Get-Disk | Format-Table Number, FriendlyName, Size, BusType
    ...and read PhysicalDriveN off the Number column. CHECK THE SIZE. This
    overwrites the disk with no further prompt.

.PARAMETER Image
    Path to the built image, e.g. pod-pi-20260906.img.xz (rpi-imager reads .xz).

.EXAMPLE
    .\Flash-Card.ps1 -Hostname z-left-rear -Disk \\.\PhysicalDrive2 -Image .\pod-pi-20260906.img.xz
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Hostname,
    [Parameter(Mandatory = $true)][string] $Disk,
    [Parameter(Mandatory = $true)][string] $Image,
    [string] $SecretsFile = (Join-Path $PSScriptRoot 'fleet.env'),
    [string] $Imager = (Join-Path $env:ProgramFiles 'Raspberry Pi Imager\rpi-imager.exe')
)

$ErrorActionPreference = 'Stop'

foreach ($p in @($SecretsFile, $Image, $Imager)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "not found: $p" }
}

# --- load fleet.env (KEY=VALUE, # comments, blank lines) ----------------------
$vals = @{}
foreach ($line in Get-Content -LiteralPath $SecretsFile) {
    if ($line -match '^\s*(#|$)') { continue }
    if ($line -notmatch '^\s*([A-Z_]+)\s*=\s*(.*?)\s*$') { throw "bad line in ${SecretsFile}: $line" }
    $vals[$Matches[1]] = $Matches[2]
}
$vals['HOSTNAME'] = $Hostname

# --- render ------------------------------------------------------------------
$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'firstrun.sh.template') -Raw
foreach ($k in $vals.Keys) { $template = $template.Replace("__${k}__", $vals[$k]) }

$missing = [regex]::Matches($template, '__[A-Z_]+__') | ForEach-Object { $_.Value } | Sort-Object -Unique
if ($missing) { throw "unsubstituted placeholders (empty or absent in ${SecretsFile}): $($missing -join ', ')" }

# Single quotes in the template are the shell's; a value containing one would
# break out of its argument. None of these values legitimately contain one.
foreach ($k in $vals.Keys) {
    if ($vals[$k] -match "'") { throw "value for $k contains a single quote, which would break the generated shell script" }
}

# MUST be LF. This is a shell script the Pi runs; PowerShell's default CRLF
# would leave "#!/bin/sh`r" and the script would not execute.
$rendered = Join-Path ([System.IO.Path]::GetTempPath()) "firstrun-$Hostname.sh"
[System.IO.File]::WriteAllText($rendered, ($template -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))

Write-Host "rendered -> $rendered  (hostname=$Hostname)"
Write-Host "flashing $Image -> $Disk ..." -ForegroundColor Yellow

try {
    & $Imager --cli --first-run-script $rendered $Image $Disk
    if ($LASTEXITCODE -ne 0) { throw "rpi-imager exited $LASTEXITCODE" }
    Write-Host "done: $Hostname" -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $rendered -Force -ErrorAction SilentlyContinue
}
