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

$patterns = @(
    'config\refind.conf',
    'scripts\Backup-RestorBootManager.ps1',
    'scripts\Restore-RestorBootManager.ps1',
    'scripts\New-RestorRecoveryDisk.ps1',
    'scripts\Build-RestorRecoveryMedia.ps1',
    'scripts\Test-RestorGoldenBackup.ps1',
    'scripts\Test-ReleaseIntegrity.ps1',
    'scripts\New-ReleaseIntegrityManifest.ps1',
    'scripts\lib\RestorPc.Common.psm1',
    'scripts\lib\RestorPc.Backup.psm1',
    'theme\restor-pc\assets\win_code.png',
    'theme\restor-pc\assets\win_vesty.png',
    'theme\restor-pc\assets\memtest86plus.png',
    'theme\restor-pc\assets\rescuegrid.png',
    'theme\restor-pc\assets\lockpick.png',
    'docs\BACKUP-RESTORE.md',
    'docs\DISASTER-RECOVERY.md',
    'docs\TEST-MATRIX.md',
    'docs\releases\v1.3.0.md'
)

$lines = New-Object System.Collections.Generic.List[string]
$fileCount = 0
foreach ($relative in ($patterns | Sort-Object)) {
    $full = Join-Path $repoRoot $relative
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpperInvariant()
    $normalized = $relative -replace '/', '\'
    $lines.Add(("{0}  {1}" -f $hash, $normalized))
    $fileCount++
}

$utf8 = New-Object System.Text.UTF8Encoding $false
$integrityPath = Join-Path $releaseDir 'RELEASE-INTEGRITY.txt'
[IO.File]::WriteAllLines($integrityPath, [string[]]$lines.ToArray(), $utf8)

if ([string]::IsNullOrWhiteSpace($SourceCommit)) {
    $SourceCommit = 'pending-release-tag'
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
