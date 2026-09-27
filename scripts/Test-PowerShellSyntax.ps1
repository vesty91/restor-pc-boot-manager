<#
.SYNOPSIS
  Vérifie la syntaxe de scripts\*.ps1 sans les exécuter.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptsRoot = Join-Path $repoRoot 'scripts'
$failed = $false

$files = @(Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1' -File)
if ($files.Count -eq 0) {
    Write-Host '[ERROR] Aucun script PowerShell dans scripts\.'
    exit 1
}

foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )
    } catch {
        $failed = $true
        Write-Host ("[ERROR] {0} : {1}" -f $file.FullName, $_.Exception.Message)
        continue
    }

    $reported = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($parseErrors) {
        foreach ($parseError in @($parseErrors)) {
            $failed = $true
            $message = "[{0}] {1}" -f $file.Name, $parseError
            if ($reported.Add($message)) {
                Write-Host ("[ERROR] " + $message)
            }
        }
    }

    foreach ($token in @($tokens)) {
        $kind = [string]$token.Kind
        if ($kind -eq 'Unknown') {
            $failed = $true
            $message = "[{0}] jeton invalide ligne {1} : {2}" -f $file.Name, $token.Extent.StartLineNumber, $token.Text
            if ($reported.Add($message)) {
                Write-Host ("[ERROR] " + $message)
            }
        }
    }
}

if ($failed) { exit 1 }
Write-Host '[OK] PowerShell syntax valid'
exit 0
