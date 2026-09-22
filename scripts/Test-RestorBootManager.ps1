[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(0, 255)]
    [int]$DiskNumber
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$espGuid = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'

$disk = Get-Disk -Number $DiskNumber
if ($disk.IsBoot -or $disk.IsSystem) {
    Write-Warning 'Le disque contrôlé est marqué Boot/System par Windows.'
}

$partition = Get-Partition -DiskNumber $DiskNumber |
    Where-Object { [string]$_.GptType -eq $espGuid } |
    Select-Object -First 1

if (-not $partition) { throw "Aucune partition EFI trouvée sur le disque $DiskNumber." }

$temporaryAccessPath = $null
if (-not $partition.DriveLetter) {
    $temporaryAccessPath = Join-Path $env:TEMP ("restor-esp-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryAccessPath | Out-Null
    Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath $temporaryAccessPath
    $root = $temporaryAccessPath
} else {
    $root = "$($partition.DriveLetter):\"
}

try {
    $checks = [ordered]@{
        'EFI fallback binary' = 'EFI\BOOT\BOOTX64.EFI'
        'rEFInd config'       = 'EFI\BOOT\refind.conf'
        'Theme config'        = 'EFI\BOOT\themes\restor-pc\theme.conf'
        'Background'          = 'EFI\BOOT\themes\restor-pc\assets\background.png'
        'Windows icon'        = 'EFI\BOOT\themes\restor-pc\assets\os_windows.png'
        'Install manifest'    = 'EFI\BOOT\restor-pc-install.json'
    }

    $failed = $false
    foreach ($item in $checks.GetEnumerator()) {
        $path = Join-Path $root $item.Value
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        if (-not $exists) { $failed = $true }
        [pscustomobject]@{
            Check  = $item.Key
            Status = if ($exists) { 'OK' } else { 'MISSING' }
            Path   = $item.Value
        }
    }

    if ($failed) { throw 'Validation échouée : un ou plusieurs fichiers sont absents.' }
    Write-Host "`nValidation réussie pour le disque $DiskNumber." -ForegroundColor Green
}
finally {
    if ($temporaryAccessPath) {
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath $temporaryAccessPath -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temporaryAccessPath -Force -ErrorAction SilentlyContinue
    }
}
