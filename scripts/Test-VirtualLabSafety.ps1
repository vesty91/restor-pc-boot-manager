<#
.SYNOPSIS
  Analyse statique du laboratoire VHDX. N'attache aucun disque.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$failed = $false
$labScript = Join-Path $repoRoot 'scripts\New-RestorVirtualLab.ps1'
$inventoryScript = Join-Path $repoRoot 'scripts\Get-RestorVirtualLab.ps1'
$orchestrator = Join-Path $repoRoot 'scripts\Test-VirtualRestore.ps1'
$restoreScript = Join-Path $repoRoot 'scripts\Restore-RestorBootManager.ps1'

function Get-ScriptAst {
    param([string]$Path)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and @($parseErrors).Count -gt 0) { throw ("Syntaxe invalide : " + $Path) }
    return $ast
}

foreach ($path in @($labScript, $inventoryScript, $orchestrator, $restoreScript)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host ("[ERROR] Script absent : {0}" -f $path)
        exit 1
    }
}

$forbidden = @('\\.\PhysicalDrive', 'Clear-Disk', 'diskpart', 'SkipSafety', 'ForceTestDisk', 'AllowNonNvme', 'IgnoreSerial', 'DisableDiskCheck', 'Enable-WindowsOptionalFeature')
foreach ($path in @($labScript, $inventoryScript, $orchestrator)) {
    $text = [IO.File]::ReadAllText($path)
    foreach ($token in $forbidden) {
        if ($text.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $failed = $true
            Write-Host ("[ERROR] {0} contient {1}" -f (Split-Path -Leaf $path), $token)
        }
    }
}
$labText = [IO.File]::ReadAllText($labScript)
if ($labText.IndexOf('test\vhd', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    $failed = $true
    Write-Host '[ERROR] Le laboratoire ne force pas un chemin sous test\vhd.'
}
if ($labText.IndexOf('SAMSUNG MZVLB256HAHQ-000L2', [StringComparison]::Ordinal) -lt 0 -or $labText.IndexOf('PHYSICAL RESTOR-PC NVME BLOCKED', [StringComparison]::Ordinal) -lt 0) {
    $failed = $true
    Write-Host '[ERROR] Le NVMe physique n est pas bloque explicitement.'
}
$restoreText = [IO.File]::ReadAllText($restoreScript)
foreach ($token in @('SkipSafety', 'ForceTestDisk', 'AllowNonNvme', 'IgnoreSerial', 'DisableDiskCheck')) {
    if ($restoreText.IndexOf($token, [StringComparison]::Ordinal) -ge 0) {
        $failed = $true
        Write-Host ("[ERROR] Restore contient une backdoor : {0}" -f $token)
    }
}

$destructive = @('Initialize-Disk', 'New-Partition', 'Format-Volume', 'Add-PartitionAccessPath', 'Set-Disk')
$labAst = Get-ScriptAst -Path $labScript
$functions = @($labAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true))
$layout = @($functions | Where-Object { $_.Name -eq 'Invoke-RestorVirtualDiskLayout' })
if ($layout.Count -ne 1) {
    $failed = $true
    Write-Host '[ERROR] Invoke-RestorVirtualDiskLayout est absent.'
} else {
    $commands = @($layout[0].Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))
    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        if ($destructive -notcontains $name) { continue }
        $earlierAssert = @($commands | Where-Object {
            $_.GetCommandName() -eq 'Assert-RestorVirtualLabDisk' -and $_.Extent.StartOffset -lt $command.Extent.StartOffset
        })
        if ($earlierAssert.Count -lt 1) {
            $failed = $true
            Write-Host ("[ERROR] {0} n est pas precede par Assert-RestorVirtualLabDisk." -f $name)
        }
    }
}
foreach ($outside in @($inventoryScript, $orchestrator)) {
    $outsideAst = Get-ScriptAst -Path $outside
    $hits = @($outsideAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $destructive -contains $node.GetCommandName()
    }, $true))
    if ($hits.Count -gt 0) {
        $failed = $true
        Write-Host ("[ERROR] Commande de partitionnement hors du script de creation : {0}" -f (Split-Path -Leaf $outside))
    }
}

if ($failed) { exit 1 }
Write-Host '[OK] virtual lab safety valid'
exit 0
