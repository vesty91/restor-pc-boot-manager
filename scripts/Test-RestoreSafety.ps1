<#
.SYNOPSIS
  Contrôle statique du dry-run et des commandes de partitionnement.
  N'exécute ni Backup, ni Restore, ni Get-Disk.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$failed = $false
$blockedCommands = @(
    'Clear-Disk',
    'Initialize-Disk',
    'Remove-Partition',
    'Resize-Partition',
    'New-Partition',
    'Format-Volume',
    'diskpart',
    'diskpart.exe'
)

function Get-ScriptAst {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and @($parseErrors).Count -gt 0) {
        throw ("Syntaxe invalide : " + $Path)
    }
    return $ast
}

function Test-BlockedCommands {
    param([string]$Path, $Ast)
    $commands = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))
    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($blockedCommands -contains $name) {
            $script:failed = $true
            Write-Host ("[ERROR] {0} ligne {1} exécute {2}." -f (Split-Path -Leaf $Path), $command.Extent.StartLineNumber, $name)
        }
        if (@('Invoke-Expression', 'iex') -contains $name) {
            $script:failed = $true
            Write-Host ("[ERROR] {0} ligne {1} utilise Invoke-Expression." -f (Split-Path -Leaf $Path), $command.Extent.StartLineNumber)
        }
    }
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

function Test-WriteGate {
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
    if ($comparison.Left.VariablePath.UserPath -ne 'ConfirmRestore') { return $false }
    if ($comparison.Right -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
    return $comparison.Right.Value -eq 'RESTOR-PC'
}

$names = @(
    'Backup-RestorBootManager.ps1',
    'Test-RestorGoldenBackup.ps1',
    'Restore-RestorBootManager.ps1'
)
$asts = @{}
foreach ($name in $names) {
    $path = Join-Path $repoRoot ('scripts\' + $name)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host ("[ERROR] Script absent : {0}" -f $name)
        exit 1
    }
    $ast = Get-ScriptAst -Path $path
    $asts[$name] = $ast
    Test-BlockedCommands -Path $path -Ast $ast
}

$restoreAst = $asts['Restore-RestorBootManager.ps1']
$gate = @($restoreAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$writeAllowed' -and
    (Test-WriteGate -Expression $node.Right)
}, $true))
if ($gate.Count -ne 1) {
    $failed = $true
    Write-Host '[ERROR] Restore doit n''autoriser l''écriture que si -Apply et -ConfirmRestore RESTOR-PC.'
}

$dryRunExit = $null
foreach ($exitNode in @($restoreAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ExitStatementAst]
}, $true))) {
    $parent = $exitNode.Parent
    while ($null -ne $parent -and $parent -isnot [System.Management.Automation.Language.IfStatementAst]) {
        $parent = $parent.Parent
    }
    if ($null -eq $parent) { continue }
    foreach ($clause in @($parent.Clauses)) {
        $ownsExit = $exitNode.Extent.StartOffset -ge $clause.Item2.Extent.StartOffset -and $exitNode.Extent.EndOffset -le $clause.Item2.Extent.EndOffset
        if (-not $ownsExit) { continue }
        $condition = Get-InnerExpression -Expression $clause.Item1
        $isDryRun = $condition -is [System.Management.Automation.Language.UnaryExpressionAst] -and
            [string]$condition.TokenKind -eq 'Not' -and
            $condition.Child -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $condition.Child.VariablePath.UserPath -eq 'writeAllowed'
        if ($isDryRun) { $dryRunExit = $exitNode }
    }
}
if ($null -eq $dryRunExit) {
    foreach ($stopNode in @($restoreAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Exit-RestorCommand'
    }, $true))) {
        $parent = $stopNode.Parent
        while ($null -ne $parent -and $parent -isnot [System.Management.Automation.Language.IfStatementAst]) {
            $parent = $parent.Parent
        }
        if ($null -eq $parent) { continue }
        foreach ($clause in @($parent.Clauses)) {
            $ownsStop = $stopNode.Extent.StartOffset -ge $clause.Item2.Extent.StartOffset -and $stopNode.Extent.EndOffset -le $clause.Item2.Extent.EndOffset
            if (-not $ownsStop) { continue }
            $condition = Get-InnerExpression -Expression $clause.Item1
            $isDryRun = $condition -is [System.Management.Automation.Language.UnaryExpressionAst] -and
                [string]$condition.TokenKind -eq 'Not' -and
                $condition.Child -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $condition.Child.VariablePath.UserPath -eq 'writeAllowed'
            $stopsWithZero = $stopNode.Extent.Text -match '-Code\s+0'
            if ($isDryRun -and $stopsWithZero) { $dryRunExit = $stopNode }
        }
    }
}
$stopFunction = Join-Path $repoRoot 'scripts\lib\RestorPc.Common.psm1'
if (-not (Test-Path -LiteralPath $stopFunction -PathType Leaf)) {
    $failed = $true
    Write-Host '[ERROR] RestorPc.Common.psm1 est absent.'
} else {
    $moduleAst = Get-ScriptAst -Path $stopFunction
    $functionNode = @($moduleAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Exit-RestorCommand'
    }, $true))
    $moduleExit = @()
    if ($functionNode.Count -eq 1) {
        $moduleExit = @($functionNode[0].Body.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ExitStatementAst]
        }, $true))
    }
    if ($functionNode.Count -ne 1 -or $moduleExit.Count -lt 1) {
        $failed = $true
        Write-Host '[ERROR] Exit-RestorCommand doit encore appeler exit hors du mode de test.'
    }
}
if ($null -eq $dryRunExit) {
    $failed = $true
    Write-Host '[ERROR] Le dry-run doit quitter avant toute écriture quand -Apply ou la confirmation manque.'
}

if ($null -ne $dryRunExit) {
    $writeCommands = @($restoreAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        @('robocopy.exe', 'robocopy', 'Add-PartitionAccessPath') -contains $node.GetCommandName()
    }, $true))
    foreach ($writeCommand in $writeCommands) {
        if ($writeCommand.Extent.StartOffset -le $dryRunExit.Extent.EndOffset) {
            $failed = $true
            Write-Host ("[ERROR] {0} est atteint sans passer par le dry-run." -f $writeCommand.GetCommandName())
        }
    }
}

if ($failed) { exit 1 }
Write-Host '[OK] restore safety valid'
exit 0
