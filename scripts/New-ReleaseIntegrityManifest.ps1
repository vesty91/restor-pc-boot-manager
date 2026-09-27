<#
.SYNOPSIS
  Genere release/RELEASE-INTEGRITY.txt et RELEASE-INFO.json pour les fichiers critiques versionnes.
#>
[CmdletBinding()]
param(
    [string]$Version = '1.3.0',
    [string]$SourceCommit = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseDir = Join-Path $repoRoot 'release'
New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
Import-Module (Join-Path $PSScriptRoot 'lib\RestorPc.Common.psm1') -Force

$patterns = @(Get-RestorCriticalReleaseRelativePaths)

$lines = New-Object System.Collections.Generic.List[string]
$fileCount = 0
foreach ($relative in ($patterns | Sort-Object)) {
    $full = Join-Path $repoRoot $relative
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw ("Fichier critique absent pour le manifeste de release : " + $relative)
    }
    $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpperInvariant()
    $normalized = $relative -replace '/', '\'
    $lines.Add(("{0}  {1}" -f $hash, $normalized))
    $fileCount++
}

$utf8 = New-Object System.Text.UTF8Encoding $false
$integrityPath = Join-Path $releaseDir 'RELEASE-INTEGRITY.txt'
[IO.File]::WriteAllLines($integrityPath, [string[]]$lines.ToArray(), $utf8)

if ([string]::IsNullOrWhiteSpace($SourceCommit)) {
    $SourceCommit = (git -C $repoRoot rev-parse HEAD).Trim()
}
if ([string]::IsNullOrWhiteSpace($SourceCommit) -or $SourceCommit -eq 'pending-release-tag') {
    throw 'SourceCommit invalide pour RELEASE-INFO.json.'
}
$vesty = (Get-FileHash -LiteralPath (Join-Path $repoRoot 'theme\restor-pc\assets\win_vesty.png') -Algorithm SHA256).Hash.ToUpperInvariant()
$info = [ordered]@{
    Version             = $Version
    Commit              = $SourceCommit
    GeneratedAt         = (Get-Date).ToString('o')
    Files               = $fileCount
    Algorithm           = 'SHA256'
    BootMenuEntries     = @('WIN CODE', 'WIN VESTY', 'MEMTEST86+', 'RESCUEGRID', 'LOCKPICK')
    ExpectedVestySha256 = $vesty
}
[IO.File]::WriteAllText((Join-Path $releaseDir 'RELEASE-INFO.json'), ($info | ConvertTo-Json -Depth 4), $utf8)
Write-Host ("[OK] RELEASE-INTEGRITY.txt ({0} files)" -f $fileCount)
Write-Host '[OK] RELEASE-INFO.json'
exit 0
