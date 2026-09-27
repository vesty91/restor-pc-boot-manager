<#
.SYNOPSIS
  Cree un VHDX, lance le restore production en -Apply, puis demonte le disque.
#>
[CmdletBinding()]
param(
    [switch]$KeepLab
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$labRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'test\vhd\restore-lab'))
$vhdPath = Join-Path $labRoot 'restor-restore-lab.vhdx'
$logPath = Join-Path $labRoot 'logs\orchestrator.log'
$script:LabMounted = $false

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
    if ($full.Contains('..')) { throw 'Nettoyage refuse.' }
    $expected = [IO.Path]::GetFullPath((Join-Path $repoRoot 'test\vhd\restore-lab'))
    if (-not $full.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { throw 'Nettoyage hors du laboratoire refuse.' }
    $root = [IO.Path]::GetPathRoot($full).TrimEnd('\')
    if ($full.TrimEnd('\') -eq $root) { throw 'Nettoyage de la racine refuse.' }
    if ($full.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Nettoyage du depot refuse.' }
    $testRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'test'))
    if ($full.Equals($testRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Nettoyage de test\ refuse.' }
    return $full
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
    $script:LabMounted = $false
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
    & (Join-Path $PSScriptRoot 'New-RestorVirtualLab.ps1') -LabRoot $labRoot
    $script:LabMounted = $true
    $versions = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'config\ToolVersions.psd1')
    Import-Module Pester -RequiredVersion $versions.Pester -Force
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path $repoRoot 'tests\Integration\VirtualApply.Tests.ps1'
    $configuration.Run.PassThru = $true
    $configuration.Run.Exit = $false
    $configuration.Filter.Tag = @('VHD')
    $configuration.Output.Verbosity = 'Detailed'
    $result = Invoke-Pester -Configuration $configuration
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { throw 'Tests VHD en echec.' }
    $reportPath = Join-Path $labRoot 'RESTORE-REPORT.json'
    if (-not (Test-Path -LiteralPath $reportPath)) { throw 'RESTORE-REPORT.json absent.' }
    $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$report.Status -ne 'VALID') { throw 'Le rapport de restore n est pas VALID.' }
    Write-OrchestratorStep 'OK' 'Rapport VALID.'
} catch {
    $failed = $true
    Write-OrchestratorStep 'ERROR' $_.Exception.Message
} finally {
    try { Dismount-RestorLabVhd } catch { Write-OrchestratorStep 'ERROR' $_.Exception.Message; $failed = $true }
    if (-not $failed -and -not $KeepLab) {
        $cleanup = Assert-RestorLabCleanupPath -Path $labRoot
        if (Test-Path -LiteralPath $cleanup) { Remove-Item -LiteralPath $cleanup -Recurse -Force }
        Write-OrchestratorStep 'OK' 'Laboratoire supprime.'
    } elseif ($KeepLab) {
        Write-OrchestratorStep 'INFO' ("Laboratoire conserve, VHDX demonte : " + $labRoot)
    }
}

if ($failed) { exit 1 }
Write-Host '[OK] virtual restore lab passed'
exit 0
