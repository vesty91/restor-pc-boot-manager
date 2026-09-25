[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateRange(0, 255)]
    [int]$DiskNumber,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$RefindArchive,

    [Parameter()]
    [ValidateRange(260, 4096)]
    [int]$EspSizeMB = 1024
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EfiSystemPartitionGuid = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
$projectRoot = Split-Path -Parent $PSScriptRoot
$themeSource = Join-Path $projectRoot 'theme\restor-pc'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvrez PowerShell avec Exécuter en tant qu’administrateur."
    }
}

function Get-FreeDriveLetter {
    $used = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { [char]$_.DriveLetter })
    foreach ($code in ([int][char]'R')..([int][char]'Z')) {
        $candidate = [char]$code
        if ($candidate -notin $used) { return $candidate }
    }
    throw 'Aucune lettre libre entre R: et Z:.'
}

function Find-RefindPayload {
    param([string]$Root)
    $binary = Get-ChildItem -LiteralPath $Root -Filter 'refind_x64.efi' -File -Recurse |
        Select-Object -First 1
    if (-not $binary) { throw "refind_x64.efi est absent de l’archive." }

    $payload = $binary.Directory.FullName
    if (-not (Test-Path -LiteralPath (Join-Path $payload 'icons'))) {
        throw 'Le dossier icons est absent à côté de refind_x64.efi.'
    }
    return $payload
}

function Get-RenderedRefindConfig {
    param(
        [Parameter(Mandatory)]
        [string]$TemplatePath,

        [Parameter(Mandatory)]
        [string]$WindowsEspGuid,

        [Parameter(Mandatory)]
        [string[]]$WindowsVolumeGuids
    )

    $template = Get-Content -LiteralPath $TemplatePath -Raw
    if (-not $template.Contains('{{WINDOWS_ESP_GUID}}') -or
        -not $template.Contains('{{WINDOWS_VOLUME_GUIDS}}')) {
        throw 'Le modèle refind.conf ne contient pas les marqueurs attendus.'
    }

    $rendered = $template.Replace('{{WINDOWS_ESP_GUID}}', $WindowsEspGuid)
    return $rendered.Replace('{{WINDOWS_VOLUME_GUIDS}}', ($WindowsVolumeGuids -join ','))
}

Assert-Administrator

if ((Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType -ne 'Uefi') {
    throw "Windows n’est pas démarré en mode UEFI."
}

$disk = Get-Disk -Number $DiskNumber
$serial = ([string]$disk.SerialNumber).Trim()
if ([string]::IsNullOrWhiteSpace($serial)) { $serial = 'SANS-SERIE' }

Write-Host ''
$disk | Format-List Number, FriendlyName, SerialNumber, BusType, PartitionStyle, Size, OperationalStatus, IsBoot, IsSystem, IsReadOnly, IsOffline

if ($disk.IsBoot -or $disk.IsSystem) {
    throw "Refus : le disque $DiskNumber est marqué Boot ou System par Windows."
}

if ($disk.Size -lt 2GB) {
    throw 'Le disque cible est trop petit.'
}

$currentSystemDiskNumbers = @(Get-Partition | Where-Object { $_.IsBoot -or $_.IsSystem } | Select-Object -ExpandProperty DiskNumber -Unique)
if ($DiskNumber -in $currentSystemDiskNumbers) {
    throw "Refus : le disque $DiskNumber contient une partition système ou de démarrage."
}

$windowsEsp = Get-Partition |
    Where-Object { $_.IsSystem -and $_.DiskNumber -ne $DiskNumber } |
    Select-Object -First 1
if (-not $windowsEsp) {
    throw 'Aucune partition EFI Windows marquée System n’a été trouvée.'
}

$windowsEspGuid = ([string]$windowsEsp.Guid).Trim('{}')
if ([string]::IsNullOrWhiteSpace($windowsEspGuid)) {
    throw 'La partition EFI Windows ne possède pas de GUID GPT exploitable.'
}

$windowsVolumeGuids = @(
    foreach ($systemDiskNumber in $currentSystemDiskNumbers) {
        Get-Partition -DiskNumber $systemDiskNumber -ErrorAction SilentlyContinue |
            ForEach-Object { ([string]$_.Guid).Trim('{}') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
)
if ($windowsVolumeGuids.Count -eq 0) {
    throw 'Aucun GUID de volume Windows n’a été trouvé pour filtrer le menu.'
}

$expected = "ERASE DISK $DiskNumber $serial"
Write-Warning "L’étape suivante efface entièrement le disque affiché ci-dessus."
Write-Host "Pour confirmer, saisissez exactement : $expected" -ForegroundColor Yellow
$typed = Read-Host 'Confirmation'
if ($typed -cne $expected) {
    throw 'Confirmation incorrecte. Aucune modification effectuée.'
}

$archive = (Resolve-Path -LiteralPath $RefindArchive).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("restor-refind-" + [guid]::NewGuid().ToString('N'))
$driveLetter = Get-FreeDriveLetter

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $tempRoot
    $refindPayload = Find-RefindPayload -Root $tempRoot

    if (-not $PSCmdlet.ShouldProcess("Disk $DiskNumber ($($disk.FriendlyName), serial $serial)", 'Initialize GPT, create a FAT32 ESP and install rEFInd')) {
        return
    }

    if ($disk.IsReadOnly) { Set-Disk -Number $DiskNumber -IsReadOnly $false }
    if ($disk.IsOffline) { Set-Disk -Number $DiskNumber -IsOffline $false }

    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT
    $partition = New-Partition -DiskNumber $DiskNumber -Size ($EspSizeMB * 1MB) -GptType $EfiSystemPartitionGuid -DriveLetter $driveLetter
    Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel 'RESTOR-BOOT' -Confirm:$false | Out-Null

    $espRoot = "${driveLetter}:\"
    $bootRoot = Join-Path $espRoot 'EFI\BOOT'
    New-Item -ItemType Directory -Path $bootRoot -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $refindPayload 'refind_x64.efi') -Destination (Join-Path $bootRoot 'BOOTX64.EFI') -Force
    Copy-Item -LiteralPath (Join-Path $refindPayload 'icons') -Destination $bootRoot -Recurse -Force

    $drivers = Join-Path $refindPayload 'drivers_x64'
    if (Test-Path -LiteralPath $drivers) {
        Copy-Item -LiteralPath $drivers -Destination $bootRoot -Recurse -Force
    }

    $themeDestination = Join-Path $bootRoot 'themes\restor-pc'
    New-Item -ItemType Directory -Path (Split-Path -Parent $themeDestination) -Force | Out-Null
    Copy-Item -LiteralPath $themeSource -Destination $themeDestination -Recurse -Force

    # Replace the generic rEFInd icons with the Restor-PC variants.
    Copy-Item -LiteralPath (Join-Path $themeDestination 'assets\os_windows.png') -Destination (Join-Path $bootRoot 'icons\os_win.png') -Force
    Copy-Item -LiteralPath (Join-Path $themeDestination 'assets\os_linux.png') -Destination (Join-Path $bootRoot 'icons\os_linux.png') -Force

    $renderedConfig = Get-RenderedRefindConfig `
        -TemplatePath (Join-Path $projectRoot 'config\refind.conf') `
        -WindowsEspGuid $windowsEspGuid `
        -WindowsVolumeGuids $windowsVolumeGuids
    [IO.File]::WriteAllText(
        (Join-Path $bootRoot 'refind.conf'),
        $renderedConfig,
        [Text.Encoding]::ASCII
    )

    $manifest = [pscustomobject]@{
        InstalledAt   = (Get-Date).ToString('o')
        DiskNumber    = $DiskNumber
        FriendlyName  = $disk.FriendlyName
        SerialNumber  = $serial
        EspSizeMB     = $EspSizeMB
        SourceArchive = Split-Path -Leaf $archive
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bootRoot 'restor-pc-install.json') -Encoding utf8

    Write-Host "`nInstallation terminée sur ${driveLetter}:" -ForegroundColor Green
    Write-Host 'Le reste du NVMe a été laissé non alloué.'
    Write-Host "Validez maintenant avec : .\scripts\Test-RestorBootManager.ps1 -DiskNumber $DiskNumber"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
