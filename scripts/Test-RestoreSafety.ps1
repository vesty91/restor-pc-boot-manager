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

function Get-RestorCommandNode {
    param($Ast, [string]$CommandName)
    $commands = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))
    $matched = New-Object System.Collections.Generic.List[object]
    foreach ($command in $commands) {
        if ($command.GetCommandName() -eq $CommandName) { $matched.Add($command) }
    }
    return @($matched | Sort-Object { $_.Extent.StartOffset })
}

function Get-RestorAstParameterName {
    param($Ast)
    $names = New-Object System.Collections.Generic.List[string]
    $blocks = @()
    if ($Ast.ParamBlock) { $blocks += $Ast.ParamBlock }
    foreach ($functionNode in @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true))) {
        if ($functionNode.Body.ParamBlock) { $blocks += $functionNode.Body.ParamBlock }
    }
    foreach ($block in $blocks) {
        foreach ($parameter in @($block.Parameters)) {
            $names.Add([string]$parameter.Name.VariablePath.UserPath)
        }
    }
    return @($names)
}

function Test-RestorIntegrityCallInWriteGate {
    param($CommandNode)
    $parent = $CommandNode.Parent
    while ($null -ne $parent -and $parent -isnot [System.Management.Automation.Language.IfStatementAst]) {
        $parent = $parent.Parent
    }
    if ($null -eq $parent) { return $false }
    foreach ($clause in @($parent.Clauses)) {
        $ownsCommand = $CommandNode.Extent.StartOffset -ge $clause.Item2.Extent.StartOffset -and $CommandNode.Extent.EndOffset -le $clause.Item2.Extent.EndOffset
        if (-not $ownsCommand) { continue }
        $condition = Get-InnerExpression -Expression $clause.Item1
        if ($condition -is [System.Management.Automation.Language.VariableExpressionAst] -and $condition.VariablePath.UserPath -eq 'writeAllowed') {
            return $true
        }
    }
    return $false
}

$forbiddenParameter = @(
    'SkipIntegrityCheck',
    'SkipIntegrity',
    'IgnoreManifest',
    'SkipHash',
    'ForceBackup',
    'TrustBackup',
    'NoVerify',
    'TestMode'
)
$backupModulePath = Join-Path $repoRoot 'scripts\lib\RestorPc.Backup.psm1'
if (-not (Test-Path -LiteralPath $backupModulePath -PathType Leaf)) {
    $failed = $true
    Write-Host '[ERROR] RestorPc.Backup.psm1 est absent.'
} else {
    $backupAst = Get-ScriptAst -Path $backupModulePath
    foreach ($name in @($forbiddenParameter)) {
        if (@(Get-RestorAstParameterName -Ast $backupAst) -contains $name) {
            $failed = $true
            Write-Host ("[ERROR] Paramètre de contournement interdit : {0}" -f $name)
        }
    }
    foreach ($blockedName in @('Get-Disk', 'robocopy', 'robocopy.exe', 'Exit-RestorCommand')) {
        if (@(Get-RestorCommandNode -Ast $backupAst -CommandName $blockedName).Count -gt 0) {
            $failed = $true
            Write-Host ("[ERROR] Le moteur d'intégrité appelle {0}." -f $blockedName)
        }
    }
    $moduleExit = @($backupAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ExitStatementAst]
    }, $true))
    if ($moduleExit.Count -gt 0) {
        $failed = $true
        Write-Host '[ERROR] Le moteur d''intégrité ne doit pas appeler exit.'
    }
}

foreach ($name in @($forbiddenParameter)) {
    if (@(Get-RestorAstParameterName -Ast $restoreAst) -contains $name) {
        $failed = $true
        Write-Host ("[ERROR] Restore expose un contournement : {0}" -f $name)
    }
}

$integrityCalls = @(Get-RestorCommandNode -Ast $restoreAst -CommandName 'Test-RestorBackupIntegrity')
$diskCalls = @(Get-RestorCommandNode -Ast $restoreAst -CommandName 'Get-RestorDisk')
$adminCalls = @(Get-RestorCommandNode -Ast $restoreAst -CommandName 'Test-RestorAdministrator')
$partitionCalls = @(Get-RestorCommandNode -Ast $restoreAst -CommandName 'Get-Partition')
$robocopyCalls = @(Get-RestorCommandNode -Ast $restoreAst -CommandName 'robocopy.exe')
if ($integrityCalls.Count -ne 2 -or $diskCalls.Count -ne 1 -or $adminCalls.Count -ne 1 -or $partitionCalls.Count -lt 1 -or $robocopyCalls.Count -ne 2) {
    $failed = $true
    Write-Host '[ERROR] Restore doit avoir deux gates d''intégrité, avant le disque puis entre les deux robocopy.'
} else {
    if (-not (Test-RestorIntegrityCallInWriteGate -CommandNode $integrityCalls[0])) {
        $failed = $true
        Write-Host '[ERROR] Le premier contrôle d''intégrité doit être réservé à writeAllowed.'
    }
    if ($integrityCalls[0].Extent.StartOffset -ge $diskCalls[0].Extent.StartOffset) {
        $failed = $true
        Write-Host '[ERROR] Le premier contrôle d''intégrité doit précéder Get-RestorDisk.'
    }
    if ($integrityCalls[0].Extent.StartOffset -ge $partitionCalls[0].Extent.StartOffset -or $integrityCalls[0].Extent.StartOffset -ge $robocopyCalls[0].Extent.StartOffset) {
        $failed = $true
        Write-Host '[ERROR] Le premier contrôle d''intégrité doit précéder les opérations de partition et de copie.'
    }
    if ($adminCalls[0].Extent.StartOffset -le $diskCalls[0].Extent.StartOffset) {
        $failed = $true
        Write-Host '[ERROR] Le contrôle administrateur doit suivre l''identification du disque sur le chemin d''écriture.'
    }
    if ($integrityCalls[1].Extent.StartOffset -le $robocopyCalls[0].Extent.StartOffset -or $integrityCalls[1].Extent.StartOffset -ge $robocopyCalls[1].Extent.StartOffset) {
        $failed = $true
        Write-Host '[ERROR] Le second contrôle d''intégrité doit se placer après PRE-RESTORE et avant la copie Golden.'
    }
    if ($null -ne $dryRunExit -and $integrityCalls[1].Extent.StartOffset -le $dryRunExit.Extent.EndOffset) {
        $failed = $true
        Write-Host '[ERROR] Le dry-run ne doit pas atteindre le second contrôle d''intégrité.'
    }
    $snapshotCalls = @(Get-RestorCommandNode -Ast $restoreAst -CommandName 'Get-RestorManifestSnapshot')
    $postCalls = @(Get-RestorCommandNode -Ast $restoreAst -CommandName 'Test-RestorRestoredTarget')
    if ($snapshotCalls.Count -lt 1 -or $snapshotCalls[0].Extent.StartOffset -ge $diskCalls[0].Extent.StartOffset) {
        $failed = $true
        Write-Host '[ERROR] Le snapshot du manifeste doit précéder Get-RestorDisk.'
    }
    if ($postCalls.Count -lt 1 -or $postCalls[0].Extent.StartOffset -le $robocopyCalls[1].Extent.StartOffset) {
        $failed = $true
        Write-Host '[ERROR] La vérification post-restore doit suivre la copie Golden.'
    }
}

if ($failed) { exit 1 }
Write-Host '[OK] restore safety valid'
exit 0
