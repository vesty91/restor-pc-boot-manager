<#
.SYNOPSIS
  Détecte QEMU et le firmware OVMF sans rien installer.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-QemuStep {
    param([string]$Level, [string]$Message)
    Write-Host ("[{0}] {1}" -f $Level, $Message)
}

function Get-QemuSearchRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
        'C:\Program Files\qemu',
        'C:\Program Files (x86)\qemu',
        'C:\tools\qemu',
        (Join-Path $env:LOCALAPPDATA 'Programs\qemu'),
        'C:\msys64\ucrt64\bin',
        'C:\msys64\mingw64\bin'
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $roots.Add($candidate) }
    }
    return $roots
}

function Find-ToolExecutable {
    param([Parameter(Mandatory)][string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source)) {
        return [IO.Path]::GetFullPath($command.Source)
    }
    foreach ($root in (Get-QemuSearchRoots)) {
        $direct = Join-Path $root $Name
        if (Test-Path -LiteralPath $direct) { return [IO.Path]::GetFullPath($direct) }
        $nested = Get-ChildItem -LiteralPath $root -Filter $Name -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($nested) { return $nested.FullName }
    }
    return $null
}

function Find-FirmwareFile {
    param([Parameter(Mandatory)][string[]]$Names)
    $directories = New-Object System.Collections.Generic.List[string]
    foreach ($root in (Get-QemuSearchRoots)) { $directories.Add($root) }
    $qemu = Find-ToolExecutable -Name 'qemu-system-x86_64.exe'
    if ($qemu) {
        $bin = Split-Path -Parent $qemu
        $directories.Add($bin)
        $directories.Add((Join-Path $bin 'share'))
        $directories.Add((Join-Path (Split-Path -Parent $bin) 'share'))
        $directories.Add((Join-Path $bin 'share\qemu'))
    }
    foreach ($name in $Names) {
        foreach ($directory in $directories) {
            if (-not (Test-Path -LiteralPath $directory)) { continue }
            $direct = Join-Path $directory $name
            if (Test-Path -LiteralPath $direct) { return [IO.Path]::GetFullPath($direct) }
            $nested = Get-ChildItem -LiteralPath $directory -Filter $name -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($nested) { return $nested.FullName }
        }
    }
    return $null
}

function Get-QemuToolSet {
    $codeNames = @('OVMF_CODE.fd', 'OVMF_CODE_4M.fd', 'edk2-x86_64-code.fd', 'edk2-x86_64-secure-code.fd')
    $varsNames = @('OVMF_VARS.fd', 'OVMF_VARS_4M.fd', 'edk2-i386-vars.fd', 'edk2-x86_64-vars.fd')
    return [pscustomobject]@{
        Qemu     = Find-ToolExecutable -Name 'qemu-system-x86_64.exe'
        QemuImg  = Find-ToolExecutable -Name 'qemu-img.exe'
        OvmfCode = Find-FirmwareFile -Names $codeNames
        OvmfVars = Find-FirmwareFile -Names $varsNames
    }
}

function Write-InstallHints {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    $choco = Get-Command choco.exe -ErrorAction SilentlyContinue
    Write-QemuStep 'INFO' 'Aucune installation automatique n''est lancée.'
    if ($winget) {
        Write-QemuStep 'INFO' 'Commande proposée : winget install --id SoftwareFreedomConservancy.QEMU -e'
    }
    if ($choco) {
        Write-QemuStep 'INFO' 'Commande proposée : choco install qemu -y'
    }
    if (-not $winget -and -not $choco) {
        Write-QemuStep 'INFO' 'Installez QEMU pour Windows, avec les firmwares edk2/OVMF livrés dans son dossier share.'
    }
}

function Invoke-QemuCheck {
    $tools = Get-QemuToolSet
    $missing = @()
    if ($tools.Qemu) { Write-QemuStep 'OK' ("qemu-system-x86_64.exe : " + $tools.Qemu) } else { $missing += 'qemu-system-x86_64.exe'; Write-QemuStep 'ERROR' 'qemu-system-x86_64.exe est introuvable.' }
    if ($tools.QemuImg) { Write-QemuStep 'OK' ("qemu-img.exe : " + $tools.QemuImg) } else { $missing += 'qemu-img.exe'; Write-QemuStep 'WARN' 'qemu-img.exe est introuvable. La construction de l''image FAT32 n''en a pas besoin.' }
    if ($tools.OvmfCode) { Write-QemuStep 'OK' ("OVMF code : " + $tools.OvmfCode) } else { $missing += 'OVMF_CODE.fd'; Write-QemuStep 'ERROR' 'OVMF_CODE.fd / edk2-x86_64-code.fd est introuvable.' }
    if ($tools.OvmfVars) { Write-QemuStep 'OK' ("OVMF vars : " + $tools.OvmfVars) } else { $missing += 'OVMF_VARS.fd'; Write-QemuStep 'ERROR' 'OVMF_VARS.fd / edk2-i386-vars.fd est introuvable.' }
    if ($missing -contains 'qemu-system-x86_64.exe' -or $missing -contains 'OVMF_CODE.fd' -or $missing -contains 'OVMF_VARS.fd') {
        Write-InstallHints
        return 1
    }
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-QemuCheck)
}
