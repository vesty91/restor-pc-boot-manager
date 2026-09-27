<#
.SYNOPSIS
  Vérifie config\refind.conf sans accéder à un volume physique.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$configPath = Join-Path $repoRoot 'config\refind.conf'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Host '[ERROR] config\refind.conf est absent.'
    exit 1
}

$expected = @{
    'WIN CODE' = @{ Volume = 'CODE-EFI'; Loader = '\EFI\Microsoft\Boot\bootmgfw.efi' }
    'WIN VESTY' = @{ Volume = 'VESTY-EFI'; Loader = '\EFI\Microsoft\Boot\bootmgfw.efi' }
    'MEMTEST86+' = @{ Volume = $null; Loader = '\EFI\TOOLS\MEMTEST\mt86plus.efi' }
    'RESCUEGRID' = @{ Volume = 'RESCUE-EFI'; Loader = '\EFI\Microsoft\Boot\bootmgfw.efi' }
    'LOCKPICK' = @{ Volume = 'LOCKPICK-EFI'; Loader = '\EFI\BOOT\BOOTX64.EFI' }
}

$entries = @{}
$current = $null
$scanforManual = $false
$lineNumber = 0
foreach ($line in @(Get-Content -LiteralPath $configPath)) {
    $lineNumber++
    $trim = $line.Trim()
    if ($trim.Length -eq 0 -or $trim.StartsWith('#')) { continue }
    if ($trim -match '^scanfor\s+manual(\s+#.*)?$') {
        $scanforManual = $true
        continue
    }
    if ($trim -match '^menuentry\s+"([^"]+)"\s*\{') {
        $name = $Matches[1]
        if ($entries.ContainsKey($name)) {
            Write-Host ("[ERROR] Entrée dupliquée à la ligne {0} : {1}" -f $lineNumber, $name)
            exit 1
        }
        $current = @{ Name = $name; Volume = $null; Loader = $null; Line = $lineNumber }
        $entries[$name] = $current
        continue
    }
    if ($null -eq $current) { continue }
    if ($trim -match '^volume\s+"([^"]+)"') {
        $current.Volume = $Matches[1]
        continue
    }
    if ($trim -match '^loader\s+(\S+)') {
        $current.Loader = $Matches[1]
        continue
    }
    if ($trim -eq '}') { $current = $null }
}

$failed = $false
if (-not $scanforManual) {
    $failed = $true
    Write-Host '[ERROR] scanfor manual est absent de config\refind.conf.'
}

foreach ($name in $expected.Keys) {
    if (-not $entries.ContainsKey($name)) {
        $failed = $true
        Write-Host ("[ERROR] Entrée absente : {0}" -f $name)
        continue
    }
    $entry = $entries[$name]
    $want = $expected[$name]
    if ($entry.Loader -ne $want.Loader) {
        $failed = $true
        Write-Host ("[ERROR] {0} : loader {1}, attendu {2}" -f $name, $entry.Loader, $want.Loader)
    }
    if ($entry.Volume -ne $want.Volume) {
        $failed = $true
        Write-Host ("[ERROR] {0} : volume {1}, attendu {2}" -f $name, $entry.Volume, $want.Volume)
    }
}

foreach ($name in @($entries.Keys)) {
    if (-not $expected.ContainsKey($name)) {
        $failed = $true
        Write-Host ("[ERROR] Entrée inattendue : {0}" -f $name)
    }
}

if ($entries.Count -ne 5) {
    $failed = $true
    Write-Host ("[ERROR] {0} entrées trouvées, 5 attendues." -f $entries.Count)
}

if ($failed) { exit 1 }
Write-Host '[OK] rEFInd config valid'
exit 0
