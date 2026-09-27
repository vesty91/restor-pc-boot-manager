<#
.SYNOPSIS
  Cree un VHDX GPT de laboratoire avec cinq volumes EFI FAT32.
#>
[CmdletBinding()]
param(
    [string]$LabRoot,
    [switch]$KeepExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    $LabRoot = Join-Path $repoRoot 'test\vhd\restore-lab'
}
$PhysicalModel = 'SAMSUNG MZVLB256HAHQ-000L2'
$EfiType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:LabLog = $null

function Write-LabStep {
    param([string]$Level, [string]$Message)
    $line = "[{0}] {1}" -f $Level, $Message
    Write-Host $line
    if ($script:LabLog) { Add-Content -LiteralPath $script:LabLog -Value $line -Encoding utf8 }
}

function Assert-RestorAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'PowerShell administrateur requis pour le laboratoire VHDX.'
    }
}

function Resolve-RestorLabRoot {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Contains('..')) { throw 'Chemin de laboratoire refuse.' }
    $vhdParent = [IO.Path]::GetFullPath((Join-Path $repoRoot 'test\vhd'))
    $prefix = $vhdParent + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Le laboratoire doit rester sous test\vhd.'
    }
    if ($full.TrimEnd('\') -eq $vhdParent.TrimEnd('\')) { throw 'Le laboratoire ne peut pas etre test\vhd lui-meme.' }
    return $full
}

function Assert-RestorVirtualLabDisk {
    param(
        [Parameter(Mandatory)][string]$VhdPath,
        [Parameter(Mandatory)][int]$DiskNumber
    )
    $full = [IO.Path]::GetFullPath($VhdPath)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'VHDX absent.' }
    $image = Get-DiskImage -ImagePath $full
    if (-not $image.Attached) { throw 'VHDX non attache.' }
    $associated = Get-DiskImage -ImagePath $full | Get-Disk
    if ($null -eq $associated) { throw 'Aucun disque Windows associe au VHDX.' }
    if ([int]$associated.Number -ne $DiskNumber) { throw 'DiskNumber different du disque associe au VHDX.' }
    if ([bool]$associated.IsBoot) { throw 'Disque de demarrage refuse.' }
    if ([bool]$associated.IsSystem) { throw 'Disque systeme refuse.' }
    if ([string]$associated.FriendlyName -eq $PhysicalModel) { throw 'PHYSICAL RESTOR-PC NVME BLOCKED' }
    return $associated
}

function Get-RestorVhdBackend {
    if (Get-Command -Name New-VHD -ErrorAction SilentlyContinue) { return 'New-VHD' }
    foreach ($candidate in @(
        'C:\Program Files\qemu\qemu-img.exe',
        'C:\Program Files (x86)\qemu\qemu-img.exe'
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $command = Get-Command -Name qemu-img.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Invoke-RestorLabVhdFile {
    param([Parameter(Mandatory)][string]$VhdPath, [Parameter(Mandatory)][string]$Backend)
    if ($Backend -eq 'New-VHD') {
        New-VHD -Path $VhdPath -SizeBytes 4GB -Dynamic | Out-Null
        return
    }
    & $Backend create -f vhdx $VhdPath 4G
    if ($LASTEXITCODE -ne 0) { throw 'qemu-img n a pas pu creer le VHDX.' }
}

function Invoke-RestorVirtualDiskLayout {
    param(
        [Parameter(Mandatory)][string]$VhdPath,
        [Parameter(Mandatory)][int]$DiskNumber
    )
    $specs = @(
        @{ Name = 'RESTOR-BOOT'; Label = 'RESTOR-BOOT'; Size = 900MB },
        @{ Name = 'CODE-EFI'; Label = 'CODE-EFI'; Size = 500MB },
        @{ Name = 'VESTY-EFI'; Label = 'VESTY-EFI'; Size = 500MB },
        @{ Name = 'RESCUE-EFI'; Label = 'RESCUE-EFI'; Size = 500MB },
        @{ Name = 'LOCKPICK-EFI'; Label = 'LOCKPICK-EF'; Size = 900MB }
    )
    $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
    if ($disk.IsOffline) {
        $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
        Set-Disk -Number $DiskNumber -IsOffline $false
        $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
    }
    if ($disk.IsReadOnly) {
        $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
        Set-Disk -Number $DiskNumber -IsReadOnly $false
        $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
    }
    $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
    Write-LabStep 'OK' 'VHDX path validated'
    Write-LabStep 'OK' ("Virtual disk number: {0}" -f $disk.Number)
    Write-LabStep 'OK' 'IsBoot=False'
    Write-LabStep 'OK' 'IsSystem=False'
    Write-LabStep 'OK' 'Physical RESTOR-PC NVMe blocked'
    Write-LabStep 'OK' 'Safe to initialize virtual disk'
    if ([string]$disk.PartitionStyle -ne 'GPT') {
        $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
        Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false
    }
    $created = @()
    foreach ($spec in $specs) {
        $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
        $partition = New-Partition -DiskNumber $DiskNumber -Size $spec.Size -GptType $EfiType -AssignDriveLetter
        Start-Sleep -Milliseconds 400
        $partition = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber
        $letter = [string]$partition.DriveLetter
        if ($letter -notmatch '^[A-Za-z]$') {
            $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
            Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -AssignDriveLetter
            Start-Sleep -Milliseconds 400
            $partition = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber
            $letter = [string]$partition.DriveLetter
        }
        if ($letter -notmatch '^[A-Za-z]$') { throw ("Aucune lettre pour " + $spec.Name) }
        $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
        Format-Volume -DriveLetter $letter -FileSystem FAT32 -NewFileSystemLabel $spec.Label -Confirm:$false -Force | Out-Null
        $volume = Get-Volume -DriveLetter $letter
        $created += [pscustomobject]@{
            Name            = $spec.Name
            Label           = [string]$volume.FileSystemLabel
            DriveLetter     = $letter.ToUpperInvariant()
            PartitionNumber = [int]$partition.PartitionNumber
            Size            = [int64]$partition.Size
            GptType         = [string]$partition.GptType
            FileSystem      = [string]$volume.FileSystem
            DiskNumber      = $DiskNumber
        }
        Write-LabStep 'OK' ("{0} {1}: {2} {3}" -f $spec.Name, $letter.ToUpperInvariant(), $volume.FileSystem, $volume.FileSystemLabel)
    }
    return @($created)
}

function Get-RestorLabSizeTolerance {
    64MB
}

function Get-RestorExpectedVirtualSpec {
    @(
        @{ Name = 'RESTOR-BOOT'; Label = 'RESTOR-BOOT'; Size = 900MB },
        @{ Name = 'CODE-EFI'; Label = 'CODE-EFI'; Size = 500MB },
        @{ Name = 'VESTY-EFI'; Label = 'VESTY-EFI'; Size = 500MB },
        @{ Name = 'RESCUE-EFI'; Label = 'RESCUE-EFI'; Size = 500MB },
        @{ Name = 'LOCKPICK-EFI'; Label = 'LOCKPICK-EF'; Size = 900MB }
    )
}

function Get-RestorReusableVirtualLayout {
    param(
        [Parameter(Mandatory)][string]$VhdPath,
        [Parameter(Mandatory)][int]$DiskNumber
    )
    $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
    if ($disk.IsOffline) {
        $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
        Set-Disk -Number $DiskNumber -IsOffline $false
        $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
    }
    if ($disk.IsReadOnly) {
        $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
        Set-Disk -Number $DiskNumber -IsReadOnly $false
        $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
    }
    $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
    if ([string]$disk.PartitionStyle -ne 'GPT') {
        return [pscustomobject]@{ State = 'Empty'; Partitions = @() }
    }
    $partitions = @(Get-Partition -DiskNumber $DiskNumber | Where-Object { [string]$_.Type -ne 'Reserved' })
    if ($partitions.Count -eq 0) {
        return [pscustomobject]@{ State = 'Empty'; Partitions = @() }
    }
    $described = @()
    foreach ($partition in $partitions) {
        $letter = [string]$partition.DriveLetter
        if ($letter -notmatch '^[A-Za-z]$') {
            $disk = Assert-RestorVirtualLabDisk -VhdPath $VhdPath -DiskNumber $DiskNumber
            Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -AssignDriveLetter
            Start-Sleep -Milliseconds 400
            $partition = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber
            $letter = [string]$partition.DriveLetter
        }
        if ($letter -notmatch '^[A-Za-z]$') {
            throw 'Existing VHDX layout is invalid; recreate the lab without -KeepExisting.'
        }
        $volume = Get-Volume -DriveLetter $letter
        $described += [pscustomobject]@{
            Label           = ([string]$volume.FileSystemLabel).Trim()
            DriveLetter     = $letter.ToUpperInvariant()
            PartitionNumber = [int]$partition.PartitionNumber
            Size            = [int64]$partition.Size
            GptType         = [string]$partition.GptType
            FileSystem      = [string]$volume.FileSystem
            DiskNumber      = $DiskNumber
        }
    }
    $expected = @(Get-RestorExpectedVirtualSpec)
    if ($described.Count -ne $expected.Count) {
        throw 'Existing VHDX layout is invalid; recreate the lab without -KeepExisting.'
    }
    $inventory = @()
    $tolerance = Get-RestorLabSizeTolerance
    foreach ($spec in $expected) {
        $match = @($described | Where-Object { $_.Label -eq $spec.Label })
        if ($match.Count -ne 1) {
            throw 'Existing VHDX layout is invalid; recreate the lab without -KeepExisting.'
        }
        $item = $match[0]
        if (([string]$item.GptType).ToLowerInvariant() -ne $EfiType) {
            throw 'Existing VHDX layout is invalid; recreate the lab without -KeepExisting.'
        }
        if ([string]$item.FileSystem -ne 'FAT32') {
            throw 'Existing VHDX layout is invalid; recreate the lab without -KeepExisting.'
        }
        if ([math]::Abs([int64]$item.Size - [int64]$spec.Size) -gt [int64]$tolerance) {
            throw 'Existing VHDX layout is invalid; recreate the lab without -KeepExisting.'
        }
        $inventory += [pscustomobject]@{
            Name            = $spec.Name
            Label           = $item.Label
            DriveLetter     = $item.DriveLetter
            PartitionNumber = $item.PartitionNumber
            Size            = $item.Size
            GptType         = $item.GptType
            FileSystem      = $item.FileSystem
            DiskNumber      = $item.DiskNumber
        }
    }
    return [pscustomobject]@{ State = 'Valid'; Partitions = @($inventory) }
}

Assert-RestorAdministrator
$lab = Resolve-RestorLabRoot -Path $LabRoot
New-Item -ItemType Directory -Path $lab -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $lab 'logs') -Force | Out-Null
$script:LabLog = Join-Path $lab 'logs\lab-creation.log'
$vhdPath = Join-Path $lab 'restor-restore-lab.vhdx'
$backend = Get-RestorVhdBackend
if (-not $backend) {
    Write-LabStep 'ERROR' 'No supported VHDX creation backend available'
    Write-LabStep 'ERROR' 'Installez Hyper-V (New-VHD) ou QEMU (qemu-img.exe). Aucune fonctionnalite Windows n est activee automatiquement.'
    throw 'No supported VHDX creation backend available'
}
if ((Test-Path -LiteralPath $vhdPath) -and -not $KeepExisting) {
    $existing = Get-DiskImage -ImagePath $vhdPath -ErrorAction SilentlyContinue
    if ($existing -and $existing.Attached) { Dismount-DiskImage -ImagePath $vhdPath | Out-Null }
    Remove-Item -LiteralPath $vhdPath -Force
}
if (-not (Test-Path -LiteralPath $vhdPath)) {
    Write-LabStep 'INFO' ("Creation VHDX via {0}" -f $(if ($backend -eq 'New-VHD') { 'New-VHD' } else { 'qemu-img' }))
    Invoke-RestorLabVhdFile -VhdPath $vhdPath -Backend $backend
}
$image = Get-DiskImage -ImagePath $vhdPath -ErrorAction SilentlyContinue
if (-not $image -or -not $image.Attached) {
    Mount-DiskImage -ImagePath $vhdPath | Out-Null
}
$associated = Get-DiskImage -ImagePath $vhdPath | Get-Disk
$reusable = Get-RestorReusableVirtualLayout -VhdPath $vhdPath -DiskNumber ([int]$associated.Number)
if ($reusable.State -eq 'Valid') {
    Write-LabStep 'OK' 'Existing VHDX layout reused'
    $partitions = @($reusable.Partitions)
} elseif ($reusable.State -eq 'Empty') {
    $partitions = @(Invoke-RestorVirtualDiskLayout -VhdPath $vhdPath -DiskNumber ([int]$associated.Number))
} else {
    throw 'Existing VHDX layout is invalid; recreate the lab without -KeepExisting.'
}
$inventory = [ordered]@{
    VhdPath    = [IO.Path]::GetFullPath($vhdPath)
    DiskNumber = [int]$associated.Number
    Backend    = $(if ($backend -eq 'New-VHD') { 'New-VHD' } else { 'qemu-img' })
    Partitions = @($partitions)
}
$inventoryPath = Join-Path $lab 'lab-inventory.json'
$utf8 = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllText($inventoryPath, ($inventory | ConvertTo-Json -Depth 5), $utf8)
Write-LabStep 'OK' ("Inventaire : " + $inventoryPath)
return $inventory
