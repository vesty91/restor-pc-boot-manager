<#
.SYNOPSIS
  Lance les tests Pester hors materiel.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$versions = Import-PowerShellDataFile -Path (Join-Path $repoRoot 'config\ToolVersions.psd1')
$outputRoot = Join-Path $repoRoot 'tests-output'
if (-not (Test-Path -LiteralPath $outputRoot)) {
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
}

try {
    Import-Module Pester -RequiredVersion $versions.Pester -Force -ErrorAction Stop
} catch {
    Write-Host ("[ERROR] Pester {0} est introuvable. Installez la version pinnee dans config\ToolVersions.psd1." -f $versions.Pester)
    Write-Host ("[ERROR] {0}" -f $_.Exception.Message)
    exit 1
}

$loaded = Get-Module Pester | Select-Object -First 1
Write-Host ("Pester version : {0}" -f $loaded.Version)
Write-Host ("PowerShell : {0}" -f $PSVersionTable.PSVersion)

$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $repoRoot 'tests'
$configuration.Run.PassThru = $true
$configuration.Run.Exit = $false
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = Join-Path $outputRoot 'TestResults.xml'
$configuration.TestResult.OutputFormat = 'NUnitXml'
$configuration.CodeCoverage.Enabled = $true
$configuration.CodeCoverage.Path = @(
    (Join-Path $repoRoot 'scripts\lib\RestorPc.Common.psm1'),
    (Join-Path $repoRoot 'scripts\Test-RestorGoldenBackup.ps1'),
    (Join-Path $repoRoot 'scripts\Restore-RestorBootManager.ps1')
)
$configuration.CodeCoverage.OutputFormat = 'JaCoCo'
$configuration.CodeCoverage.OutputPath = Join-Path $outputRoot 'coverage.xml'

$result = Invoke-Pester -Configuration $configuration
$coverage = $null
if ($null -ne $result.CodeCoverage) {
    $coverage = $result.CodeCoverage.CoveragePercent
}
$summary = [ordered]@{
    Total    = [int]$result.TotalCount
    Passed   = [int]$result.PassedCount
    Failed   = [int]$result.FailedCount
    Skipped  = [int]$result.SkippedCount
    Coverage = $coverage
}
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'pester-summary.json') -Encoding utf8

Write-Host ("Tests total : {0}" -f $summary.Total)
Write-Host ("Passed : {0}" -f $summary.Passed)
Write-Host ("Failed : {0}" -f $summary.Failed)
Write-Host ("Skipped : {0}" -f $summary.Skipped)
if ($null -eq $coverage) {
    Write-Host 'Coverage : n/a'
} else {
    Write-Host ("Coverage : {0:N1} %" -f $coverage)
}

if ($summary.Failed -gt 0 -or $result.Result -ne 'Passed') {
    Write-Host '[ERROR] Pester behavioral tests'
    exit 1
}
Write-Host '[OK] Pester behavioral tests'
exit 0
