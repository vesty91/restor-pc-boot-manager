<#
.SYNOPSIS
  Construit des images GPT/FAT32 virtuelles sous test\ pour QEMU.

.DESCRIPTION
  Le menu v1.0.0 est lu depuis config\refind.conf et theme\restor-pc du dépôt
  courant. Toutes les écritures restent dans test\. Aucun disque physique.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFile = $null
$script:CrcTable = $null
$SectorSize = 512
$DiskBytes = 64MB
$DiskSectors = [uint32]($DiskBytes / $SectorSize)
$PartitionStart = [uint32]2048
$ReservedSectors = [uint32]32
$SectorsPerCluster = [uint32]1
$NumberOfFats = [uint32]2

function Write-BuildStep {
    param([string]$Level, [string]$Message)
    $line = "[{0}] {1}" -f $Level, $Message
    Write-Host $line
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

function Assert-TestImagePath {
    param([Parameter(Mandatory)][string]$ImagePath, [Parameter(Mandatory)][string]$ProjectRoot)
    $full = [IO.Path]::GetFullPath($ImagePath)
    $testRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'test'))
    if (-not $full.StartsWith($testRoot + [IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Refus : l'image n'est pas sous test\ : " + $full)
    }
    if ((Split-Path -Parent $full) -ne $testRoot -or [IO.Path]::GetExtension($full) -ne '.img') {
        throw ("Refus : seule une image .img directement dans test\ est autorisée : " + $full)
    }
    if ($full -match 'PhysicalDrive|/dev/sd|/dev/nvme|\\\\\?\\Volume') {
        throw 'Refus : chemin de périphérique physique.'
    }
    return $full
}

function Get-Crc32 {
    param([byte[]]$Data, [int]$Length = -1)
    if ($Length -lt 0) { $Length = $Data.Length }
    $polynomial = [uint32]3988292384
    $crc = [uint32]::MaxValue
    for ($i = 0; $i -lt $Length; $i++) {
        $crc = [uint32]($crc -bxor $Data[$i])
        for ($bit = 0; $bit -lt 8; $bit++) {
            $shifted = $crc -shr 1
            if (($crc -band 1) -ne 0) { $crc = [uint32]($shifted -bxor $polynomial) }
            else { $crc = [uint32]$shifted }
        }
    }
    return [uint32]($crc -bxor ([uint32]::MaxValue))
}

function Write-UInt32 {
    param([byte[]]$Buffer, [int]$Offset, [uint32]$Value)
    $bytes = [BitConverter]::GetBytes($Value)
    [Array]::Copy($bytes, 0, $Buffer, $Offset, 4)
}

function Write-UInt16 {
    param([byte[]]$Buffer, [int]$Offset, [uint16]$Value)
    $bytes = [BitConverter]::GetBytes($Value)
    [Array]::Copy($bytes, 0, $Buffer, $Offset, 2)
}

function Get-ShortName {
    param([string]$Name, [hashtable]$Used)
    $upper = $Name.ToUpperInvariant()
    $dot = $upper.LastIndexOf('.')
    $base = $upper
    $extension = ''
    if ($dot -gt 0 -and $dot -lt ($upper.Length - 1)) {
        $base = $upper.Substring(0, $dot)
        $extension = $upper.Substring($dot + 1)
    }
    $clean = { param($Text) ($Text.ToUpperInvariant() -replace '[^A-Z0-9_$%''\-@~`!(){}^#&]', '') }
    $base = & $clean $base
    $extension = & $clean $extension
    if ($extension.Length -gt 3) { $extension = $extension.Substring(0, 3) }
    $fits = $base.Length -le 8 -and $base.Length -gt 0 -and ($upper -ceq ($base + $(if ($extension) { '.' + $extension } else { '' })))
    if ($fits) {
        $short = $base.PadRight(8).Substring(0, 8) + $extension.PadRight(3).Substring(0, 3)
        if (-not $Used.ContainsKey($short)) {
            $Used[$short] = $true
            return @{ Short = $short; UseLfn = ($Name -cne $upper); Original = $Name }
        }
    }
    $stem = $base
    if ([string]::IsNullOrWhiteSpace($stem)) { $stem = 'FILE' }
    if ($stem.Length -gt 6) { $stem = $stem.Substring(0, 6) }
    for ($index = 1; $index -lt 100000; $index++) {
        $suffix = '~' + $index
        $room = 8 - $suffix.Length
        $trimmed = $stem.Substring(0, [Math]::Min($stem.Length, $room))
        $short = ($trimmed + $suffix).PadRight(8).Substring(0, 8) + $extension.PadRight(3).Substring(0, 3)
        if (-not $Used.ContainsKey($short)) {
            $Used[$short] = $true
            return @{ Short = $short; UseLfn = $true; Original = $Name }
        }
    }
    throw ("Nom court impossible : " + $Name)
}

function Get-SfnChecksum {
    param([string]$ShortName)
    $sum = 0
    foreach ($byte in [Text.Encoding]::ASCII.GetBytes($ShortName)) {
        $sum = (((($sum -band 1) -shl 7) + ($sum -shr 1) + $byte) -band 0xFF)
    }
    return [byte]$sum
}

function New-DirectoryEntryBytes {
    param($Entries, [uint16]$Date, [uint16]$Time)
    $list = New-Object System.Collections.Generic.List[byte]
    foreach ($entry in $Entries) {
        $name = Get-ShortName -Name $entry.Name -Used $entry.Used
        if ($name.UseLfn -or $name.Original -cne $name.Original.ToUpperInvariant()) {
            $chars = New-Object System.Collections.Generic.List[uint16]
            foreach ($char in $name.Original.ToCharArray()) { $chars.Add([uint16][char]$char) }
            $chars.Add([uint16]0)
            while (($chars.Count % 13) -ne 0) { $chars.Add([uint16]0xFFFF) }
            $slots = [int]($chars.Count / 13)
            $checksum = Get-SfnChecksum -ShortName $name.Short
            for ($slot = $slots; $slot -ge 1; $slot--) {
                $record = New-Object byte[] 32
                $record[0] = [byte]$slot
                if ($slot -eq $slots) { $record[0] = [byte]($record[0] -bor 0x40) }
                $record[11] = 0x0F
                $record[13] = $checksum
                $sourceIndex = ($slot - 1) * 13
                $offsets = @(1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)
                for ($charIndex = 0; $charIndex -lt 13; $charIndex++) {
                    $value = $chars[$sourceIndex + $charIndex]
                    $record[$offsets[$charIndex]] = [byte]($value -band 0xFF)
                    $record[$offsets[$charIndex] + 1] = [byte](($value -shr 8) -band 0xFF)
                }
                $list.AddRange($record)
            }
        }
        $record = New-Object byte[] 32
        [Array]::Copy([Text.Encoding]::ASCII.GetBytes($name.Short), 0, $record, 0, 11)
        $record[11] = [byte]$entry.Attribute
        Write-UInt16 -Buffer $record -Offset 14 -Value $Time
        Write-UInt16 -Buffer $record -Offset 16 -Value $Date
        Write-UInt16 -Buffer $record -Offset 18 -Value $Date
        Write-UInt16 -Buffer $record -Offset 22 -Value $Time
        Write-UInt16 -Buffer $record -Offset 24 -Value $Date
        $cluster = [uint32]$entry.Cluster
        Write-UInt16 -Buffer $record -Offset 20 -Value ([uint16](($cluster -shr 16) -band 0xFFFF))
        Write-UInt16 -Buffer $record -Offset 26 -Value ([uint16]($cluster -band 0xFFFF))
        Write-UInt32 -Buffer $record -Offset 28 -Value ([uint32]$entry.Size)
        $list.AddRange($record)
    }
    return ,$list.ToArray()
}

function Add-TreeFiles {
    param($Map, [string]$SourceDirectory, [string]$DestinationDirectory)
    if (-not (Test-Path -LiteralPath $SourceDirectory)) { return }
    Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($SourceDirectory.Length).TrimStart('\')
        $display = ($DestinationDirectory.Trim('\') + '\' + $relative)
        $key = $display.ToUpperInvariant()
        if ($Map.ContainsKey($key)) { throw ("Fichier EFI en double : " + $display) }
        $Map[$key] = @{ Source = $_.FullName; Display = $display }
        Write-BuildStep 'INFO' ("Copie EFI " + $display.Replace('\', '/'))
    }
}

function New-FileTree {
    param([hashtable]$Files)
    $root = @{ Name = ''; IsDirectory = $true; Children = New-Object System.Collections.Generic.List[object]; Data = $null; FirstCluster = 0; Clusters = 0 }
    foreach ($key in ($Files.Keys | Sort-Object)) {
        $item = $Files[$key]
        $source = if ($item -is [string]) { $item } else { $item.Source }
        $display = if ($item -is [string]) { $key } else { $item.Display }
        $parts = $display -split '\\'
        $node = $root
        for ($index = 0; $index -lt ($parts.Count - 1); $index++) {
            $existing = $node.Children | Where-Object { $_.Name -eq $parts[$index] } | Select-Object -First 1
            if (-not $existing) {
                $existing = @{ Name = $parts[$index]; IsDirectory = $true; Children = New-Object System.Collections.Generic.List[object]; Data = $null; FirstCluster = 0; Clusters = 0 }
                $node.Children.Add($existing)
            }
            $node = $existing
        }
        $bytes = [IO.File]::ReadAllBytes($source)
        $node.Children.Add(@{ Name = $parts[-1]; IsDirectory = $false; Children = $null; Data = $bytes; FirstCluster = 0; Clusters = 0 })
    }
    return $root
}

function Get-NodeClusterCount {
    param($Node, [int]$ClusterBytes, [hashtable]$UsedNames)
    if (-not $Node.IsDirectory) {
        if ($Node.Data.Length -eq 0) { $Node.Clusters = 1 } else { $Node.Clusters = [int][Math]::Ceiling($Node.Data.Length / $ClusterBytes) }
        return
    }
    $entries = @()
    if ($Node.Name) { $entries += @(@{ Kind = 'dot' }, @{ Kind = 'dotdot' }) }
    foreach ($child in $Node.Children) {
        $entries += @{ Kind = 'child'; Name = $child.Name; Used = $UsedNames }
    }
    $bytes = (New-DirectoryEntryBytes -Entries @(
        foreach ($child in $Node.Children) {
            @{ Name = $child.Name; Attribute = $(if ($child.IsDirectory) { 0x10 } else { 0x20 }); Cluster = 0; Size = 0; Used = $UsedNames }
        }
    ) -Date 0 -Time 0).Length
    if ($Node.Name) { $bytes += 64 }
    if ($bytes -eq 0) { $bytes = 32 }
    $Node.Clusters = [int][Math]::Ceiling($bytes / $ClusterBytes)
    foreach ($child in $Node.Children) { Get-NodeClusterCount -Node $child -ClusterBytes $ClusterBytes -UsedNames @{} }
}

function Invoke-AllocateClusters {
    param($Node, $NextCluster, [uint32[]]$Fat)
    $first = [uint32]$NextCluster.Value
    $Node.FirstCluster = $first
    for ($index = 0; $index -lt $Node.Clusters; $index++) {
        $current = [uint32]$NextCluster.Value
        $NextCluster.Value = [uint32]($current + 1)
        if ($index -eq ($Node.Clusters - 1)) { $Fat[$current] = [uint32]0x0FFFFFFF } else { $Fat[$current] = $NextCluster.Value }
    }
    if ($Node.IsDirectory) {
        foreach ($child in $Node.Children) { Invoke-AllocateClusters -Node $child -NextCluster $NextCluster -Fat $Fat }
    }
}

function Write-ClusterBytes {
    param([byte[]]$Partition, [uint32]$Cluster, [byte[]]$Data, [uint32]$DataStartSector, [uint32]$SectorsPerCluster)
    $offset = [int](($DataStartSector + (($Cluster - 2) * $SectorsPerCluster)) * $SectorSize)
    [Array]::Copy($Data, 0, $Partition, $offset, $Data.Length)
}

function Write-Tree {
    param($Node, [byte[]]$Partition, [uint32]$DataStart, [uint16]$Date, [uint16]$Time, [hashtable]$UsedNames, [uint32]$ParentCluster)
    if (-not $Node.IsDirectory) {
        $clusterBytes = $SectorsPerCluster * $SectorSize
        for ($index = 0; $index -lt $Node.Clusters; $index++) {
            $start = $index * $clusterBytes
            $count = [Math]::Min($clusterBytes, $Node.Data.Length - $start)
            $chunk = New-Object byte[] $clusterBytes
            if ($count -gt 0) { [Array]::Copy($Node.Data, $start, $chunk, 0, $count) }
            Write-ClusterBytes -Partition $Partition -Cluster ([uint32]($Node.FirstCluster + $index)) -Data $chunk -DataStartSector $DataStart -SectorsPerCluster $SectorsPerCluster
        }
        return
    }
    $entries = New-Object System.Collections.Generic.List[object]
    if ($Node.Name) {
        $dot = New-Object byte[] 32
        [Array]::Copy([Text.Encoding]::ASCII.GetBytes('.          '), $dot, 11)
        $dot[11] = 0x10
        Write-UInt16 -Buffer $dot -Offset 20 -Value ([uint16](($Node.FirstCluster -shr 16) -band 0xFFFF))
        Write-UInt16 -Buffer $dot -Offset 26 -Value ([uint16]($Node.FirstCluster -band 0xFFFF))
        $dotdot = New-Object byte[] 32
        [Array]::Copy([Text.Encoding]::ASCII.GetBytes('..         '), $dotdot, 11)
        $dotdot[11] = 0x10
        Write-UInt16 -Buffer $dotdot -Offset 20 -Value ([uint16](($ParentCluster -shr 16) -band 0xFFFF))
        Write-UInt16 -Buffer $dotdot -Offset 26 -Value ([uint16]($ParentCluster -band 0xFFFF))
        $entries.Add($dot)
        $entries.Add($dotdot)
    }
    $childNames = @{}
    $renderedChildren = New-DirectoryEntryBytes -Entries @(
        foreach ($child in $Node.Children) {
            @{
                Name = $child.Name
                Attribute = $(if ($child.IsDirectory) { 0x10 } else { 0x20 })
                Cluster = $child.FirstCluster
                Size = $(if ($child.IsDirectory) { 0 } else { $child.Data.Length })
                Used = $childNames
            }
        }
    ) -Date $Date -Time $Time
    $directory = New-Object System.Collections.Generic.List[byte]
    foreach ($prefix in $entries) { $directory.AddRange($prefix) }
    if ($renderedChildren.Length -gt 0) { $directory.AddRange($renderedChildren) }
    $clusterBytes = $SectorsPerCluster * $SectorSize
    $raw = $directory.ToArray()
    $capacity = $Node.Clusters * $SectorsPerCluster * $SectorSize
    if ($raw.Length -gt $capacity) { throw ("Répertoire trop grand pour les clusters réservés : " + $Node.Name) }
    for ($index = 0; $index -lt $Node.Clusters; $index++) {
        $chunk = New-Object byte[] $clusterBytes
        $start = $index * $clusterBytes
        $count = [Math]::Min($clusterBytes, [Math]::Max(0, $raw.Length - $start))
        if ($count -gt 0) { [Array]::Copy($raw, $start, $chunk, 0, $count) }
        Write-ClusterBytes -Partition $Partition -Cluster ([uint32]($Node.FirstCluster + $index)) -Data $chunk -DataStartSector $DataStart -SectorsPerCluster $SectorsPerCluster
    }
    foreach ($child in $Node.Children) {
        Write-Tree -Node $child -Partition $Partition -DataStart $DataStart -Date $Date -Time $Time -UsedNames $childNames -ParentCluster $Node.FirstCluster
    }
}

function New-GptImage {
    param([byte[]]$Partition, [string]$ImagePath, [uint32]$PartitionSectors, [string]$PartitionName)
    $image = New-Object byte[] ($DiskSectors * $SectorSize)
    $mbr = New-Object byte[] 512
    $mbr[446] = 0x00
    $mbr[450] = 0xEE
    $mbr[451] = 0xFF
    $mbr[452] = 0xFF
    $mbr[453] = 0xFF
    Write-UInt32 -Buffer $mbr -Offset 454 -Value 1
    Write-UInt32 -Buffer $mbr -Offset 458 -Value ([uint32]($DiskSectors - 1))
    $mbr[510] = 0x55
    $mbr[511] = 0xAA
    [Array]::Copy($mbr, 0, $image, 0, 512)

    $entries = New-Object byte[] (128 * 128)
    $type = [guid]'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'
    $unique = [guid]::NewGuid()
    [Array]::Copy($type.ToByteArray(), 0, $entries, 0, 16)
    [Array]::Copy($unique.ToByteArray(), 0, $entries, 16, 16)
    Write-UInt32 -Buffer $entries -Offset 32 -Value $PartitionStart
    $lastLba = [uint64]$PartitionStart + [uint64]$PartitionSectors - 1
    $lastBytes = [BitConverter]::GetBytes($lastLba)
    [Array]::Copy($lastBytes, 0, $entries, 40, 8)
    $name = [Text.Encoding]::Unicode.GetBytes($PartitionName)
    [Array]::Copy($name, 0, $entries, 56, $name.Length)
    $entryCrc = Get-Crc32 -Data $entries
    $diskGuid = [guid]::NewGuid().ToByteArray()

    $backupHeaderLba = [uint64]($DiskSectors - 1)
    $backupEntriesLba = $backupHeaderLba - 32
    function New-GptHeader {
        param([uint64]$Current, [uint64]$Backup, [uint64]$EntriesLba)
        $header = New-Object byte[] 512
        [Array]::Copy([Text.Encoding]::ASCII.GetBytes('EFI PART'), 0, $header, 0, 8)
        Write-UInt32 -Buffer $header -Offset 8 -Value 0x00010000
        Write-UInt32 -Buffer $header -Offset 12 -Value 92
        $currentBytes = [BitConverter]::GetBytes($Current)
        $backupBytes = [BitConverter]::GetBytes($Backup)
        [Array]::Copy($currentBytes, 0, $header, 24, 8)
        [Array]::Copy($backupBytes, 0, $header, 32, 8)
        [Array]::Copy([BitConverter]::GetBytes([uint64]34), 0, $header, 40, 8)
        [Array]::Copy([BitConverter]::GetBytes([uint64]($backupEntriesLba - 1)), 0, $header, 48, 8)
        [Array]::Copy($diskGuid, 0, $header, 56, 16)
        [Array]::Copy([BitConverter]::GetBytes($EntriesLba), 0, $header, 72, 8)
        Write-UInt32 -Buffer $header -Offset 80 -Value 128
        Write-UInt32 -Buffer $header -Offset 84 -Value 128
        Write-UInt32 -Buffer $header -Offset 88 -Value $entryCrc
        $crc = Get-Crc32 -Data $header -Length 92
        Write-UInt32 -Buffer $header -Offset 16 -Value $crc
        return $header
    }
    $primary = New-GptHeader -Current 1 -Backup $backupHeaderLba -EntriesLba 2
    $backup = New-GptHeader -Current $backupHeaderLba -Backup 1 -EntriesLba $backupEntriesLba
    [Array]::Copy($primary, 0, $image, $SectorSize, 512)
    [Array]::Copy($entries, 0, $image, (2 * $SectorSize), $entries.Length)
    $partitionOffset = [int]($PartitionStart * $SectorSize)
    [Array]::Copy($Partition, 0, $image, $partitionOffset, $Partition.Length)
    [Array]::Copy($entries, 0, $image, ([int]($backupEntriesLba * $SectorSize)), $entries.Length)
    [Array]::Copy($backup, 0, $image, ([int]($backupHeaderLba * $SectorSize)), 512)
    [IO.File]::WriteAllBytes($ImagePath, $image)
}

function New-FatPartition {
    param($Root, [string]$VolumeLabel)
    $backupEntriesLba = ($DiskSectors - 1) - 32
    $lastUsable = [uint32]($backupEntriesLba - 1)
    $partitionSectors = [uint32]($lastUsable - $PartitionStart + 1)
    $tmp1 = [uint32]($partitionSectors - $ReservedSectors)
    $tmp2 = [uint32](((256 * $SectorsPerCluster) + $NumberOfFats) / 2)
    $fatSectors = [uint32][Math]::Floor(($tmp1 + $tmp2 - 1) / $tmp2)
    $dataSectors = [uint32]($tmp1 - ($NumberOfFats * $fatSectors))
    $clusterCount = [uint32][Math]::Floor($dataSectors / $SectorsPerCluster)
    if ($clusterCount -lt 65525) { throw ("FAT32 refusé : seulement $clusterCount clusters.") }
    $clusterBytes = $SectorsPerCluster * $SectorSize
    Get-NodeClusterCount -Node $Root -ClusterBytes $clusterBytes -UsedNames @{}
    $fatEntries = ($fatSectors * $SectorSize) / 4
    $fat = New-Object 'uint32[]' $fatEntries
    $fat[0] = [uint32]0x0FFFFFF8
    $fat[1] = [uint32]0x0FFFFFFF
    $cursor = @{ Value = [uint32]2 }
    Invoke-AllocateClusters -Node $Root -NextCluster $cursor -Fat $fat
    if ($cursor.Value -gt ($clusterCount + 2)) { throw 'La table FAT est trop petite pour les fichiers du projet.' }

    $partition = New-Object byte[] ($partitionSectors * $SectorSize)
    $boot = New-Object byte[] 512
    $boot[0] = 0xEB; $boot[1] = 0x58; $boot[2] = 0x90
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('MSWIN4.1'), 0, $boot, 3, 8)
    Write-UInt16 -Buffer $boot -Offset 11 -Value $SectorSize
    $boot[13] = [byte]$SectorsPerCluster
    Write-UInt16 -Buffer $boot -Offset 14 -Value ([uint16]$ReservedSectors)
    $boot[16] = [byte]$NumberOfFats
    $boot[21] = 0xF8
    Write-UInt16 -Buffer $boot -Offset 24 -Value 63
    Write-UInt16 -Buffer $boot -Offset 26 -Value 255
    Write-UInt32 -Buffer $boot -Offset 28 -Value $PartitionStart
    Write-UInt32 -Buffer $boot -Offset 32 -Value $partitionSectors
    Write-UInt32 -Buffer $boot -Offset 36 -Value $fatSectors
    Write-UInt32 -Buffer $boot -Offset 44 -Value 2
    Write-UInt16 -Buffer $boot -Offset 48 -Value 1
    Write-UInt16 -Buffer $boot -Offset 50 -Value 6
    $boot[64] = 0x80
    $boot[66] = 0x29
    Write-UInt32 -Buffer $boot -Offset 67 -Value 0x52455354
    $paddedLabel = $VolumeLabel.ToUpperInvariant()
    if ($paddedLabel.Length -gt 11) { throw ("Libellé FAT trop long : " + $VolumeLabel) }
    $paddedLabel = $paddedLabel.PadRight(11).Substring(0, 11)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes($paddedLabel), 0, $boot, 71, 11)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('FAT32   '), 0, $boot, 82, 8)
    $boot[510] = 0x55; $boot[511] = 0xAA
    [Array]::Copy($boot, 0, $partition, 0, 512)
    [Array]::Copy($boot, 0, $partition, (6 * $SectorSize), 512)
    $fsInfo = New-Object byte[] 512
    Write-UInt32 -Buffer $fsInfo -Offset 0 -Value 0x41615252
    Write-UInt32 -Buffer $fsInfo -Offset 484 -Value 0x61417272
    Write-UInt32 -Buffer $fsInfo -Offset 488 -Value ([uint32]::MaxValue)
    Write-UInt32 -Buffer $fsInfo -Offset 492 -Value ([uint32]$cursor.Value)
    Write-UInt32 -Buffer $fsInfo -Offset 508 -Value ([uint32]2857697280)
    [Array]::Copy($fsInfo, 0, $partition, $SectorSize, 512)

    $fatBytes = New-Object byte[] ($fatSectors * $SectorSize)
    for ($index = 0; $index -lt $fat.Length; $index++) {
        Write-UInt32 -Buffer $fatBytes -Offset ($index * 4) -Value $fat[$index]
    }
    $fatOffset = $ReservedSectors * $SectorSize
    [Array]::Copy($fatBytes, 0, $partition, $fatOffset, $fatBytes.Length)
    [Array]::Copy($fatBytes, 0, $partition, ($fatOffset + $fatBytes.Length), $fatBytes.Length)

    $now = Get-Date
    $date = [uint16]((($now.Year - 1980) -shl 9) -bor ($now.Month -shl 5) -bor $now.Day)
    $time = [uint16](($now.Hour -shl 11) -bor ($now.Minute -shl 5) -bor [Math]::Floor($now.Second / 2))
    $dataStart = [uint32]($ReservedSectors + ($NumberOfFats * $fatSectors))
    Write-Tree -Node $Root -Partition $partition -DataStart $dataStart -Date $date -Time $time -UsedNames @{} -ParentCluster 0
    return @{ Partition = $partition; PartitionSectors = $partitionSectors; FatSectors = $fatSectors; DataStart = $dataStart }
}

function Read-ImageFile {
    param([string]$ImagePath, [string]$RelativePath)
    $stream = [IO.File]::Open($ImagePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sector = New-Object byte[] 512
        $stream.Position = $SectorSize
        [void]$stream.Read($sector, 0, 512)
        $signature = [Text.Encoding]::ASCII.GetString($sector, 0, 8)
        if ($signature -ne 'EFI PART') { throw 'En-tête GPT absent.' }
        $stream.Position = 2 * $SectorSize
        $entry = New-Object byte[] 128
        [void]$stream.Read($entry, 0, 128)
        $start = [BitConverter]::ToUInt32($entry, 32)
        $boot = New-Object byte[] 512
        $stream.Position = $start * $SectorSize
        [void]$stream.Read($boot, 0, 512)
        if ($boot[510] -ne 0x55 -or $boot[511] -ne 0xAA) { throw 'Secteur de boot FAT32 invalide.' }
        $reserved = [BitConverter]::ToUInt16($boot, 14)
        $fats = $boot[16]
        $fatSectors = [BitConverter]::ToUInt32($boot, 36)
        $spc = $boot[13]
        $fat = New-Object byte[] ($fatSectors * $SectorSize)
        $stream.Position = ($start + $reserved) * $SectorSize
        [void]$stream.Read($fat, 0, $fat.Length)
        $dataStart = ($start + $reserved + ($fats * $fatSectors))
        function Read-Cluster([uint32]$Cluster) {
            $buffer = New-Object byte[] ($spc * $SectorSize)
            $stream.Position = ($dataStart + (($Cluster - 2) * $spc)) * $SectorSize
            [void]$stream.Read($buffer, 0, $buffer.Length)
            return ,$buffer
        }
        function Read-Chain([uint32]$Cluster) {
            $data = New-Object System.Collections.Generic.List[byte]
            $guard = 0
            while ($Cluster -ge 2 -and $Cluster -lt 0x0FFFFFF8) {
                $chunk = Read-Cluster $Cluster
                $data.AddRange([byte[]]$chunk)
                $Cluster = [BitConverter]::ToUInt32($fat, [int]($Cluster * 4))
                $guard++
                if ($guard -gt 100000) { throw 'Chaîne FAT trop longue.' }
            }
            return ,$data.ToArray()
        }
        function Get-LfnName([byte[]]$Record) {
            $chars = New-Object System.Collections.Generic.List[char]
            $offsets = @(1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)
            foreach ($offset in $offsets) {
                $value = [uint16]($Record[$offset] -bor ($Record[$offset + 1] -shl 8))
                if ($value -eq 0 -or $value -eq 0xFFFF) { break }
                $chars.Add([char]$value)
            }
            return -join $chars
        }
        $current = Read-Chain 2
        foreach ($part in ($RelativePath -split '\\')) {
            $offset = 0
            $lfn = ''
            $foundCluster = $null
            $foundSize = 0
            $foundDir = $false
            while ($offset + 32 -le $current.Length) {
                if ($current[$offset] -eq 0) { break }
                $record = New-Object byte[] 32
                [Array]::Copy($current, $offset, $record, 0, 32)
                $offset += 32
                if ($record[0] -eq 0xE5) { $lfn = ''; continue }
                if ($record[11] -eq 0x0F) { $lfn = (Get-LfnName $record) + $lfn; continue }
                $name8 = [Text.Encoding]::ASCII.GetString($record, 0, 8).TrimEnd()
                $ext3 = [Text.Encoding]::ASCII.GetString($record, 8, 3).TrimEnd()
                $sfn = if ($ext3) { $name8 + '.' + $ext3 } else { $name8 }
                $display = if ($lfn) { $lfn } else { $sfn }
                $lfn = ''
                if ($display -eq '.' -or $display -eq '..') { continue }
                if ($display -ieq $part) {
                    $foundCluster = [uint32]([BitConverter]::ToUInt16($record, 26) -bor ([BitConverter]::ToUInt16($record, 20) -shl 16))
                    $foundSize = [BitConverter]::ToUInt32($record, 28)
                    $foundDir = (($record[11] -band 0x10) -ne 0)
                    break
                }
            }
            if (-not $foundCluster) { return $null }
            $current = Read-Chain $foundCluster
            if (-not $foundDir) {
                if ($current.Length -lt $foundSize) { throw 'Fichier FAT tronqué.' }
                $exact = New-Object byte[] $foundSize
                [Array]::Copy($current, 0, $exact, 0, $foundSize)
                return ,$exact
            }
        }
        return ,$current
    } finally { $stream.Dispose() }
}

function Find-RefindDirectory {
    param([string]$ProjectRoot)
    $candidates = @(
        (Join-Path $ProjectRoot 'bootloader\refind\refind_x64.efi'),
        (Join-Path $ProjectRoot 'bootloader\refind_x64.efi')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return (Split-Path -Parent $candidate) }
    }
    $found = Get-ChildItem -LiteralPath $ProjectRoot -Filter 'refind_x64.efi' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(\.git|test)\\' } |
        Select-Object -First 1
    if ($found) { return $found.Directory.FullName }
    return $null
}

function New-TestEfiStub {
    param([Parameter(Mandatory)][string]$Marker)
    $file = New-Object byte[] 1024
    $file[0] = 0x4D
    $file[1] = 0x5A
    $file[0x3C] = 0x80
    $file[0x80] = 0x50
    $file[0x81] = 0x45
    $file[0x84] = 0x64
    $file[0x85] = 0x86
    $file[0x86] = 1
    $file[0x94] = 0xF0
    $file[0x96] = 0x22
    $file[0x97] = 0x02
    $file[0x98] = 0x0B
    $file[0x99] = 0x02
    Write-UInt32 -Buffer $file -Offset 0x9C -Value 512
    Write-UInt32 -Buffer $file -Offset 0xA8 -Value 0x1000
    Write-UInt32 -Buffer $file -Offset 0xAC -Value 0x1000
    Write-UInt32 -Buffer $file -Offset 0xB8 -Value 0x1000
    Write-UInt32 -Buffer $file -Offset 0xBC -Value 0x200
    Write-UInt32 -Buffer $file -Offset 0xD0 -Value 0x2000
    Write-UInt32 -Buffer $file -Offset 0xD4 -Value 0x200
    $file[0xDC] = 10
    Write-UInt32 -Buffer $file -Offset 0xE0 -Value 0x100000
    Write-UInt32 -Buffer $file -Offset 0xE8 -Value 0x1000
    Write-UInt32 -Buffer $file -Offset 0xF0 -Value 0x100000
    Write-UInt32 -Buffer $file -Offset 0xF8 -Value 0x1000
    Write-UInt32 -Buffer $file -Offset 0x104 -Value 16
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('.text'), 0, $file, 0x188, 5)
    Write-UInt32 -Buffer $file -Offset (0x188 + 8) -Value 512
    Write-UInt32 -Buffer $file -Offset (0x188 + 12) -Value 0x1000
    Write-UInt32 -Buffer $file -Offset (0x188 + 16) -Value 512
    Write-UInt32 -Buffer $file -Offset (0x188 + 20) -Value 0x200
    Write-UInt32 -Buffer $file -Offset (0x188 + 36) -Value 0x60000020
    $file[0x200] = 0x48
    $file[0x201] = 0x31
    $file[0x202] = 0xC0
    $file[0x203] = 0xC3
    $markerBytes = [Text.Encoding]::ASCII.GetBytes('RESTOR-PC-QEMU-TEST-STUB ' + $Marker)
    [Array]::Copy($markerBytes, 0, $file, 0x210, [Math]::Min($markerBytes.Length, 120))
    return ,$file
}

function Read-GptPartitionName {
    param([string]$ImagePath)
    $stream = [IO.File]::Open($ImagePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $entry = New-Object byte[] 128
        $stream.Position = 2 * $SectorSize
        [void]$stream.Read($entry, 0, 128)
        return [Text.Encoding]::Unicode.GetString($entry, 56, 72).Trim([char]0)
    } finally { $stream.Dispose() }
}

function Read-FatLabel {
    param([string]$ImagePath)
    $stream = [IO.File]::Open($ImagePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $boot = New-Object byte[] 512
        $stream.Position = $PartitionStart * $SectorSize
        [void]$stream.Read($boot, 0, 512)
        return [Text.Encoding]::ASCII.GetString($boot, 71, 11).Trim()
    } finally { $stream.Dispose() }
}

function Publish-VirtualDisk {
    param($Files, [string]$ImagePath, [string]$FatLabel, [string]$GptName)
    if (Test-Path -LiteralPath $ImagePath) {
        $existing = Get-Item -LiteralPath $ImagePath
        Write-BuildStep 'WARN' 'Remplacement limité à cette image virtuelle :'
        Write-BuildStep 'WARN' $ImagePath
        Write-BuildStep 'WARN' ("Taille actuelle : {0} octets." -f $existing.Length)
        Remove-Item -LiteralPath $ImagePath -Force
    }
    $tree = New-FileTree -Files $Files
    $built = New-FatPartition -Root $tree -VolumeLabel $FatLabel
    New-GptImage -Partition $built.Partition -ImagePath $ImagePath -PartitionSectors $built.PartitionSectors -PartitionName $GptName
    Write-BuildStep 'OK' ("Image {0} octets, FAT [{1}], GPT [{2}]" -f (Get-Item -LiteralPath $ImagePath).Length, (Read-FatLabel $ImagePath), (Read-GptPartitionName $ImagePath))
}

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$imagePath = Assert-TestImagePath -ImagePath (Join-Path $projectRoot 'test\restor-boot.img') -ProjectRoot $projectRoot
$logDirectory = Join-Path $projectRoot 'test\logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$script:LogFile = Join-Path $logDirectory ('build-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-BuildStep 'INFO' ("Projet : " + $projectRoot)
Write-BuildStep 'INFO' ("Image de test : " + $imagePath)

$refindDirectory = Find-RefindDirectory -ProjectRoot $projectRoot
$refindBinary = if ($refindDirectory) { Join-Path $refindDirectory 'refind_x64.efi' } else { $null }
if (-not $refindBinary -or -not (Test-Path -LiteralPath $refindBinary)) {
    Write-BuildStep 'ERROR' 'refind_x64.efi est absent du projet.'
    Write-BuildStep 'INFO' 'Placez le binaire officiel rEFInd ici : bootloader\refind\refind_x64.efi'
    Write-BuildStep 'INFO' 'Le script ne lit pas le NVMe RESTOR-PC pour le récupérer.'
    exit 1
}
$refindHash = (Get-FileHash -LiteralPath $refindBinary -Algorithm SHA256).Hash
Write-BuildStep 'OK' ("refind_x64.efi SHA256 " + $refindHash)
$configPath = Join-Path $projectRoot 'config\refind.conf'
$themePath = Join-Path $projectRoot 'theme\restor-pc'
$requiredSources = @(
    $configPath,
    (Join-Path $themePath 'theme.conf'),
    (Join-Path $themePath 'assets\background.png'),
    (Join-Path $themePath 'assets\win_code.png'),
    (Join-Path $themePath 'assets\win_vesty.png'),
    (Join-Path $themePath 'assets\memtest86plus.png'),
    (Join-Path $themePath 'assets\rescuegrid.png'),
    (Join-Path $themePath 'assets\lockpick.png')
)
foreach ($required in $requiredSources) {
    if (-not (Test-Path -LiteralPath $required)) {
        Write-BuildStep 'ERROR' ("Fichier requis absent : " + $required)
        exit 1
    }
}

$stubDirectory = Join-Path $projectRoot 'test\stubs'
New-Item -ItemType Directory -Path $stubDirectory -Force | Out-Null
$files = @{}
$files['EFI\BOOT\BOOTX64.EFI'] = @{ Source = $refindBinary; Display = 'EFI\BOOT\BOOTX64.EFI' }
$files['EFI\BOOT\refind.conf'] = @{ Source = $configPath; Display = 'EFI\BOOT\refind.conf' }
Write-BuildStep 'INFO' ("config\refind.conf du dépôt courant : " + $configPath)
Add-TreeFiles -Map $files -SourceDirectory $themePath -DestinationDirectory 'EFI\BOOT\themes\restor-pc'
Add-TreeFiles -Map $files -SourceDirectory (Join-Path $refindDirectory 'icons') -DestinationDirectory 'EFI\BOOT\icons'
Add-TreeFiles -Map $files -SourceDirectory (Join-Path $refindDirectory 'drivers_x64') -DestinationDirectory 'EFI\BOOT\drivers_x64'
Add-TreeFiles -Map $files -SourceDirectory (Join-Path $refindDirectory 'tools_x64') -DestinationDirectory 'EFI\BOOT\tools_x64'
$memtest = Get-ChildItem -LiteralPath $projectRoot -Filter 'mt86plus.efi' -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(\.git|test|bootloader)\\' } |
    Select-Object -First 1
$memtestPath = Join-Path $stubDirectory 'mt86plus.efi'
if ($memtest) {
    Copy-Item -LiteralPath $memtest.FullName -Destination $memtestPath -Force
    Write-BuildStep 'INFO' ("Copie locale de mt86plus.efi : " + $memtest.FullName)
    Write-BuildStep 'INFO' 'Ce binaire n''est pas exécuté ici. Le banc vérifie seulement son chemin.'
} else {
    [IO.File]::WriteAllBytes($memtestPath, (New-TestEfiStub -Marker 'MEMTEST86-PLUS'))
    Write-BuildStep 'WARN' 'mt86plus.efi est absent du dépôt. Un stub EFI TEST est utilisé. Ce n''est pas MemTest86+.'
}
$files['EFI\TOOLS\MEMTEST\MT86PLUS.EFI'] = @{ Source = $memtestPath; Display = 'EFI\TOOLS\MEMTEST\mt86plus.efi' }
Publish-VirtualDisk -Files $files -ImagePath $imagePath -FatLabel 'RESTOR-BOOT' -GptName 'RESTOR-BOOT'

$volumes = @(
    @{ Name = 'CODE-EFI'; File = 'code-efi.img'; Loader = 'EFI\Microsoft\Boot\bootmgfw.efi' },
    @{ Name = 'VESTY-EFI'; File = 'vesty-efi.img'; Loader = 'EFI\Microsoft\Boot\bootmgfw.efi' },
    @{ Name = 'RESCUE-EFI'; File = 'rescue-efi.img'; Loader = 'EFI\Microsoft\Boot\bootmgfw.efi' },
    @{ Name = 'LOCKPICK-EFI'; File = 'lockpick-efi.img'; Loader = 'EFI\BOOT\BOOTX64.EFI' }
)
foreach ($volume in $volumes) {
    $stubPath = Join-Path $stubDirectory ($volume.Name + '.efi')
    [IO.File]::WriteAllBytes($stubPath, (New-TestEfiStub -Marker $volume.Name))
    $fatLabel = if ($volume.Name -eq 'LOCKPICK-EFI') { 'LOCKPICK-EF' } else { $volume.Name }
    if ($volume.Name -eq 'LOCKPICK-EFI') {
        Write-BuildStep 'WARN' 'Le libellé FAT de LOCKPICK est LOCKPICK-EF. Le nom GPT reste LOCKPICK-EFI pour rEFInd.'
    }
    $volumeFiles = @{}
    $volumeFiles[$volume.Loader.ToUpperInvariant()] = @{ Source = $stubPath; Display = $volume.Loader }
    $volumeImage = Assert-TestImagePath -ImagePath (Join-Path $projectRoot ('test\' + $volume.File)) -ProjectRoot $projectRoot
    Publish-VirtualDisk -Files $volumeFiles -ImagePath $volumeImage -FatLabel $fatLabel -GptName $volume.Name
    $loader = Read-ImageFile -ImagePath $volumeImage -RelativePath $volume.Loader
    $loaderText = [Text.Encoding]::ASCII.GetString($loader)
    if ($loaderText -notmatch 'RESTOR-PC-QEMU-TEST-STUB') {
        Write-BuildStep 'ERROR' ("Stub absent de " + $volume.Name)
        exit 1
    }
    $gptName = Read-GptPartitionName -ImagePath $volumeImage
    if ($gptName -ne $volume.Name) {
        Write-BuildStep 'ERROR' ("Nom GPT [{0}] au lieu de {1}" -f $gptName, $volume.Name)
        exit 1
    }
    Write-BuildStep 'OK' ($volume.Name + ' simulé par ' + $volume.File)
}

function Assert-ImageMatchesSource {
    param([string]$Image, [string]$Relative, [string]$Source)
    $data = Read-ImageFile -ImagePath $Image -RelativePath $Relative
    if ($null -eq $data -or $data.Length -eq 0) { throw ("Fichier vide ou absent : " + $Relative) }
    $sourceBytes = [IO.File]::ReadAllBytes($Source)
    $sha = [Security.Cryptography.SHA256]::Create()
    $left = [BitConverter]::ToString($sha.ComputeHash($data)).Replace('-', '')
    $right = [BitConverter]::ToString($sha.ComputeHash($sourceBytes)).Replace('-', '')
    $sha.Dispose()
    if ($left -ne $right) { throw ("Contenu différent de la source actuelle : " + $Relative) }
    Write-BuildStep 'OK' ("Identique à la source : " + $Relative)
}
Assert-ImageMatchesSource -Image $imagePath -Relative 'EFI\BOOT\refind.conf' -Source $configPath
Assert-ImageMatchesSource -Image $imagePath -Relative 'EFI\BOOT\themes\restor-pc\theme.conf' -Source (Join-Path $themePath 'theme.conf')
foreach ($asset in @('background.png','win_code.png','win_vesty.png','memtest86plus.png','rescuegrid.png','lockpick.png')) {
    Assert-ImageMatchesSource -Image $imagePath -Relative ('EFI\BOOT\themes\restor-pc\assets\' + $asset) -Source (Join-Path $themePath ('assets\' + $asset))
}
$bootloader = Read-ImageFile -ImagePath $imagePath -Relative 'EFI\BOOT\BOOTX64.EFI'
$shaBoot = [Security.Cryptography.SHA256]::Create()
$bootHash = [BitConverter]::ToString($shaBoot.ComputeHash($bootloader)).Replace('-', '')
$shaBoot.Dispose()
if ($bootHash -ne $refindHash) {
    Write-BuildStep 'ERROR' 'BOOTX64.EFI ne correspond pas à refind_x64.efi.'
    exit 1
}
$configText = [Text.Encoding]::ASCII.GetString((Read-ImageFile -ImagePath $imagePath -Relative 'EFI\BOOT\refind.conf'))
foreach ($entryName in @('WIN CODE','WIN VESTY','MEMTEST86+','RESCUEGRID','LOCKPICK')) {
    $count = ([regex]::Matches($configText, [regex]::Escape('menuentry "' + $entryName + '"'))).Count
    if ($count -ne 1) {
        Write-BuildStep 'ERROR' ("Entrée {0} présente {1} fois." -f $entryName, $count)
        exit 1
    }
    Write-BuildStep 'OK' ("Entrée unique : " + $entryName)
}
if ($configText -notmatch 'volume "LOCKPICK-EFI"' -or $configText -notmatch 'volume "RESCUE-EFI"') {
    Write-BuildStep 'ERROR' 'Le refind.conf de l''image ne contient pas les volumes v1.0.0.'
    exit 1
}
Write-BuildStep 'OK' ("RESTOR-BOOT prêt : " + $imagePath)
exit 0
