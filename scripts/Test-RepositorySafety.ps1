<#
.SYNOPSIS
  Vérifie que Git ne suit aucun fichier binaire interdit.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tracked = @(git -C $repoRoot ls-files)
if ($LASTEXITCODE -ne 0) {
    Write-Host '[ERROR] git ls-files a échoué.'
    exit 1
}

$failed = $false
foreach ($relative in $tracked) {
    $path = ($relative -replace '\\', '/').Trim()
    $leaf = [IO.Path]::GetFileName($path)
    $forbidden = $false
    if ($leaf -eq 'Lockpick.iso' -or $path -like '*.iso') { $forbidden = $true }
    if ($path -like 'test/*.img') { $forbidden = $true }
    if ($path -like 'test/logs' -or $path -like 'test/logs/*') { $forbidden = $true }
    if ($path -like 'test/stubs' -or $path -like 'test/stubs/*') { $forbidden = $true }
    if ($path -eq 'bootloader/refind/refind_x64.efi') { $forbidden = $true }
    if ($path -like '*.vhd' -or $path -like '*.vhdx' -or $path -like '*.qcow2' -or $path -like '*.raw') { $forbidden = $true }
    if ($forbidden) {
        $failed = $true
        Write-Host ("[ERROR] Fichier interdit versionné : {0}" -f $path)
    }
}

$restorePath = Join-Path $repoRoot 'scripts\Restore-RestorBootManager.ps1'
$tokens = $null
$parseErrors = $null
$restoreAst = [System.Management.Automation.Language.Parser]::ParseFile($restorePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and @($parseErrors).Count -gt 0) {
    Write-Host '[ERROR] Syntaxe Restore invalide.'
    exit 1
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
$parameterNames = New-Object System.Collections.Generic.List[string]
$blocks = @()
if ($restoreAst.ParamBlock) { $blocks += $restoreAst.ParamBlock }
foreach ($functionNode in @($restoreAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true))) {
    if ($functionNode.Body.ParamBlock) { $blocks += $functionNode.Body.ParamBlock }
}
foreach ($block in $blocks) {
    foreach ($parameter in @($block.Parameters)) {
        if ($null -eq $parameter) { continue }
        $parameterNames.Add([string]$parameter.Name.VariablePath.UserPath)
    }
}
foreach ($name in $forbiddenParameter) {
    if ($parameterNames -contains $name) {
        $failed = $true
        Write-Host ("[ERROR] Restore expose un contournement : {0}" -f $name)
    }
}

if ($failed) { exit 1 }
Write-Host '[OK] repository safety valid'
exit 0
