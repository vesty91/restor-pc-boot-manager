<#
.SYNOPSIS
  Verifie release/RELEASE-INTEGRITY.txt et RELEASE-INFO.json.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
} else {
    $RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
}

$integrityPath = Join-Path $RepoRoot 'release\RELEASE-INTEGRITY.txt'
$infoPath = Join-Path $RepoRoot 'release\RELEASE-INFO.json'
$failed = $false

function Write-Step {
    param([string]$Level, [string]$Message)
    Write-Host ("[{0}] {1}" -f $Level, $Message)
}

if (-not (Test-Path -LiteralPath $integrityPath -PathType Leaf)) {
    Write-Step 'ERROR' 'RELEASE-INTEGRITY.txt absent.'
    exit 1
}
if (-not (Test-Path -LiteralPath $infoPath -PathType Leaf)) {
    Write-Step 'ERROR' 'RELEASE-INFO.json absent.'
    exit 1
}

$info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$info.Algorithm -ne 'SHA256') {
    $failed = $true
    Write-Step 'ERROR' 'Algorithm inattendu.'
}
$expectedEntries = @('WIN CODE', 'WIN VESTY', 'MEMTEST86+', 'RESCUEGRID', 'LOCKPICK')
$actualEntries = @($info.BootMenuEntries | ForEach-Object { [string]$_ })
foreach ($entry in $expectedEntries) {
    if ($actualEntries -notcontains $entry) {
        $failed = $true
        Write-Step 'ERROR' ("Entree menu absente : " + $entry)
    }
}
$vestyPath = Join-Path $RepoRoot 'theme\restor-pc\assets\win_vesty.png'
$vestyHash = (Get-FileHash -LiteralPath $vestyPath -Algorithm SHA256).Hash.ToUpperInvariant()
if ([string]$info.ExpectedVestySha256 -ne $vestyHash) {
    $failed = $true
    Write-Step 'ERROR' 'ExpectedVestySha256 ne correspond pas a win_vesty.png.'
}

$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$lineNo = 0
foreach ($raw in @(Get-Content -LiteralPath $integrityPath)) {
    $lineNo++
    $line = [string]$raw
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -notmatch '^[0-9A-Fa-f]{64}  .+\\.+') {
        $failed = $true
        Write-Step 'ERROR' ("Ligne invalide {0}" -f $lineNo)
        continue
    }
    $hash = $line.Substring(0, 64).ToUpperInvariant()
    $relative = $line.Substring(66).Trim()
    if ($relative.Contains('..') -or $relative.StartsWith('\') -or $relative -match '^[A-Za-z]:') {
        $failed = $true
        Write-Step 'ERROR' ("Path traversal refuse : {0}" -f $relative)
        continue
    }
    if (-not $seen.Add($relative)) {
        $failed = $true
        Write-Step 'ERROR' ("Chemin duplique : {0}" -f $relative)
        continue
    }
    $full = Join-Path $RepoRoot $relative
    $fullResolved = [IO.Path]::GetFullPath($full)
    if (-not $fullResolved.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $failed = $true
        Write-Step 'ERROR' ("Chemin hors depot : {0}" -f $relative)
        continue
    }
    if (-not (Test-Path -LiteralPath $fullResolved -PathType Leaf)) {
        $failed = $true
        Write-Step 'ERROR' ("Fichier absent : {0}" -f $relative)
        continue
    }
    $actual = (Get-FileHash -LiteralPath $fullResolved -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $hash) {
        $failed = $true
        Write-Step 'ERROR' ("Hash modifie : {0}" -f $relative)
    }
}

if ([int]$info.Files -ne $seen.Count) {
    $failed = $true
    Write-Step 'ERROR' ("Files={0} mais manifeste={1}" -f $info.Files, $seen.Count)
}

if ($failed) {
    Write-Step 'ERROR' 'Release integrity FAILED'
    exit 1
}
Write-Step 'OK' 'Release integrity VALID'
exit 0
