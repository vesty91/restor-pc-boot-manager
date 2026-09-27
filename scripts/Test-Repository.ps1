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
        'pwsh -NoProfile -File .\scripts\Test-Repository.ps1'
    )
    foreach ($needle in $workflowNeedles) {
        if ($workflow.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
            $failed = $true
            Write-Host ("[ERROR] ci.yml ne contient pas : {0}" -f $needle)
        }
    }
}

$analyzer = Get-Module -ListAvailable -Name PSScriptAnalyzer
if (-not $analyzer) {
    Write-Host '[WARN] PSScriptAnalyzer absent. Les règles de sévérité Error ne sont pas évaluées.'
} else {
    Import-Module PSScriptAnalyzer
    $results = @(Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot 'scripts') -Recurse -Severity @('Error', 'Warning'))
    foreach ($result in $results) {
        if ([string]$result.Severity -eq 'Warning') {
            Write-Host ("[WARN] {0}:{1} {2} {3}" -f $result.ScriptName, $result.Line, $result.RuleName, $result.Message)
        }
    }
    $errors = @($results | Where-Object { [string]$_.Severity -eq 'Error' })
    foreach ($result in $errors) {
        $failed = $true
        Write-Host ("[ERROR] {0}:{1} {2} {3}" -f $result.ScriptName, $result.Line, $result.RuleName, $result.Message)
    }
}

if ($failed) { exit 1 }
Write-Host '[OK] RESTOR-PC repository validation passed'
exit 0
