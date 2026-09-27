<#
.SYNOPSIS
  Cree un VHDX vierge, reconstruit le layout RESTOR-PC et valide la recovery.
#>
[CmdletBinding()]
param(
    [switch]$KeepLab
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$labRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'test\vhd\full-recovery-lab'))
$vhdPath = Join-Path $labRoot 'restor-full-recovery.vhdx'
$logPath = Join-Path $labRoot 'logs\orchestrator.log'
$reportPath = Join-Path $labRoot 'RECOVERY-RESULT.json'
$PhysicalModel = 'SAMSUNG MZVLB256HAHQ-000L2'

function Write-OrchestratorStep {
    param([string]$Level, [string]$Message)
    $line = "[{0}] {1}" -f $Level, $Message
    Write-Host $line
    $parent = Split-Path -Parent $logPath
    if ($parent -and (Test-Path -LiteralPath $parent)) {
        Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
    }
}

function Assert-RestorAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'PowerShell administrateur requis.'
    }
}

function Assert-RestorLabCleanupPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $expected = [IO.Path]::GetFullPath((Join-Path $repoRoot 'test\vhd\full-recovery-lab'))
    if (-not $full.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'Nettoyage hors du laboratoire refuse.' }
    return $full
}

function Assert-RestorVirtualLabDisk {
    param([Parameter(Mandatory)][string]$VhdPath, [Parameter(Mandatory)][int]$DiskNumber)
    $full = [IO.Path]::GetFullPath($VhdPath)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'VHDX absent.' }
    $image = Get-DiskImage -ImagePath $full
    if (-not $image.Attached) { throw 'VHDX non attache.' }
    $associated = Get-DiskImage -ImagePath $full | Get-Disk
    if ([int]$associated.Number -ne $DiskNumber) { throw 'DiskNumber different du disque associe au VHDX.' }
    if ([bool]$associated.IsBoot) { throw 'Disque de demarrage refuse.' }
    if ([bool]$associated.IsSystem) { throw 'Disque systeme refuse.' }
    if ([string]$associated.FriendlyName -eq $PhysicalModel) { throw 'PHYSICAL RESTOR-PC NVME BLOCKED' }
    return $associated
}

function Dismount-RestorLabVhd {
    if (-not (Test-Path -LiteralPath $vhdPath -PathType Leaf)) { return }
    $image = Get-DiskImage -ImagePath $vhdPath -ErrorAction SilentlyContinue
    if ($image -and $image.Attached) {
        Dismount-DiskImage -ImagePath $vhdPath | Out-Null
        Write-OrchestratorStep 'OK' 'VHDX demonte.'
    }
    $after = Get-DiskImage -ImagePath $vhdPath -ErrorAction SilentlyContinue
    if ($after -and $after.Attached) { throw 'Le VHDX est encore attache.' }
}

function Get-RestorVhdBackend {
    if (Get-Command -Name New-VHD -ErrorAction SilentlyContinue) { return 'New-VHD' }
    foreach ($candidate in @(
        'C:\Program Files\qemu\qemu-img.exe',
        'C:\Program Files (x86)\qemu\qemu-img.exe'
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $command = Get-Command -Name qemu-img.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 requis.' }
if (-not $IsWindows) { throw 'Windows requis.' }
foreach ($commandName in @('Mount-DiskImage', 'Get-DiskImage')) {
    if (-not (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) { throw ("Commande absente : " + $commandName) }
}
if (-not (Get-Module -ListAvailable -Name Storage)) { throw 'Module Storage absent.' }
Assert-RestorAdministrator

$failed = $false
try {
    New-Item -ItemType Directory -Path (Join-Path $labRoot 'logs') -Force | Out-Null
    if (Test-Path -LiteralPath $vhdPath) {
        $existing = Get-DiskImage -ImagePath $vhdPath -ErrorAction SilentlyContinue
        if ($existing -and $existing.Attached) { Dismount-DiskImage -ImagePath $vhdPath | Out-Null }
        Remove-Item -LiteralPath $vhdPath -Force
    }
    $backend = Get-RestorVhdBackend
    if (-not $backend) { throw 'No supported VHDX creation backend available' }
    if ($backend -eq 'New-VHD') {
        New-VHD -Path $vhdPath -SizeBytes 80GB -Dynamic | Out-Null
    } else {
        & $backend create -f vhdx $vhdPath 80G
        if ($LASTEXITCODE -ne 0) { throw 'qemu-img n a pas pu creer le VHDX.' }
    }
    Write-OrchestratorStep 'OK' 'blank VHD created'
    Mount-DiskImage -ImagePath $vhdPath | Out-Null
    $disk = Get-DiskImage -ImagePath $vhdPath | Get-Disk
    $disk = Assert-RestorVirtualLabDisk -VhdPath $vhdPath -DiskNumber ([int]$disk.Number)
    Write-OrchestratorStep 'OK' 'associated disk proven'
    Write-OrchestratorStep 'OK' 'IsBoot false'
    Write-OrchestratorStep 'OK' 'IsSystem false'
    Write-OrchestratorStep 'OK' 'physical model blocked'

    Import-Module (Join-Path $repoRoot 'scripts\lib\RestorPc.Common.psm1') -Force
    Import-Module (Join-Path $repoRoot 'scripts\lib\RestorPc.Backup.psm1') -Force
    . (Join-Path $repoRoot 'tests\Helpers\TestFixture.ps1')
    $golden = New-RestorTestGoldenBackup -Root (Join-Path $labRoot 'golden') -RepoRoot $repoRoot
    Write-OrchestratorStep 'OK' 'backup integrity valid'

    $model = [string]$disk.FriendlyName
    if ([string]::IsNullOrWhiteSpace($model)) { $model = 'Msft Virtual Disk' }
    $serial = ConvertTo-NormalizedSerial ([string]$disk.SerialNumber)
    & (Join-Path $PSScriptRoot 'New-RestorRecoveryDisk.ps1') `
        -DiskNumber ([int]$disk.Number) `
        -BackupPath $golden `
        -ExpectedModel $model `
        -ExpectedSerial $serial `
        -Apply `
        -ConfirmRebuild 'REBUILD-RESTOR-PC' `
        -ResultPath $reportPath

    if (-not (Test-Path -LiteralPath $reportPath)) { throw 'RECOVERY-RESULT.json absent.' }
    $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$report.Status -ne 'VALID') { throw 'Le rapport de recovery n est pas VALID.' }
    Write-OrchestratorStep 'OK' 'recovery report VALID'

    $versions = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'config\ToolVersions.psd1')
    Import-Module Pester -RequiredVersion $versions.Pester -Force
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path $repoRoot 'tests\Integration\FullRecovery.Tests.ps1'
    $configuration.Run.PassThru = $true
    $configuration.Run.Exit = $false
    $configuration.Filter.Tag = @('VHD')
    $configuration.Output.Verbosity = 'Detailed'
    $result = Invoke-Pester -Configuration $configuration
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { throw 'Tests Full Recovery VHD en echec.' }
} catch {
    $failed = $true
    Write-OrchestratorStep 'ERROR' $_.Exception.Message
} finally {
    try { Dismount-RestorLabVhd } catch { Write-OrchestratorStep 'ERROR' $_.Exception.Message; $failed = $true }
    if (-not $failed -and -not $KeepLab) {
        $cleanup = Assert-RestorLabCleanupPath -Path $labRoot
        if (Test-Path -LiteralPath $cleanup) { Remove-Item -LiteralPath $cleanup -Recurse -Force }
        Write-OrchestratorStep 'OK' 'Laboratoire recovery supprime.'
    } elseif ($KeepLab) {
        Write-OrchestratorStep 'INFO' ("Laboratoire conserve, VHDX demonte : " + $labRoot)
    }
}

if ($failed) { exit 1 }
Write-Host '[OK] full recovery lab passed'
exit 0
