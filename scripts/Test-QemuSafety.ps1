<#
.SYNOPSIS
  Analyse statique des scripts QEMU. Ne lance pas QEMU.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$failed = $false
$needles = @('PhysicalDrive', '/dev/sd', '/dev/nvme', '\\?\Volume')
$imageNames = @('restor-boot.img', 'code-efi.img', 'vesty-efi.img', 'rescue-efi.img', 'lockpick-efi.img')

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

function Test-ForbiddenStringAllowed {
    param($StringNode)
    $node = $StringNode
    while ($null -ne $node) {
        if ($node -is [System.Management.Automation.Language.ThrowStatementAst]) { return $true }
        if ($node -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            if ($node.Left.Extent.Text -eq '$forbidden') { return $true }
        }
        if ($node -is [System.Management.Automation.Language.BinaryExpressionAst]) {
            $operator = [string]$node.Operator
            if ($operator -match 'Match$' -and $node.Right -eq $StringNode) { return $true }
        }
        if ($node -is [System.Management.Automation.Language.CommandAst]) {
            $commandName = $node.GetCommandName()
            if (@('Write-Host', 'Write-Error', 'Write-Warning', 'Write-BootStep', 'Write-BuildStep', 'Write-QemuStep', 'Assert-QemuCommandSafe') -contains $commandName) {
                return $true
            }
        }
        $node = $node.Parent
    }
    return $false
}

function Test-NoEffectivePhysicalReference {
    param([string]$Path, $Ast)
    $strings = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true))
    foreach ($stringNode in $strings) {
        $text = $stringNode.Extent.Text
        $hit = $false
        foreach ($needle in $needles) {
            if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true }
        }
        if (-not $hit) { continue }
        if (Test-ForbiddenStringAllowed -StringNode $stringNode) { continue }
        $script:failed = $true
        Write-Host ("[ERROR] {0} ligne {1} : référence physique hors garde-fou : {2}" -f (Split-Path -Leaf $Path), $stringNode.Extent.StartLineNumber, $text)
    }
}

$testBootPath = Join-Path $repoRoot 'scripts\test-boot.ps1'
$buildPath = Join-Path $repoRoot 'scripts\build-test-disk.ps1'
$checkPath = Join-Path $repoRoot 'scripts\check-qemu.ps1'
foreach ($requiredPath in @($testBootPath, $buildPath, $checkPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        Write-Host ("[ERROR] Script absent : {0}" -f $requiredPath)
        exit 1
    }
}

$testBootAst = Get-ScriptAst -Path $testBootPath
$buildAst = Get-ScriptAst -Path $buildPath
$checkAst = Get-ScriptAst -Path $checkPath
Test-NoEffectivePhysicalReference -Path $testBootPath -Ast $testBootAst
Test-NoEffectivePhysicalReference -Path $buildPath -Ast $buildAst
Test-NoEffectivePhysicalReference -Path $checkPath -Ast $checkAst

$accel = $null
if ($testBootAst.ParamBlock) {
    foreach ($parameter in @($testBootAst.ParamBlock.Parameters)) {
        if ($parameter.Name.VariablePath.UserPath -eq 'Accel') { $accel = $parameter }
    }
}
if ($null -eq $accel -or $null -eq $accel.DefaultValue -or [string]$accel.DefaultValue.SafeGetValue() -ne 'tcg') {
    $failed = $true
    Write-Host '[ERROR] Le mode QEMU par défaut doit être TCG.'
}
foreach ($assignment in @($testBootAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$Accel'
}, $true))) {
    $failed = $true
    Write-Host ("[ERROR] test-boot.ps1 réassigne `$Accel ligne {0}." -f $assignment.Extent.StartLineNumber)
}

$ahci = @($testBootAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
    $node.Value -eq 'ich9-ahci,id=ahci'
}, $true))
if ($ahci.Count -lt 1) {
    $failed = $true
    Write-Host '[ERROR] ich9-ahci est absent des arguments QEMU.'
}

$qemuFunction = @($testBootAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-QemuArgumentLine'
}, $true))
if ($qemuFunction.Count -ne 1) {
    $failed = $true
    Write-Host '[ERROR] Get-QemuArgumentLine est absent de test-boot.ps1.'
} else {
    foreach ($needle in $needles) {
        if ($qemuFunction[0].Extent.Text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $failed = $true
            Write-Host ("[ERROR] Get-QemuArgumentLine contient {0}." -f $needle)
        }
    }
}

$commandCalls = @($testBootAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
$getLine = @($commandCalls | Where-Object { $_.GetCommandName() -eq 'Get-QemuArgumentLine' } | Sort-Object { $_.Extent.StartOffset })
$guards = @($commandCalls | Where-Object { $_.GetCommandName() -eq 'Assert-QemuCommandSafe' } | Sort-Object { $_.Extent.StartOffset })
$starts = @($commandCalls | Where-Object { $_.GetCommandName() -eq 'Start-QemuSession' } | Sort-Object { $_.Extent.StartOffset })
if ($getLine.Count -lt 1 -or $starts.Count -lt 1) {
    $failed = $true
    Write-Host '[ERROR] La construction ou le lancement QEMU est introuvable.'
} else {
    $buildOffset = $getLine[0].Extent.StartOffset
    $startOffset = $starts[0].Extent.StartOffset
    $guardAfterBuild = @($guards | Where-Object { $_.Extent.StartOffset -gt $buildOffset -and $_.Extent.StartOffset -lt $startOffset })
    if ($guardAfterBuild.Count -lt 1) {
        $failed = $true
        Write-Host '[ERROR] Assert-QemuCommandSafe doit filtrer la commande QEMU avant son lancement.'
    }
}

foreach ($scriptAst in @($testBootAst, $buildAst)) {
    $imageLiterals = @($scriptAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value.Length -gt 4 -and $node.Value -like '*.img'
    }, $true))
    foreach ($literal in $imageLiterals) {
        $value = $literal.Value
        $bare = [IO.Path]::GetFileName($value)
        $prefix = $value.Substring(0, $value.Length - $bare.Length)
        $allowedPrefix = $prefix -eq '' -or $prefix -eq 'test\' -or $prefix -eq 'test/'
        if (-not $allowedPrefix -or $imageNames -notcontains $bare -or $value -match '^[A-Za-z]:' -or $value.StartsWith('\\')) {
            $failed = $true
            Write-Host ("[ERROR] Image QEMU hors de test\*.img : {0}" -f $value)
        }
    }
}

$bootText = $testBootAst.Extent.Text
foreach ($imageName in $imageNames) {
    if ($bootText.IndexOf($imageName, [StringComparison]::Ordinal) -lt 0) {
        $failed = $true
        Write-Host ("[ERROR] test-boot.ps1 ne cite pas {0}." -f $imageName)
    }
}

$guardFunction = @($buildAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-TestImagePath'
}, $true))
if ($guardFunction.Count -ne 1) {
    $failed = $true
    Write-Host '[ERROR] Assert-TestImagePath est absent de build-test-disk.ps1.'
} else {
    $guardText = $guardFunction[0].Extent.Text
    if ($guardText -notmatch 'test' -or $guardText -notmatch '\.img') {
        $failed = $true
        Write-Host '[ERROR] Assert-TestImagePath ne limite pas les images à test\*.img.'
    }
}

if ($failed) { exit 1 }
Write-Host '[OK] QEMU safety valid'
exit 0
