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
Import-Module (Join-Path $PSScriptRoot 'lib\RestorPc.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\RestorPc.Backup.psm1') -Force

function Write-Step {
    param([string]$Level, [string]$Message)
    Write-Host ("[{0}] {1}" -f $Level, $Message)
}

$result = Test-RestorBackupIntegrity -BackupPath $BackupPath -ExpectedVestySha256 $ExpectedVestySha256
foreach ($failure in @($result.Failures)) {
    Write-Step 'ERROR' ([string]$failure)
}
if ($result.ManifestHashValid) {
    Write-Step 'OK' ("Manifest SHA256 " + $result.ManifestSha256Actual)
}
if ($result.VestyHashValid) {
    Write-Step 'OK' 'WIN VESTY hash confirmé.'
}
if ($result.Valid) {
    Write-Step 'OK' ("Manifeste vérifié, {0} fichiers." -f $result.FilesVerified)
    Write-Step 'OK' 'GOLDEN BACKUP VALID'
    Exit-RestorCommand -Code 0
}
Write-Step 'ERROR' 'GOLDEN BACKUP INVALID'
Exit-RestorCommand -Code 1
