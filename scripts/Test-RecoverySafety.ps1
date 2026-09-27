<#
.SYNOPSIS
  Analyse statique de New-RestorRecoveryDisk et du lab Full Recovery.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$failed = $false
$recoveryScript = Join-Path $repoRoot 'scripts\New-RestorRecoveryDisk.ps1'
$labScript = Join-Path $repoRoot 'scripts\Test-FullRecovery.ps1'

function Get-ScriptAst {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and @($parseErrors).Count -gt 0) { throw ("Syntaxe invalide : " + $Path) }
    return $ast
}

function Get-InnerExpression {
    param($Expression)
    while ($null -ne $Expression) {
        if ($Expression -is [System.Management.Automation.Language.CommandExpressionAst]) {
            $Expression = $Expression.Expression
            continue
        }
        if ($Expression -is [System.Management.Automation.Language.PipelineAst]) {
            $Expression = $Expression.PipelineElements[0]
            continue
        }
        if ($Expression -is [System.Management.Automation.Language.ParenExpressionAst]) {
            $Expression = $Expression.Pipeline
            continue
        }
        break
    }
    return $Expression
}

foreach ($path in @($recoveryScript, $labScript)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host ("[ERROR] Script absent : {0}" -f $path)
        exit 1
    }
}

$forbiddenHard = @('Remove-Partition', 'Resize-Partition', '\\.\PhysicalDrive')
foreach ($path in @($recoveryScript, $labScript)) {
    $text = [IO.File]::ReadAllText($path)
    foreach ($token in $forbiddenHard) {
        if ($text.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $failed = $true
            Write-Host ("[ERROR] {0} contient {1}" -f (Split-Path -Leaf $path), $token)
        }
    }
}

$recoveryAst = Get-ScriptAst -Path $recoveryScript
$blockedInRecovery = @('Clear-Disk', 'diskpart', 'diskpart.exe', 'Remove-Partition', 'Resize-Partition')
$commands = @($recoveryAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
foreach ($command in $commands) {
    $name = $command.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    if ($blockedInRecovery -contains $name) {
        $failed = $true
        Write-Host ("[ERROR] New-RestorRecoveryDisk ligne {0} execute {1}." -f $command.Extent.StartLineNumber, $name)
    }
}

function Test-RebuildGate {
    param($Expression)
    $Expression = Get-InnerExpression -Expression $Expression
    if ($Expression -isnot [System.Management.Automation.Language.BinaryExpressionAst]) { return $false }
    if ([string]$Expression.Operator -ne 'And') { return $false }
    if ($Expression.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $false }
    if ($Expression.Left.VariablePath.UserPath -ne 'Apply') { return $false }
    $comparison = $Expression.Right
    if ($comparison -isnot [System.Management.Automation.Language.BinaryExpressionAst]) { return $false }
    if ([string]$comparison.Operator -ne 'Ceq') { return $false }
    if ($comparison.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $false }
    if ($comparison.Left.VariablePath.UserPath -ne 'ConfirmRebuild') { return $false }
    if ($comparison.Right -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
    return $comparison.Right.Value -eq 'REBUILD-RESTOR-PC'
}

$gate = @($recoveryAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$writeAllowed' -and
    (Test-RebuildGate -Expression $node.Right)
}, $true))
if ($gate.Count -ne 1) {
    $failed = $true
    Write-Host '[ERROR] Recovery doit exiger -Apply et -ConfirmRebuild REBUILD-RESTOR-PC (-ceq).'
}

$integrityCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Test-RestorBackupIntegrity' } | Sort-Object { $_.Extent.StartOffset })
$initCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'Initialize-Disk' } | Sort-Object { $_.Extent.StartOffset })
$newPartCalls = @($commands | Where-Object { $_.GetCommandName() -eq 'New-Partition' } | Sort-Object { $_.Extent.StartOffset })
if ($integrityCalls.Count -lt 1) {
    $failed = $true
    Write-Host '[ERROR] Recovery doit verifier le Golden Backup.'
} elseif ($initCalls.Count -gt 0 -and $integrityCalls[0].Extent.StartOffset -ge $initCalls[0].Extent.StartOffset) {
    $failed = $true
    Write-Host '[ERROR] Test-RestorBackupIntegrity doit preceder Initialize-Disk.'
}
if ($newPartCalls.Count -lt 1) {
    $failed = $true
    Write-Host '[ERROR] Recovery doit creer des partitions via New-Partition.'
}

$forbiddenParameter = @(
    'SkipIntegrityCheck', 'SkipIntegrity', 'IgnoreManifest', 'SkipHash',
    'ForceBackup', 'TrustBackup', 'NoVerify', 'TestMode', 'ForceClean'
)
$paramNames = @()
if ($recoveryAst.ParamBlock) {
    foreach ($parameter in @($recoveryAst.ParamBlock.Parameters)) {
        $paramNames += [string]$parameter.Name.VariablePath.UserPath
    }
}
foreach ($name in $forbiddenParameter) {
    if ($paramNames -contains $name) {
        $failed = $true
        Write-Host ("[ERROR] Recovery expose un contournement : {0}" -f $name)
    }
}

$labText = [IO.File]::ReadAllText($labScript)
foreach ($needle in @('test\vhd\full-recovery-lab', 'SAMSUNG MZVLB256HAHQ-000L2', 'PHYSICAL RESTOR-PC NVME BLOCKED', 'Assert-RestorVirtualLabDisk', 'New-RestorRecoveryDisk.ps1')) {
    if ($labText.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $failed = $true
        Write-Host ("[ERROR] Test-FullRecovery ne contient pas : {0}" -f $needle)
    }
}

$labAst = Get-ScriptAst -Path $labScript
$labDestructive = @('Initialize-Disk', 'New-Partition', 'Format-Volume', 'Clear-Disk')
$labHits = @($labAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $labDestructive -contains $node.GetCommandName()
}, $true))
if ($labHits.Count -gt 0) {
    $failed = $true
    Write-Host '[ERROR] Test-FullRecovery ne doit pas partitionner directement ; il doit appeler New-RestorRecoveryDisk.ps1.'
}

if ($failed) { exit 1 }
Write-Host '[OK] recovery safety valid'
exit 0
