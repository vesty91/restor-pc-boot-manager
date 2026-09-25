[CmdletBinding()]
param(
    [Parameter()]
    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-Size {
    param([UInt64]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TiB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GiB' -f ($Bytes / 1GB)) }
    return ('{0:N2} MiB' -f ($Bytes / 1MB))
}

$disks = foreach ($disk in Get-Disk | Sort-Object Number) {
    $partitions = foreach ($partition in Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue | Select-Object -First 1
        $fileSystem = $null
        $fileSystemLabel = $null
        if ($null -ne $volume) {
            $fileSystem = [string]$volume.FileSystem
            $fileSystemLabel = [string]$volume.FileSystemLabel
        }

        [pscustomobject]@{
            PartitionNumber = $partition.PartitionNumber
            DriveLetter     = $partition.DriveLetter
            Type            = $partition.Type
            GptType         = [string]$partition.GptType
            SizeBytes       = [UInt64]$partition.Size
            Size            = Convert-Size $partition.Size
            FileSystem      = $fileSystem
            Label           = $fileSystemLabel
            IsBoot          = $partition.IsBoot
            IsSystem        = $partition.IsSystem
        }
    }

    [pscustomobject]@{
        DiskNumber     = $disk.Number
        FriendlyName   = $disk.FriendlyName
        SerialNumber   = ([string]$disk.SerialNumber).Trim()
        BusType        = $disk.BusType
        PartitionStyle = $disk.PartitionStyle
        Operational    = ($disk.OperationalStatus -join ',')
        SizeBytes      = [UInt64]$disk.Size
        Size           = Convert-Size $disk.Size
        IsBoot         = $disk.IsBoot
        IsSystem       = $disk.IsSystem
        IsReadOnly     = $disk.IsReadOnly
        IsOffline      = $disk.IsOffline
        Partitions     = @($partitions)
    }
}

$secureBoot = try { Confirm-SecureBootUEFI } catch { $null }

$result = [pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    GeneratedAt  = (Get-Date).ToString('o')
    FirmwareType = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType
    SecureBoot   = $secureBoot
    Disks        = @($disks)
}

$disks | Select-Object DiskNumber, FriendlyName, SerialNumber, BusType, PartitionStyle, Size, IsBoot, IsSystem, IsReadOnly, IsOffline |
    Format-Table -AutoSize

foreach ($disk in $disks) {
    Write-Host "`nDisk $($disk.DiskNumber) - $($disk.FriendlyName) - $($disk.SerialNumber)" -ForegroundColor Cyan
    $disk.Partitions | Format-Table PartitionNumber, DriveLetter, Type, Size, FileSystem, Label, IsBoot, IsSystem -AutoSize
}

if ($ExportPath) {
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExportPath)
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolved -Encoding utf8
    Write-Host "`nInventaire exporté : $resolved" -ForegroundColor Green
}

$result
