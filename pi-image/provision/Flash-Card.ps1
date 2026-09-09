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
    Per-unit hostname, e.g. pod-sw. The only value that differs per card.
    The fleet uses compass points with the nose as north (coordinator#227):
    pod-ne, pod-se, pod-sw, pod-nw. The scheme subdivides -- ne splits into
    nne + ene -- so an arm that later carries a second camera does not force
    renaming the first.

.PARAMETER Disk
    Target device as \\.\PhysicalDriveN, or just the number N. There is no
    stable "right" number -- it depends on what is plugged in -- so the script
    resolves it with Get-Disk and shows you the make, size and bus type before
    it writes anything. Confirm at that prompt, or pass -Force to skip it.

.PARAMETER Image
    Path to the built image (rpi-imager reads .xz directly). The CI artifact
    downloads as e.g. campod-pi-btrfs-img.zip -- EXTRACT IT FIRST; the file you
    want is the campod-pi-<YYYYMMDD>.img.xz inside. Imager will not read an
    .img.xz that is still inside a .zip.

.PARAMETER SecretsFile
    Defaults to fleet.env beside this script.

.PARAMETER Imager
    Path to rpi-imager.exe. Found automatically on PATH or in the usual install
    roots; pass it explicitly if it lives somewhere else.

.PARAMETER Force
    Skip the "about to erase this disk" confirmation.

.EXAMPLE
    .\Flash-Card.ps1 -Hostname pod-sw -Disk 2 -Image ~\Downloads\campod-pi-20260908.img.xz
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Hostname,
    [Parameter(Mandatory = $true)][string] $Disk,
    [Parameter(Mandatory = $true)][string] $Image,
    [string] $SecretsFile,
    [string] $Imager,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# Resolve this script's own directory WITHOUT relying on $PSScriptRoot being
# populated. It is empty in some invocation forms -- observed running
# `powershell -ExecutionPolicy Bypass -File` against a \\wsl.localhost\... path --
# and an empty $PSScriptRoot in a param() default fails at bind time, before any
# of this script's own error handling can say anything useful.
$here = $PSScriptRoot
if (-not $here) { $here = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { $null } }
if (-not $here) { $here = (Get-Location).Path }

if (-not $SecretsFile) { $SecretsFile = Join-Path $here 'fleet.env' }
$TemplateFile = Join-Path $here 'firstrun.sh.template'

# Find rpi-imager rather than assuming an install path. Hardcoding
# "$env:ProgramFiles\Raspberry Pi Imager" was a guess and it was wrong on a real
# machine; the installer's location varies (per-user vs per-machine, x86 vs x64,
# winget vs the .exe). Look on PATH first, then the usual roots, then say exactly
# where we looked so -Imager can be pointed at it.
if (-not $Imager) {
    $onPath = Get-Command 'rpi-imager.exe' -ErrorAction SilentlyContinue
    $candidates = @()
    if ($onPath) { $candidates += $onPath.Source }
    $candidates += @(
        "$env:ProgramFiles\Raspberry Pi Ltd\Imager\rpi-imager.exe"
        "${env:ProgramFiles(x86)}\Raspberry Pi Ltd\Imager\rpi-imager.exe"
        "$env:ProgramFiles\Raspberry Pi Imager\rpi-imager.exe"
        "${env:ProgramFiles(x86)}\Raspberry Pi Imager\rpi-imager.exe"
        "$env:LOCALAPPDATA\Programs\Raspberry Pi Imager\rpi-imager.exe"
        "$env:LOCALAPPDATA\Raspberry Pi Imager\rpi-imager.exe"
    ) | Where-Object { $_ -and $_ -notmatch '^\\' }   # drop entries where the env var was empty

    $Imager = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $Imager) {
        throw ("rpi-imager.exe not found. Looked on PATH and at:`n  " +
               (($candidates | Select-Object -Unique) -join "`n  ") +
               "`nPass -Imager <path>. To locate it:`n" +
               '  Get-ChildItem $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA -Recurse -Filter rpi-imager.exe -ErrorAction SilentlyContinue | Select-Object FullName')
    }
    Write-Host "imager   -> $Imager"
}

foreach ($p in @($SecretsFile, $TemplateFile, $Image, $Imager)) {
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

# An empty value would substitute silently and produce e.g. userconf 'pi' '' --
# an empty password. Treat blank as absent so it is reported below with the rest.
foreach ($k in @($vals.Keys)) { if ([string]::IsNullOrWhiteSpace($vals[$k])) { $vals.Remove($k) } }

# --- render ------------------------------------------------------------------
$template = Get-Content -LiteralPath $TemplateFile -Raw
foreach ($k in $vals.Keys) { $template = $template.Replace("__${k}__", $vals[$k]) }

# Report EVERY missing key at once -- filling these in one error at a time is
# needlessly tedious.
$missing = [regex]::Matches($template, '__[A-Z_]+__') | ForEach-Object { $_.Value } | Sort-Object -Unique
if ($missing) {
    throw "these are blank or absent in ${SecretsFile}: $($missing -join ', ')"
}

# Single quotes in the template are the shell's; a value containing one would
# break out of its argument. None of these values legitimately contain one.
foreach ($k in $vals.Keys) {
    if ($vals[$k] -match "'") { throw "value for $k contains a single quote, which would break the generated shell script" }
}

# MUST be LF. This is a shell script the Pi runs; PowerShell's default CRLF
# would leave "#!/bin/sh`r" and the script would not execute.
$rendered = Join-Path ([System.IO.Path]::GetTempPath()) "firstrun-$Hostname.sh"
[System.IO.File]::WriteAllText($rendered, ($template -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))

# --- identify and confirm the target disk -------------------------------------
# Getting this wrong erases the wrong drive, and the PhysicalDrive number is not
# stable across sessions, so show what is actually there rather than trusting the
# number that was typed.
if ($Disk -match '^(?:\\\\\.\\PhysicalDrive)?(\d+)$') { $diskNumber = [int]$Matches[1] }
else { throw "-Disk must be a number or \\.\PhysicalDriveN, got: $Disk" }
$Disk = "\\.\PhysicalDrive$diskNumber"

$target = Get-Disk -Number $diskNumber -ErrorAction SilentlyContinue
if (-not $target) { throw "no disk with Number $diskNumber. Run: Get-Disk | Format-Table Number, FriendlyName, Size, BusType" }

$sizeGB = [math]::Round($target.Size / 1GB, 1)
Write-Host ""
Write-Host "  ABOUT TO ERASE  $Disk" -ForegroundColor Red
Write-Host "  $($target.FriendlyName)  ${sizeGB} GB  bus=$($target.BusType)  partitions=$($target.NumberOfPartitions)"
Write-Host ""
if ($target.BusType -notin @('USB', 'SD')) {
    Write-Host "  NOTE: bus type is $($target.BusType), not USB or SD. Card readers are normally one of those." -ForegroundColor Yellow
}
if (-not $Force) {
    if ((Read-Host "Type the disk number ($diskNumber) to confirm") -ne "$diskNumber") { throw 'aborted' }
}

Write-Host "rendered -> $rendered  (hostname=$Hostname)"
Write-Host "flashing $Image -> $Disk ..." -ForegroundColor Yellow

# rpi-imager.exe is a GUI-subsystem binary, so the call operator does NOT wait
# for it: `& $Imager ...` returns immediately, $LASTEXITCODE is never set, and the
# finally block below deleted the firstrun script while the imager was still
# starting -- which it then reported as "firstrun script does not exists".
# Start-Process -Wait actually blocks and -PassThru gives a real exit code.
#
# -ArgumentList elements are not auto-quoted on Windows PowerShell 5.1, so quote
# the paths here; any of them can contain spaces.
$argList = @(
    '--cli'
    '--first-run-script'
    "`"$rendered`""
    "`"$Image`""
    "`"$Disk`""
)
try {
    $proc = Start-Process -FilePath $Imager -ArgumentList $argList -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "rpi-imager exited $($proc.ExitCode)" }
    Write-Host "done: $Hostname" -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $rendered -Force -ErrorAction SilentlyContinue
}
