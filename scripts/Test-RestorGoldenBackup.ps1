<#
.SYNOPSIS
  Vérifie un Golden Backup RESTOR-PC sans toucher au NVMe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BackupPath,
    [string]$ExpectedVestySha256 = 'CC67BBF03D668EE61DE3A4F620C3855DF4D2430F2D2BCB473658CF1CE53331F6'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]

function Write-Step {
    param([string]$Level, [string]$Message)
    Write-Host ("[{0}] {1}" -f $Level, $Message)
}

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message)
    Write-Step 'ERROR' $Message
}

$root = [IO.Path]::GetFullPath($BackupPath)
$infoPath = Join-Path $root 'BACKUP-INFO.json'
$manifestPath = Join-Path $root 'Manifests\SHA256-MANIFEST.txt'
if (-not (Test-Path -LiteralPath $infoPath)) { Add-Failure 'BACKUP-INFO.json absent.' }
if (-not (Test-Path -LiteralPath $manifestPath)) { Add-Failure 'SHA256-MANIFEST.txt absent.' }
if ($failures.Count -gt 0) {
    Write-Step 'ERROR' 'GOLDEN BACKUP INVALID'
    exit 1
}

$info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$info.Status -ne 'VALID') { Add-Failure ("Status du backup : " + $info.Status) }
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToUpperInvariant()
if ([string]$info.ManifestSha256 -ne $manifestHash) { Add-Failure 'ManifestSha256 ne correspond pas au fichier manifeste.' }
else { Write-Step 'OK' ("Manifest SHA256 " + $manifestHash) }

$lines = @(Get-Content -LiteralPath $manifestPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$sorted = @($lines | Sort-Object { $_.Substring(66) })
if (($lines -join "`n") -ne ($sorted -join "`n")) { Add-Failure 'Le manifeste n''est pas trié.' }
$seen = @{}
foreach ($line in $lines) {
    if ($line -notmatch '^([A-F0-9]{64})  (.+)$') { Add-Failure ("Ligne manifeste illisible : " + $line); continue }
    $expected = $Matches[1]
    $relative = $Matches[2]
    if ($seen.ContainsKey($relative)) { Add-Failure ("Doublon manifeste : " + $relative) }
    $seen[$relative] = $true
    $full = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $full)) { Add-Failure ("Fichier absent : " + $relative); continue }
    $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $expected) { Add-Failure ("Fichier modifié : " + $relative) }
}
$onDisk = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($root.Length).TrimStart('\') })
foreach ($relative in $onDisk) {
    if ($relative -eq 'Manifests\SHA256-MANIFEST.txt' -or $relative -eq 'BACKUP-INFO.json') { continue }
    if (-not $seen.ContainsKey($relative)) { Add-Failure ("Fichier hors manifeste : " + $relative) }
}
if ($failures.Count -eq 0) { Write-Step 'OK' ("Manifeste vérifié, {0} fichiers." -f $seen.Count) }

foreach ($required in @(
    'ESP\RESTOR-BOOT\EFI\BOOT\refind.conf',
    'ESP\RESTOR-BOOT\EFI\BOOT\BOOTX64.EFI',
    'ESP\CODE-EFI',
    'ESP\VESTY-EFI',
    'ESP\RESCUE-EFI',
    'ESP\LOCKPICK-EFI\EFI\BOOT\BOOTX64.EFI',
    'BCD\CODE-EFI\BCD',
    'BCD\VESTY-EFI\BCD',
    'BCD\RESCUE-EFI\BCD',
    'Metadata\NVME-IDENTITY.txt',
    'Metadata\PARTITION-LAYOUT.json',
    'Metadata\REFIND-CONFIG.txt',
    'Metadata\GIT-STATE.txt'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $required))) { Add-Failure ("Structure absente : " + $required) }
}
$vesty = Join-Path $root 'ESP\RESTOR-BOOT\EFI\BOOT\themes\restor-pc\assets\win_vesty.png'
if (-not (Test-Path -LiteralPath $vesty)) { Add-Failure 'win_vesty.png absent de la copie RESTOR-BOOT.' }
else {
    $hash = (Get-FileHash -LiteralPath $vesty -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($hash -ne $ExpectedVestySha256.ToUpperInvariant()) { Add-Failure ("WIN VESTY SHA256 " + $hash) }
    else { Write-Step 'OK' 'WIN VESTY hash confirmé.' }
}
$configPath = Join-Path $root 'ESP\RESTOR-BOOT\EFI\BOOT\refind.conf'
if (Test-Path -LiteralPath $configPath) {
    $configText = [IO.File]::ReadAllText($configPath)
    foreach ($entryName in @('WIN CODE', 'WIN VESTY', 'MEMTEST86+', 'RESCUEGRID', 'LOCKPICK')) {
        $count = ([regex]::Matches($configText, [regex]::Escape('menuentry "' + $entryName + '"'))).Count
        if ($count -ne 1) { Add-Failure ("Entrée {0} présente {1} fois." -f $entryName, $count) }
    }
}
$bootWim = Join-Path $root 'RESTOR-TOOLS\RescueGrid\WinPE\boot.wim'
if (-not (Test-Path -LiteralPath $bootWim)) { Add-Failure 'boot.wim RescueGrid absent de la sauvegarde.' }

if ($failures.Count -gt 0) {
    Write-Step 'ERROR' 'GOLDEN BACKUP INVALID'
    exit 1
}
Write-Step 'OK' 'GOLDEN BACKUP VALID'
exit 0
