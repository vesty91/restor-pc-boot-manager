[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(0, 255)]
    [int]$DiskNumber
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EfiSystemPartitionGuid = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
$projectRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $projectRoot 'config\refind.conf'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Ouvrez PowerShell avec Exécuter en tant qu’administrateur.'
    }
}

Assert-Administrator

$targetDisk = Get-Disk -Number $DiskNumber
if ($targetDisk.IsBoot -or $targetDisk.IsSystem) {
    throw "Refus : le disque $DiskNumber est marqué Boot ou System par Windows."
}

$targetEsp = Get-Partition -DiskNumber $DiskNumber |
    Where-Object { [string]$_.GptType -eq $EfiSystemPartitionGuid } |
    Select-Object -First 1
if (-not $targetEsp) {
    throw "Aucune partition EFI Restor-PC trouvée sur le disque $DiskNumber."
}

$windowsEsp = Get-Partition |
    Where-Object { $_.IsSystem -and $_.DiskNumber -ne $DiskNumber } |
    Select-Object -First 1
if (-not $windowsEsp) {
    throw 'Aucune partition EFI Windows marquée System n’a été trouvée.'
}

$windowsEspGuid = ([string]$windowsEsp.Guid).Trim('{}')
$windowsDiskNumbers = @(
    Get-Partition |
        Where-Object { ($_.IsBoot -or $_.IsSystem) -and $_.DiskNumber -ne $DiskNumber } |
        Select-Object -ExpandProperty DiskNumber -Unique
)
$windowsVolumeGuids = @(
    foreach ($windowsDiskNumber in $windowsDiskNumbers) {
        Get-Partition -DiskNumber $windowsDiskNumber -ErrorAction SilentlyContinue |
            ForEach-Object { ([string]$_.Guid).Trim('{}') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }
)

if ([string]::IsNullOrWhiteSpace($windowsEspGuid) -or $windowsVolumeGuids.Count -eq 0) {
    throw 'Impossible de déterminer les GUID nécessaires à la configuration rEFInd.'
}

$template = Get-Content -LiteralPath $templatePath -Raw
if (-not $template.Contains('{{WINDOWS_ESP_GUID}}') -or
    -not $template.Contains('{{WINDOWS_VOLUME_GUIDS}}')) {
    throw 'Le modèle refind.conf ne contient pas les marqueurs attendus.'
}

$renderedConfig = $template.Replace('{{WINDOWS_ESP_GUID}}', $windowsEspGuid)
$renderedConfig = $renderedConfig.Replace(
    '{{WINDOWS_VOLUME_GUIDS}}',
    ($windowsVolumeGuids -join ',')
)

$temporaryAccessPath = $null
if ($targetEsp.DriveLetter) {
    $espRoot = "$($targetEsp.DriveLetter):\"
} else {
    $temporaryAccessPath = Join-Path $env:TEMP ("restor-esp-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryAccessPath | Out-Null
    Add-PartitionAccessPath `
        -DiskNumber $DiskNumber `
        -PartitionNumber $targetEsp.PartitionNumber `
        -AccessPath $temporaryAccessPath
    $espRoot = $temporaryAccessPath
}

try {
    $configPath = Join-Path $espRoot 'EFI\BOOT\refind.conf'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Configuration rEFInd absente : $configPath"
    }

    $backupPath = "$configPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $configPath -Destination $backupPath
    [IO.File]::WriteAllText($configPath, $renderedConfig, [Text.Encoding]::ASCII)

    $written = Get-Content -LiteralPath $configPath -Raw
    if ($written.Contains('{{WINDOWS_')) {
        throw 'La configuration écrite contient encore un marqueur non remplacé.'
    }

    Write-Host "Menu Restor-PC mis à jour sur le disque $DiskNumber." -ForegroundColor Green
    Write-Host "Sauvegarde : $backupPath"
    Write-Host 'Entrée principale : WIN CODE / WIN VESTY'
}
finally {
    if ($temporaryAccessPath) {
        Remove-PartitionAccessPath `
            -DiskNumber $DiskNumber `
            -PartitionNumber $targetEsp.PartitionNumber `
            -AccessPath $temporaryAccessPath `
            -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temporaryAccessPath -Force -ErrorAction SilentlyContinue
    }
}
