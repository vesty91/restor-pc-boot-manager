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

if ($failed) { exit 1 }
Write-Host '[OK] repository safety valid'
exit 0
