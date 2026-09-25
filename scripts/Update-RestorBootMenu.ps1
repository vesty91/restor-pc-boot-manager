[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(0,255)]
    [int]$DiskNumber
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Ouvrez PowerShell avec Exécuter en tant qu’administrateur.'
    }
}

function Get-FreeDriveLetter {
    $used = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { [char]$_.DriveLetter })
    foreach ($letter in 'R','S','T','U','W','X','Y','Z') {
        if ([char]$letter -notin $used) { return $letter }
    }
    throw 'Aucune lettre temporaire libre.'
}

function Get-PartitionByLabel {
    param([int]$Disk,[string]$Label)
    foreach ($p in Get-Partition -DiskNumber $Disk) {
        $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
        if ($v -and $v.FileSystemLabel -eq $Label) { return $p }
    }
    return $null
}

Assert-Administrator

$disk = Get-Disk -Number $DiskNumber
if ($disk.PartitionStyle -ne 'GPT') { throw "Le disque $DiskNumber n'est pas GPT." }

if ($disk.IsSystem) {
    Write-Host "Information : le disque $DiskNumber est marqué System, ce qui est normal si RESTOR-PC a amorcé la session." -ForegroundColor Yellow
}

$restor = Get-PartitionByLabel -Disk $DiskNumber -Label 'RESTOR-BOOT'
$code   = Get-PartitionByLabel -Disk $DiskNumber -Label 'CODE-EFI'
$vesty  = Get-PartitionByLabel -Disk $DiskNumber -Label 'VESTY-EFI'

if (-not $restor -or -not $code -or -not $vesty) {
    throw 'Structure RESTOR-PC incomplète : RESTOR-BOOT, CODE-EFI et VESTY-EFI sont requis.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$configSource = Join-Path $projectRoot 'config\refind.conf'
$themeSource  = Join-Path $projectRoot 'theme\restor-pc'

if (-not (Test-Path -LiteralPath $configSource)) { throw 'config\refind.conf introuvable.' }
if (-not (Test-Path -LiteralPath $themeSource))  { throw 'theme\restor-pc introuvable.' }

$tempLetter = $null
if ($restor.DriveLetter) {
    $root = ($restor.DriveLetter + ':\')
} else {
    $tempLetter = Get-FreeDriveLetter
    $access = ($tempLetter + ':\')
    Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $restor.PartitionNumber -AccessPath $access
    $root = $access
}

try {
    $bootRoot = Join-Path $root 'EFI\BOOT'
    if (-not (Test-Path -LiteralPath (Join-Path $bootRoot 'BOOTX64.EFI'))) {
        throw 'BOOTX64.EFI est absent de RESTOR-BOOT.'
    }

    $configDestination = Join-Path $bootRoot 'refind.conf'
    $backup = ($configDestination + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

    if (Test-Path -LiteralPath $configDestination) {
        Copy-Item -LiteralPath $configDestination -Destination $backup -Force
    }

    Copy-Item -LiteralPath $configSource -Destination $configDestination -Force

    $themeDestination = Join-Path $bootRoot 'themes\restor-pc'
    New-Item -ItemType Directory -Path (Split-Path $themeDestination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $themeSource -Destination $themeDestination -Recurse -Force

    Write-Host 'Menu RESTOR-PC mis à jour.' -ForegroundColor Green
    Write-Host ('Sauvegarde précédente : ' + $backup)
}
finally {
    if ($tempLetter) {
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $restor.PartitionNumber -AccessPath ($tempLetter + ':\') -ErrorAction SilentlyContinue
    }
}
