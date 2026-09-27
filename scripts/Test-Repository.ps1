<#
.SYNOPSIS
  Lance toute la validation statique du dépôt. Aucun disque, aucun QEMU, aucun Restore -Apply.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runner = (Get-Process -Id $PID).Path
$failed = $false

$steps = @(
    @{ Name = 'PowerShell syntax'; Script = 'Test-PowerShellSyntax.ps1' },
    @{ Name = 'rEFInd config'; Script = 'Test-RefindConfig.ps1' },
    @{ Name = 'theme assets'; Script = 'Test-ThemeAssets.ps1' },
    @{ Name = 'QEMU safety'; Script = 'Test-QemuSafety.ps1' },
    @{ Name = 'repository safety'; Script = 'Test-RepositorySafety.ps1' },
    @{ Name = 'restore safety'; Script = 'Test-RestoreSafety.ps1' }
)

foreach ($step in $steps) {
    $scriptPath = Join-Path $PSScriptRoot $step.Script
    & $runner -NoProfile -File $scriptPath
    if ($LASTEXITCODE -ne 0) {
        $failed = $true
        Write-Host ("[ERROR] " + $step.Name)
    } else {
        Write-Host ("[OK] " + $step.Name)
    }
}

$readmePath = Join-Path $repoRoot 'README.md'
$workflowPath = Join-Path $repoRoot '.github\workflows\ci.yml'
$docPaths = @(
    'CHANGELOG.md',
    'docs\releases\v1.1.0.md',
    'docs\BACKUP-RESTORE.md',
    'Lockpick\README.md',
    'README.md',
    '.github\workflows\ci.yml'
)
foreach ($relative in $docPaths) {
    $path = Join-Path $repoRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failed = $true
        Write-Host ("[ERROR] Documentation absente : {0}" -f $relative)
    }
}
if (Test-Path -LiteralPath $readmePath -PathType Leaf) {
    $readme = Get-Content -LiteralPath $readmePath -Raw
    $readmeNeedles = @(
        'Latest stable release: v1.1.0',
        'docs/releases/v1.1.0.md',
        'docs/BACKUP-RESTORE.md',
        'Lockpick/README.md',
        '## CI / Validation',
        'pwsh -NoProfile -File .\scripts\Test-Repository.ps1',
        'RESTOR-PC CI',
        '.github/workflows/ci.yml'
    )
    foreach ($needle in $readmeNeedles) {
        if ($readme.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
            $failed = $true
            Write-Host ("[ERROR] README.md ne contient pas : {0}" -f $needle)
        }
    }
}
if (Test-Path -LiteralPath $workflowPath -PathType Leaf) {
    $workflow = Get-Content -LiteralPath $workflowPath -Raw
    $workflowNeedles = @(
        'name: RESTOR-PC CI',
        'windows-latest',
        'workflow_dispatch',
        'permissions:',
        'contents: read',
        'concurrency:',
        'cancel-in-progress: true',
        'timeout-minutes: 15',
        'actions/checkout@v7',
        'pwsh -NoProfile -File .\scripts\Test-Repository.ps1'
    )
    foreach ($needle in $workflowNeedles) {
        if ($workflow.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
            $failed = $true
            Write-Host ("[ERROR] ci.yml ne contient pas : {0}" -f $needle)
        }
    }
}

$analyzer = @(Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending)
if ($analyzer.Count -eq 0) {
    $failed = $true
    Write-Host '[ERROR] PSScriptAnalyzer absent. Les portes de qualité ne peuvent pas être évaluées.'
    Write-Host '[ERROR] PSScriptAnalyzer critical rules'
} else {
    Write-Host ("PSScriptAnalyzer version : {0}" -f $analyzer[0].Version)
    Import-Module PSScriptAnalyzer
    $settingsPath = Join-Path $repoRoot 'config\PSScriptAnalyzerSettings.psd1'
    $results = @(Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot 'scripts') -Recurse -Settings $settingsPath -Severity @('Error', 'Warning'))
    $analyzerErrors = @($results | Where-Object { [string]$_.Severity -eq 'Error' })
    $warnings = @($results | Where-Object { [string]$_.Severity -eq 'Warning' })
    Write-Host 'PSScriptAnalyzer:'
    Write-Host ("Errors   : {0}" -f $analyzerErrors.Count)
    Write-Host ("Warnings : {0}" -f $warnings.Count)
    $warnings | Group-Object RuleName | Sort-Object Count -Descending | ForEach-Object {
        Write-Host ("  {0} {1}" -f $_.Count, $_.Name)
    }
    $analyzerFailed = $false
    foreach ($result in $analyzerErrors) {
        $failed = $true
        $analyzerFailed = $true
        Write-Host ("[ERROR] {0}:{1} {2} {3}" -f $result.ScriptName, $result.Line, $result.RuleName, $result.Message)
    }
    $criticalRules = @(
        'PSAvoidUsingEmptyCatchBlock',
        'PSAvoidAssignmentToAutomaticVariable',
        'PSReviewUnusedParameter'
    )
    foreach ($ruleName in $criticalRules) {
        $hits = @($results | Where-Object { $_.RuleName -eq $ruleName })
        if ($hits.Count -gt 0) {
            $failed = $true
            $analyzerFailed = $true
            foreach ($hit in $hits) {
                Write-Host ("[ERROR] {0}:{1} {2}" -f $hit.ScriptName, $hit.Line, $hit.RuleName)
            }
        }
    }
    if ($analyzerFailed) {
        Write-Host '[ERROR] PSScriptAnalyzer critical rules'
    } else {
        Write-Host '[OK] PSScriptAnalyzer critical rules'
    }
}

if ($failed) { exit 1 }
Write-Host '[OK] RESTOR-PC repository validation passed'
exit 0
