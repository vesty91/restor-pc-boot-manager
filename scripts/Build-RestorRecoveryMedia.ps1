<#
.SYNOPSIS
  Construit le staging RESTOR-PC Recovery Media (et ISO WinPE si disponible).
#>
[CmdletBinding()]
param(
    [string]$OutputRoot = '',
    [string]$WinPESource = '',
    [string]$BootWim = '',
    [string]$Version = '1.3.0-rc'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot 'artifacts\recovery-media'
}
$out = [IO.Path]::GetFullPath($OutputRoot)
$repoFull = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\')
$outNormalized = $out.TrimEnd('\')
$boundary = $repoFull + [IO.Path]::DirectorySeparatorChar
if ($outNormalized.Equals($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputRoot ne peut pas etre la racine du depot.'
}
if (-not $outNormalized.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputRoot doit rester sous la racine du depot.'
}

function Write-Step {
    param([string]$Level, [string]$Message)
    Write-Host ("[{0}] {1}" -f $Level, $Message)
}

function Get-RestorFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

if (Test-Path -LiteralPath $out) {
    Remove-Item -LiteralPath $out -Recurse -Force
}
$staging = Join-Path $out 'staging'
New-Item -ItemType Directory -Path (Join-Path $staging 'scripts\lib') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $staging 'docs') -Force | Out-Null

$scriptFiles = @(
    'Test-RestorGoldenBackup.ps1',
    'Restore-RestorBootManager.ps1',
    'New-RestorRecoveryDisk.ps1',
    'Backup-RestorBootManager.ps1'
)
foreach ($name in $scriptFiles) {
    $source = Join-Path $repoRoot ('scripts\' + $name)
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ("Script absent : " + $name) }
    Copy-Item -LiteralPath $source -Destination (Join-Path $staging ('scripts\' + $name)) -Force
}

$moduleFiles = @(
    'RestorPc.Common.psm1',
    'RestorPc.Backup.psm1'
)
foreach ($name in $moduleFiles) {
    $source = Join-Path $repoRoot ('scripts\lib\' + $name)
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ("Module absent : " + $name) }
    Copy-Item -LiteralPath $source -Destination (Join-Path $staging ('scripts\lib\' + $name)) -Force
}

$docCandidates = @(
    'docs\BACKUP-RESTORE.md',
    'docs\DISASTER-RECOVERY.md',
    'docs\VIRTUAL-RESTORE-LAB.md',
    'README.md'
)
foreach ($relative in $docCandidates) {
    $source = Join-Path $repoRoot $relative
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        $destName = Split-Path -Leaf $relative
        Copy-Item -LiteralPath $source -Destination (Join-Path $staging ('docs\' + $destName)) -Force
    }
}

$launcher = @'
<#
.SYNOPSIS
  Menu RESTOR-PC Recovery. Ne contourne aucune confirmation destructive.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$scripts = Join-Path $here 'scripts'
if (-not (Test-Path -LiteralPath (Join-Path $scripts 'Restore-RestorBootManager.ps1'))) {
    $scripts = $here
}

function Show-RestorDisks {
    Get-Disk | Select-Object Number, FriendlyName, SerialNumber, BusType, PartitionStyle, Size, IsBoot, IsSystem | Format-Table -AutoSize
}

Write-Host 'RESTOR-PC Recovery Media'
Write-Host '1. Verify Golden Backup'
Write-Host '2. Restore existing RESTOR-PC layout'
Write-Host '3. Rebuild blank replacement disk'
Write-Host '4. Show disks'
Write-Host '5. Exit'
$choice = Read-Host 'Choice'
switch ($choice) {
    '1' {
        $backup = Read-Host 'BackupPath'
        & (Join-Path $scripts 'Test-RestorGoldenBackup.ps1') -BackupPath $backup
    }
    '2' {
        $backup = Read-Host 'BackupPath'
        Write-Host 'Dry-run by default. Pass -Apply -ConfirmRestore RESTOR-PC yourself if intentional.'
        & (Join-Path $scripts 'Restore-RestorBootManager.ps1') -BackupPath $backup -AllEfi
    }
    '3' {
        $backup = Read-Host 'BackupPath'
        $disk = Read-Host 'DiskNumber'
        $model = Read-Host 'ExpectedModel'
        $serial = Read-Host 'ExpectedSerial'
        Write-Host 'Dry-run by default. Pass -Apply -ConfirmRebuild REBUILD-RESTOR-PC yourself if intentional.'
        & (Join-Path $scripts 'New-RestorRecoveryDisk.ps1') -DiskNumber ([int]$disk) -BackupPath $backup -ExpectedModel $model -ExpectedSerial $serial
    }
    '4' { Show-RestorDisks }
    '5' { exit 0 }
    default { Write-Host 'Unknown choice.'; exit 1 }
}
'@
$utf8 = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $staging 'Start-RestorRecovery.ps1'), $launcher, $utf8)

$forbiddenRoots = @(
    (Join-Path $staging 'RESTOR-PC-BACKUP'),
    (Join-Path $staging 'C'),
    (Join-Path $staging 'Lockpick.iso')
)
foreach ($path in $forbiddenRoots) {
    if (Test-Path -LiteralPath $path) { throw ("Artefact interdit dans le staging : " + $path) }
}

$isoBuilt = $false
$isoPath = Join-Path $out ('RESTOR-PC-Recovery-v' + $Version + '.iso')
$oscdimg = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$hasWinPe = $false
$bootWimPath = ''
if (-not [string]::IsNullOrWhiteSpace($BootWim) -and (Test-Path -LiteralPath $BootWim -PathType Leaf)) {
    $bootWimPath = [IO.Path]::GetFullPath($BootWim)
    $hasWinPe = $true
} elseif (-not [string]::IsNullOrWhiteSpace($WinPESource)) {
    $candidate = Join-Path $WinPESource 'sources\boot.wim'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $bootWimPath = [IO.Path]::GetFullPath($candidate)
        $hasWinPe = $true
    }
}

if ($hasWinPe -and $oscdimg) {
    $adkRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $oscdimg))
    $etfsboot = Join-Path $adkRoot 'amd64\Oscdimg\etfsboot.com'
    $efisys = Join-Path $adkRoot 'amd64\Oscdimg\efisys_noprompt.bin'
    if (-not (Test-Path -LiteralPath $etfsboot)) { $etfsboot = Join-Path (Split-Path -Parent $oscdimg) 'etfsboot.com' }
    if (-not (Test-Path -LiteralPath $efisys)) { $efisys = Join-Path (Split-Path -Parent $oscdimg) 'efisys_noprompt.bin' }
    if (-not ((Test-Path -LiteralPath $etfsboot) -and (Test-Path -LiteralPath $efisys))) {
        Write-Step 'WARN' 'WinPE ISO backend incomplete: missing etfsboot/efisys boot sectors. Staging only.'
    } else {
        $isoRoot = Join-Path $out 'iso-root'
        New-Item -ItemType Directory -Path (Join-Path $isoRoot 'sources') -Force | Out-Null
        Copy-Item -LiteralPath $bootWimPath -Destination (Join-Path $isoRoot 'sources\boot.wim') -Force
        Copy-Item -LiteralPath $staging -Destination (Join-Path $isoRoot 'RestorPc') -Recurse -Force
        $bootData = ('2#p0,e,b"{0}"#pEF,e,b"{1}"' -f $etfsboot, $efisys)
        & $oscdimg ("-bootdata:$bootData") '-u2' '-udfver102' $isoRoot $isoPath
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $isoPath)) {
            $isoBuilt = $true
            Write-Step 'OK' ("ISO bootable creee : " + $isoPath)
        } else {
            Write-Step 'WARN' 'Echec oscdimg bootable. Staging conserve.'
        }
    }
} else {
    Write-Step 'WARN' 'WinPE ISO backend unavailable'
    Write-Step 'OK' 'Recovery staging created'
}

$sums = New-Object System.Collections.Generic.List[string]
Get-ChildItem -LiteralPath $out -Recurse -File | Where-Object {
    $_.Name -ne 'SHA256SUMS.txt'
} | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($out.Length).TrimStart('\')
    $sums.Add(("{0}  {1}" -f (Get-RestorFileSha256 -Path $_.FullName), $relative))
}
[IO.File]::WriteAllLines((Join-Path $out 'SHA256SUMS.txt'), [string[]]$sums.ToArray(), $utf8)
Write-Step 'OK' ("Staging : " + $staging)
Write-Step 'OK' 'SHA256SUMS valide'
if (-not $isoBuilt) {
    Write-Step 'INFO' 'ISO not built: backend unavailable'
}
exit 0
