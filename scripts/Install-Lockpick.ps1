<#
.SYNOPSIS
  Installe le média Lockpick complet sur une nouvelle partition LOCKPICK-EFI.

.DESCRIPTION
  Identifie le NVMe RESTOR-PC par modèle et numéro de série.
  Crée une seule partition EFI de 1 Gio dans l'espace non alloué si LOCKPICK-EFI
  n'existe pas, copie le contenu intégral de l'ISO et ajoute l'entrée rEFInd
  LOCKPICK. Les partitions et BCD existants ne sont pas reconstruits.
#>
[CmdletBinding()]
param(
    [string]$ISOPath = 'C:\Users\Jeux\Restor-PC-Workspace\Lockpick.iso',

    [string]$ExpectedModel = 'SAMSUNG MZVLB256HAHQ-000L2',

    [string]$ExpectedSerial = '0025_3881_91C0_0621',

    [string]$ExpectedSha256 = '9D1AFC1D80B1F9FCB1CE530C292FB429E3E4E6E791CE5205019A2A233D1FD9DC',

    [string]$BackupRoot = 'C:\RESTOR-PC-BACKUP'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EfiType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$BasicType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$script:Mounted = @()
$script:DiskNumber = $null
$script:IsoMountedByScript = $false

function Write-Step {
    param([string]$Level, [string]$Message)
    Write-Host ("[{0}] {1}" -f $Level, $Message)
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Ouvrez PowerShell en administrateur.'
    }
}

function ConvertTo-NormalizedSerial {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value.Trim().TrimEnd('.').ToUpperInvariant())
}

function Get-FreeDriveLetter {
    $used = New-Object 'System.Collections.Generic.HashSet[char]'
    foreach ($volume in (Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter)) {
        [void]$used.Add([char]$volume.DriveLetter)
    }
    foreach ($partition in (Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
        $letterText = [string]$partition.DriveLetter
        if ($letterText -match '^[A-Za-z]$') { [void]$used.Add([char]$letterText.ToUpperInvariant()) }
    }
    foreach ($logical in (Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
        if ($logical.DeviceID -match '^([A-Za-z]):$') { [void]$used.Add([char]$Matches[1].ToUpperInvariant()) }
    }
    foreach ($letter in @('L','R','S','T','W')) {
        if (Test-Path -LiteralPath ($letter + ':\')) { [void]$used.Add([char]$letter) }
        if (-not $used.Contains([char]$letter)) { return $letter }
    }
    throw 'Aucune lettre temporaire libre (L, R, S, T, W).'
}

function Get-LogicalDisk {
    param([Parameter(Mandatory)][string]$Letter)
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $logical = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $Letter + ":'")
        if ($logical -and $logical.FileSystem) { return $logical }
        Start-Sleep -Milliseconds 400
    }
    throw ("Volume {0}: illisible après montage." -f $Letter)
}

function Mount-Temporary {
    param($Partition)
    if ($Partition.DriveLetter -and ([string]$Partition.DriveLetter) -match '^[A-Za-z]$') {
        return ([string]$Partition.DriveLetter).ToUpperInvariant()
    }
    $fresh = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $Partition.PartitionNumber
    if ($fresh.DriveLetter -and ([string]$fresh.DriveLetter) -match '^[A-Za-z]$') {
        return ([string]$fresh.DriveLetter).ToUpperInvariant()
    }
    $letter = Get-FreeDriveLetter
    Add-PartitionAccessPath -DiskNumber $script:DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath ($letter + ':\')
    $script:Mounted += [pscustomobject]@{ PartitionNumber = $Partition.PartitionNumber; Letter = $letter }
    return $letter
}

function Remove-TemporaryMounts {
    foreach ($mount in @($script:Mounted)) {
        Remove-PartitionAccessPath -DiskNumber $script:DiskNumber -PartitionNumber $mount.PartitionNumber -AccessPath ($mount.Letter + ':\') -ErrorAction SilentlyContinue
    }
    $script:Mounted = @()
}

function Get-SharedSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', ''))
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-VolumeFingerprint {
    param([Parameter(Mandatory)][string]$Root)
    $lines = New-Object System.Collections.Generic.List[string]
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch 'System Volume Information' } |
        Sort-Object FullName)
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\')
        try {
            $lines.Add(('{0}  {1}' -f (Get-SharedSha256 -Path $file.FullName), $relative))
        } catch {
            $item = Get-Item -LiteralPath $file.FullName -Force
            $lines.Add(('LOCKED {0} {1:o}  {2}' -f $item.Length, $item.LastWriteTimeUtc, $relative))
        }
    }
    return ($lines -join "`r`n")
}

function Get-RestorDisk {
    $expectedSerialNorm = ConvertTo-NormalizedSerial $ExpectedSerial
    $matches = @()
    foreach ($candidate in (Get-Disk)) {
        $serial = ConvertTo-NormalizedSerial ([string]$candidate.SerialNumber)
        $model = ([string]$candidate.FriendlyName).Trim()
        if ($model -eq $ExpectedModel.Trim() -and $serial -eq $expectedSerialNorm) {
            $matches += $candidate
        }
    }
    if ($matches.Count -ne 1) {
        $found = @(Get-Disk | ForEach-Object { '{0} | {1} | {2}' -f $_.Number, $_.FriendlyName, $_.SerialNumber }) -join "`n"
        throw ("NVMe RESTOR-PC introuvable ou ambigu.`nDisques vus :`n" + $found)
    }
    $disk = $matches[0]
    if ($disk.PartitionStyle -ne 'GPT') { throw 'Le NVMe RESTOR-PC n''est pas GPT.' }
    if ($disk.BusType -ne 'NVMe') { throw 'Le disque identifié n''est pas NVMe.' }
    return $disk
}

function Get-PartitionSnapshot {
    param([int]$Disk)
    @(Get-Partition -DiskNumber $Disk | Sort-Object PartitionNumber | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}' -f $_.PartitionNumber, $_.Offset, $_.Size, $_.GptType, $_.Guid
    })
}

function Assert-ExistingPartitionsUnchanged {
    param($Before, $After, [int]$AllowedNewNumber)
    foreach ($line in $Before) {
        $number = [int]($line.Split('|')[0])
        if ($number -eq $AllowedNewNumber) { continue }
        if ($After -notcontains $line) {
            throw ("Partition préexistante modifiée : " + $line)
        }
    }
    $extra = @($After | Where-Object { $Before -notcontains $_ })
    if ($AllowedNewNumber -ge 0) {
        $extra = @($extra | Where-Object { $_ -notmatch ('^{0}\|' -f $AllowedNewNumber) })
    }
    if ($extra.Count -gt 0) {
        throw ("Partition inattendue après l'opération : " + ($extra -join '; '))
    }
}

function Initialize-PartitionInfoType {
    if ('RestorPartitionInfo' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RestorPartitionInfo {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(SafeFileHandle handle, uint code, IntPtr inBuffer, uint inSize, IntPtr outBuffer, uint outSize, out uint returned, IntPtr overlapped);
    public static byte[] Get(string path) {
        var handle = CreateFile(path, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        var buffer = Marshal.AllocHGlobal(144);
        try {
            uint returned;
            if (!DeviceIoControl(handle, 0x00070048, IntPtr.Zero, 0, buffer, 144, out returned, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (returned != 144) throw new InvalidOperationException("Taille PARTITION_INFORMATION_EX = " + returned);
            var data = new byte[144];
            Marshal.Copy(buffer, data, 0, 144);
            return data;
        } finally { Marshal.FreeHGlobal(buffer); handle.Dispose(); }
    }
    public static void SetName(string path, byte[] info) {
        var handle = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        var buffer = Marshal.AllocHGlobal(info.Length);
        try {
            Marshal.Copy(info, 0, buffer, info.Length);
            uint returned;
            if (!DeviceIoControl(handle, 0x0007C04C, buffer, (uint)info.Length, buffer, (uint)info.Length, out returned, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.FreeHGlobal(buffer); handle.Dispose(); }
    }
}
'@
}

function Set-GptPartitionName {
    param($Partition, [string]$Name)
    Initialize-PartitionInfoType
    $disk = Get-RestorDisk
    if ($disk.Number -ne $script:DiskNumber) { throw 'Le numéro de disque a changé avant le renommage GPT.' }
    $fresh = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $Partition.PartitionNumber
    foreach ($existingLabel in @('RESTOR-BOOT','CODE-EFI','VESTY-EFI','RESTOR-TOOLS','RESCUE-EFI')) {
        if ($fresh.PartitionNumber -eq $resolved[$existingLabel].PartitionNumber) {
            throw ("Refus de renommer la partition existante " + $existingLabel)
        }
    }
    if (([string]$fresh.GptType).ToLowerInvariant() -ne $EfiType) { throw 'Refus : la partition Lockpick n''est pas de type EFI.' }
    if ($fresh.Size -lt 900MB -or $fresh.Size -gt 1200MB) { throw 'Refus : taille inattendue pour le nom GPT Lockpick.' }
    $before = Get-PartitionSnapshot -Disk $script:DiskNumber
    $letter = Mount-Temporary $fresh
    $path = '\\.\' + $letter + ':'
    $info = [RestorPartitionInfo]::Get($path)
    $offset = [BitConverter]::ToInt64($info, 8)
    $length = [BitConverter]::ToInt64($info, 16)
    $number = [BitConverter]::ToInt32($info, 24)
    if ($offset -ne [int64]$fresh.Offset -or $length -ne [int64]$fresh.Size -or $number -ne $fresh.PartitionNumber) {
        throw 'IOCTL partition : décalage, taille ou numéro inattendu. Nom non écrit.'
    }
    $typeBytes = ([guid]$EfiType).ToByteArray()
    $idBytes = ([guid]([string]$fresh.Guid)).ToByteArray()
    for ($i = 0; $i -lt 16; $i++) {
        if ($info[32 + $i] -ne $typeBytes[$i] -or $info[48 + $i] -ne $idBytes[$i]) {
            throw 'IOCTL partition : type ou GUID inattendu. Nom non écrit.'
        }
    }
    $setBuffer = New-Object byte[] 120
    $setBuffer[0] = 1
    [Array]::Copy($info, 32, $setBuffer, 8, 40)
    $chars = New-Object char[] 36
    $source = $Name.ToCharArray()
    [Array]::Copy($source, $chars, [Math]::Min($source.Length, 35))
    $nameBytes = [Text.Encoding]::Unicode.GetBytes($chars)
    [Array]::Copy($nameBytes, 0, $setBuffer, 48, 72)
    [RestorPartitionInfo]::SetName($path, $setBuffer)
    $check = [RestorPartitionInfo]::Get($path)
    for ($i = 0; $i -lt 72; $i++) {
        if ($check[$i] -ne $info[$i]) { throw 'Le renommage GPT a modifié autre chose que le nom.' }
    }
    $read = [Text.Encoding]::Unicode.GetString($check, 72, 72).Trim([char]0)
    if ($read -ne $Name) { throw ("Nom GPT relu = [{0}], attendu [{1}]." -f $read, $Name) }
    $after = Get-PartitionSnapshot -Disk $script:DiskNumber
    Assert-ExistingPartitionsUnchanged -Before $before -After $after -AllowedNewNumber -1
    Write-Step 'OK' ("Nom GPT de la partition : " + $read)
}

function Get-LabelForLetter {
    param([string]$Letter)
    $logical = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $Letter + ":'")
    if ($logical) { return [string]$logical.VolumeName }
    return ''
}

function Test-DefenderExclusionPresent {
    param([Parameter(Mandatory)][string]$Path)
    $expected = $Path.TrimEnd('\')
    $preferences = Get-MpPreference
    foreach ($item in @($preferences.ExclusionPath)) {
        if ($item -and ($item.TrimEnd('\') -ieq $expected)) { return $true }
    }
    return $false
}

function Get-PngSize {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $header = New-Object byte[] 24
        if ($stream.Read($header, 0, 24) -lt 24) { throw ("PNG trop court : " + $Path) }
        $signature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        for ($index = 0; $index -lt 8; $index++) {
            if ($header[$index] -ne $signature[$index]) { throw ("Signature PNG invalide : " + $Path) }
        }
        $chunk = [Text.Encoding]::ASCII.GetString($header, 12, 4)
        if ($chunk -ne 'IHDR') { throw ("Chunk IHDR absent : " + $Path) }
        $width = ([int]$header[16] -shl 24) -bor ([int]$header[17] -shl 16) -bor ([int]$header[18] -shl 8) -bor [int]$header[19]
        $height = ([int]$header[20] -shl 24) -bor ([int]$header[21] -shl 16) -bor ([int]$header[22] -shl 8) -bor [int]$header[23]
        return [pscustomobject]@{ Width = $width; Height = $height }
    } finally {
        $stream.Dispose()
    }
}

function Assert-LockpickPng {
    param([Parameter(Mandatory)][string]$Path)
    $size = Get-PngSize -Path $Path
    if ($size.Width -ne 176 -or $size.Height -ne 176) {
        throw ("lockpick.png fait {0}x{1}, 176x176 attendu : {2}" -f $size.Width, $size.Height, $Path)
    }
}

function Initialize-LockpickIconType {
    if ('LockpickIconExtract' -as [type]) { return }
    Add-Type -AssemblyName System.Drawing
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class LockpickIconExtract {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] icons, uint[] ids, uint count, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool DestroyIcon(IntPtr handle);
    public static Bitmap ExtractLargest(string file) {
        Bitmap best = null;
        int bestSize = 0;
        int[] sizes = new int[] { 256, 128, 64, 48, 32 };
        for (int index = 0; index < 4; index++) {
            foreach (int size in sizes) {
                IntPtr[] icons = new IntPtr[1];
                uint[] ids = new uint[1];
                uint found = PrivateExtractIcons(file, index, size, size, icons, ids, 1, 0);
                if (found == 0 || icons[0] == IntPtr.Zero) continue;
                try {
                    using (Icon icon = Icon.FromHandle(icons[0]))
                    using (Bitmap raw = icon.ToBitmap()) {
                        if (raw.Width > bestSize) {
                            if (best != null) best.Dispose();
                            best = new Bitmap(raw);
                            bestSize = raw.Width;
                        }
                    }
                } finally {
                    DestroyIcon(icons[0]);
                }
            }
        }
        return best;
    }
}
'@
}

function Save-ScaledLockpickPng {
    param(
        [Parameter(Mandatory)]$Image,
        [Parameter(Mandatory)][string]$Destination
    )
    $bitmap = New-Object System.Drawing.Bitmap 176, 176, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($Image, (New-Object System.Drawing.Rectangle 0, 0, 176, 176))
        $bitmap.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

Assert-Administrator
$projectRoot = Split-Path -Parent $PSScriptRoot
$iconDestinationInRepo = Join-Path $projectRoot 'theme\restor-pc\assets\lockpick.png'

if (-not (Test-Path -LiteralPath $ISOPath)) { throw ("ISO introuvable : " + $ISOPath) }
$isoItem = Get-Item -LiteralPath $ISOPath
$isoHash = (Get-FileHash -LiteralPath $ISOPath -Algorithm SHA256).Hash
Write-Step 'OK' ("ISO {0} octets, {1}, SHA256 {2}" -f $isoItem.Length, $isoItem.LastWriteTime.ToString('o'), $isoHash)
if ($isoHash -ne $ExpectedSha256.ToUpperInvariant()) {
    throw ("SHA256 ISO inattendu.`nLu : {0}`nAttendu : {1}" -f $isoHash, $ExpectedSha256)
}

$disk = Get-RestorDisk
$script:DiskNumber = $disk.Number
Write-Step 'OK' ("NVMe Disk {0} / {1} / {2} / GPT / libre {3:N2} Gio" -f $disk.Number, $disk.FriendlyName, $disk.SerialNumber, ($disk.LargestFreeExtent / 1GB))

$requiredLabels = @('RESTOR-BOOT','CODE-EFI','VESTY-EFI','RESTOR-TOOLS','RESCUE-EFI')
$resolved = @{}
$isoLetter = $null
try {
    foreach ($label in $requiredLabels) {
        $found = $null
        foreach ($partition in (Get-Partition -DiskNumber $disk.Number)) {
            $letter = $null
            if ($partition.DriveLetter -and ([string]$partition.DriveLetter) -match '^[A-Za-z]$') {
                $letter = ([string]$partition.DriveLetter).ToUpperInvariant()
            } else {
                $volume = Get-Volume -Partition $partition -ErrorAction SilentlyContinue
                if ($volume -and $volume.FileSystemLabel -eq $label) { $found = $partition; break }
            }
            if ($letter) {
                $logical = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $letter + ":'") -ErrorAction SilentlyContinue
                if ($logical -and [string]$logical.VolumeName -eq $label) { $found = $partition; break }
                $volume = Get-Volume -Partition $partition -ErrorAction SilentlyContinue
                if ($volume -and $volume.FileSystemLabel -eq $label) { $found = $partition; break }
            }
        }
        if (-not $found) {
            foreach ($partition in (Get-Partition -DiskNumber $disk.Number)) {
                if ($partition.Type -eq 'Reserved') { continue }
                $letter = Mount-Temporary $partition
                $name = Get-LabelForLetter $letter
                if ($name -eq $label) { $found = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber; break }
            }
        }
        if (-not $found) { throw ("Label introuvable sur le NVMe RESTOR-PC : " + $label) }
        $resolved[$label] = Get-Partition -DiskNumber $disk.Number -PartitionNumber $found.PartitionNumber
        Write-Step 'OK' ("Label " + $label + " partition " + $found.PartitionNumber)
    }

    $image = Get-DiskImage -ImagePath $ISOPath
    if (-not $image.Attached) {
        $image = Mount-DiskImage -ImagePath $ISOPath -PassThru
        $script:IsoMountedByScript = $true
    }
    $isoVolume = $image | Get-Volume
    if (-not $isoVolume.DriveLetter) { throw 'Lettre de Lockpick.iso introuvable.' }
    $isoLetter = [string]$isoVolume.DriveLetter
    $isoRoot = $isoLetter + ':\'
    $requiredIsoFiles = @(
        'EFI\BOOT\BOOTX64.EFI',
        'EFI\Microsoft\Boot\BCD',
        'boot\BCD',
        'boot\boot.sdi',
        'sources\boot.wim',
        'Programs\Lockpick\Lockpick.exe'
    )
    $sourceHashes = @{}
    foreach ($relative in $requiredIsoFiles) {
        $path = Join-Path $isoRoot $relative
        if (-not (Test-Path -LiteralPath $path)) { throw ("Fichier essentiel absent de l'ISO : " + $relative) }
    }
    foreach ($relative in @('EFI\BOOT\BOOTX64.EFI','boot\boot.sdi','sources\boot.wim','Programs\Lockpick\Lockpick.exe')) {
        $sourceHashes[$relative] = Get-SharedSha256 -Path (Join-Path $isoRoot $relative)
        Write-Step 'OK' ($relative + ' ' + $sourceHashes[$relative])
    }
    $wimItem = Get-Item -LiteralPath (Join-Path $isoRoot 'sources\boot.wim')
    $programsBytes = (Get-ChildItem -LiteralPath (Join-Path $isoRoot 'Programs') -Recurse -File -Force | Measure-Object Length -Sum).Sum
    Write-Step 'OK' ("boot.wim {0} octets, Programs {1} octets, EFI présent" -f $wimItem.Length, $programsBytes)

    $protectedBefore = @{}
    foreach ($label in @('CODE-EFI','VESTY-EFI','RESCUE-EFI')) {
        $letter = Mount-Temporary $resolved[$label]
        $protectedBefore[$label] = Get-VolumeFingerprint ($letter + ':\')
    }
    $restorLetter = Mount-Temporary $resolved['RESTOR-BOOT']
    $bootloaderPath = $restorLetter + ':\EFI\BOOT\BOOTX64.EFI'
    $bootloaderBefore = Get-SharedSha256 -Path $bootloaderPath

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $BackupRoot ($timestamp + '-pre-lockpick')
    New-Item -ItemType Directory -Path (Join-Path $backup 'Metadata') -Force | Out-Null
    $liveConfig = $restorLetter + ':\EFI\BOOT\refind.conf'
    $liveTheme = $restorLetter + ':\EFI\BOOT\themes\restor-pc\theme.conf'
    $liveAssets = $restorLetter + ':\EFI\BOOT\themes\restor-pc\assets'
    Copy-Item -LiteralPath $liveConfig -Destination (Join-Path $backup 'refind.conf') -Force
    if (Test-Path -LiteralPath $liveTheme) { Copy-Item -LiteralPath $liveTheme -Destination (Join-Path $backup 'theme.conf') -Force }
    if (Test-Path -LiteralPath $liveAssets) { Copy-Item -LiteralPath $liveAssets -Destination (Join-Path $backup 'assets') -Recurse -Force }
    Get-ChildItem -LiteralPath ($restorLetter + ':\') -Recurse -Force -ErrorAction SilentlyContinue |
        Select-Object FullName, Length, LastWriteTime |
        Export-Csv (Join-Path $backup 'Metadata\RESTOR-BOOT-files.csv') -NoTypeInformation -Encoding utf8
    Get-Content -LiteralPath $liveConfig -Raw | Set-Content (Join-Path $backup 'Metadata\refind-entries.txt') -Encoding utf8
    Get-Disk | Format-List * | Out-File (Join-Path $backup 'Metadata\Get-Disk.txt') -Encoding utf8
    Get-Partition | Select-Object DiskNumber, PartitionNumber, DriveLetter, Type, GptType, Guid, Offset, Size |
        Export-Csv (Join-Path $backup 'Metadata\Get-Partition.csv') -NoTypeInformation -Encoding utf8
    Get-Volume | Select-Object DriveLetter, FileSystemLabel, FileSystem, Size, SizeRemaining |
        Export-Csv (Join-Path $backup 'Metadata\Get-Volume.csv') -NoTypeInformation -Encoding utf8
    @(
        ('Model=' + $disk.FriendlyName),
        ('Serial=' + $disk.SerialNumber),
        ('Disk=' + $disk.Number),
        ('Style=' + $disk.PartitionStyle),
        ('ISO=' + $ISOPath),
        ('ISOSize=' + $isoItem.Length),
        ('ISOSHA256=' + $isoHash)
    ) | Set-Content (Join-Path $backup 'Metadata\identity.txt') -Encoding utf8
    $hashLines = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -LiteralPath $backup -Recurse -File | Where-Object { $_.Name -ne 'SHA256-MANIFEST.txt' } | ForEach-Object {
        $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
        $hashLines.Add(('{0}  {1}' -f $hash.Hash, $_.FullName.Substring($backup.Length).TrimStart('\')))
    }
    $hashLines | Set-Content (Join-Path $backup 'SHA256-MANIFEST.txt') -Encoding ascii
    Write-Step 'OK' ("Sauvegarde " + $backup)

    $disk = Get-RestorDisk
    if ($disk.Number -ne $script:DiskNumber) { throw 'Identité NVMe différente juste avant création.' }
    $knownNumbers = @(Get-Partition -DiskNumber $disk.Number | Select-Object -ExpandProperty PartitionNumber)
    $snapshotBeforeCreate = Get-PartitionSnapshot -Disk $disk.Number

    $lockPartition = $null
    foreach ($partition in (Get-Partition -DiskNumber $disk.Number)) {
        if ($partition.Type -eq 'Reserved') { continue }
        $letter = Mount-Temporary $partition
        $name = Get-LabelForLetter $letter
        $root = $letter + ':\'
        $lockFile = Join-Path $root 'Programs\Lockpick\Lockpick.exe'
        $hasRefind = Test-Path -LiteralPath (Join-Path $root 'EFI\BOOT\refind.conf')
        $foreign = @('RESTOR-BOOT','CODE-EFI','VESTY-EFI','RESTOR-TOOLS','RESCUE-EFI') -contains $name
        $gpt = ([string]$partition.GptType).ToLowerInvariant()
        $sizedEfi = $gpt -eq $EfiType -and $partition.Size -ge 900MB -and $partition.Size -le 1200MB
        $isLockpick = -not $hasRefind -and -not $foreign -and (
            $name -eq 'LOCKPICK-EFI' -or
            $name -eq 'LOCKPICK-EF' -or
            (Test-Path -LiteralPath $lockFile) -or
            ($sizedEfi -and [string]::IsNullOrWhiteSpace($name))
        )
        if ($isLockpick) {
            $lockPartition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber
            break
        }
    }
    if ($lockPartition) {
        Write-Step 'OK' ("LOCKPICK-EFI réutilisée, partition " + $lockPartition.PartitionNumber)
    } else {
        if ($disk.LargestFreeExtent -lt 2GB) { throw 'Espace non alloué insuffisant (moins de 2 Gio).' }
        if ($knownNumbers.Count -ne 6) {
            throw ("Refus de créer une partition : {0} partitions présentes, 6 attendues." -f $knownNumbers.Count)
        }
        Write-Step 'OK' 'Création de LOCKPICK-EFI dans l''espace non alloué.'
        $created = New-Partition -DiskNumber $disk.Number -Size 1GB -GptType $EfiType
        if ($knownNumbers -contains $created.PartitionNumber) { throw 'New-Partition a renvoyé une partition déjà existante.' }
        if ($created.Size -lt 900MB -or $created.Size -gt 1200MB) { throw ("Taille créée inattendue : " + $created.Size) }
        $createdType = ([string]$created.GptType).ToLowerInvariant()
        if ($createdType -ne $EfiType) { throw ("Type GPT créé : " + $createdType) }
        $snapshotAfterCreate = Get-PartitionSnapshot -Disk $disk.Number
        Assert-ExistingPartitionsUnchanged -Before $snapshotBeforeCreate -After $snapshotAfterCreate -AllowedNewNumber $created.PartitionNumber
        $lockPartition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $created.PartitionNumber
        $lockLetter = Mount-Temporary $lockPartition
        $volume = Get-Volume -Partition $lockPartition -ErrorAction SilentlyContinue
        if ($volume -and $volume.FileSystem) { throw 'La nouvelle partition possède déjà un système de fichiers.' }
        $formatError = $null
        try {
            Format-Volume -Partition $lockPartition -FileSystem FAT32 -NewFileSystemLabel 'LOCKPICK-EFI' -Confirm:$false -Force | Out-Null
        } catch {
            $formatError = $_.Exception.Message
        }
        if ($formatError) {
            Write-Step 'WARN' ("Format EFI direct refusé : " + $formatError)
            $beforeTypeChange = Get-PartitionSnapshot -Disk $disk.Number
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $created.PartitionNumber -GptType $BasicType
            try {
                Format-Volume -Partition (Get-Partition -DiskNumber $disk.Number -PartitionNumber $created.PartitionNumber) -FileSystem FAT32 -NewFileSystemLabel 'LOCKPICK-EFI' -Confirm:$false -Force | Out-Null
            } catch {
                Format-Volume -Partition (Get-Partition -DiskNumber $disk.Number -PartitionNumber $created.PartitionNumber) -FileSystem FAT32 -NewFileSystemLabel 'LOCKPICK-EF' -Confirm:$false -Force | Out-Null
            }
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $created.PartitionNumber -GptType $EfiType
            Assert-ExistingPartitionsUnchanged -Before $beforeTypeChange -After (Get-PartitionSnapshot -Disk $disk.Number) -AllowedNewNumber $created.PartitionNumber
        }
        $formatted = Get-LogicalDisk $lockLetter
        if ($formatted.FileSystem -ne 'FAT32') { throw ("Système de fichiers obtenu : " + $formatted.FileSystem) }
        Write-Step 'OK' ("LOCKPICK-EFI créée, partition " + $lockPartition.PartitionNumber + ", lettre " + $lockLetter)
    }

    $lockPartition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $lockPartition.PartitionNumber
    $lockLetter = Mount-Temporary $lockPartition
    $currentLabel = Get-LabelForLetter $lockLetter
    if ($currentLabel -ne 'LOCKPICK-EFI') {
        foreach ($candidateLabel in @('LOCKPICK-EFI','LOCKPICK-EF')) {
            try {
                Set-Volume -DriveLetter $lockLetter -NewFileSystemLabel $candidateLabel -ErrorAction Stop
                $currentLabel = Get-LabelForLetter $lockLetter
                if ($currentLabel -eq $candidateLabel) { break }
            } catch {
                Write-Step 'WARN' ("Libellé FAT " + $candidateLabel + " refusé : " + $_.Exception.Message)
            }
        }
    }
    if ($currentLabel -ne 'LOCKPICK-EFI') {
        Write-Step 'WARN' ("Libellé FAT relu [{0}]. Le nom GPT porte LOCKPICK-EFI." -f $currentLabel)
        Set-GptPartitionName -Partition $lockPartition -Name 'LOCKPICK-EFI'
    }

    $lockPartition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $lockPartition.PartitionNumber
    if (([string]$lockPartition.GptType).ToLowerInvariant() -ne $EfiType) { throw 'LOCKPICK-EFI n''est pas une partition EFI.' }
    $lockLetter = Mount-Temporary $lockPartition
    $owner = Get-Partition -DriveLetter $lockLetter
    if ($owner.DiskNumber -ne $script:DiskNumber -or $owner.PartitionNumber -ne $lockPartition.PartitionNumber) {
        throw 'La lettre Lockpick ne pointe pas vers le NVMe RESTOR-PC.'
    }
    $lockRoot = $lockLetter + ':\'
    $lockVolumePath = [string](Get-Volume -DriveLetter $lockLetter).Path
    if ($lockVolumePath) {
        Add-MpPreference -ExclusionPath $lockVolumePath
        $exclusionConfirmed = $false
        try {
            $exclusionConfirmed = Test-DefenderExclusionPresent -Path $lockVolumePath
        } catch {
            Write-Step 'WARN' ("Lecture des exclusions Defender impossible : " + $_.Exception.Message)
        }
        if ($exclusionConfirmed) {
            Write-Step 'OK' ("Exclusion Defender confirmée pour le volume Lockpick : " + $lockVolumePath)
        } else {
            Write-Step 'WARN' ("Exclusion Defender absente après Add-MpPreference : " + $lockVolumePath + ". Programs\Lockpick\Lockpick.exe peut être mis en quarantaine.")
        }
    } else {
        Write-Step 'WARN' 'Chemin de volume Lockpick introuvable. Aucune exclusion Defender ajoutée.'
    }
    $copyNeeded = $false
    foreach ($relative in $sourceHashes.Keys) {
        $destination = Join-Path $lockRoot $relative
        if (-not (Test-Path -LiteralPath $destination)) { $copyNeeded = $true; break }
        try {
            $existingHash = Get-SharedSha256 -Path $destination
        } catch {
            $copyNeeded = $true
            break
        }
        if ($existingHash -ne $sourceHashes[$relative]) { $copyNeeded = $true; break }
    }
    if ($copyNeeded) {
        Write-Step 'OK' ("Copie intégrale de " + $isoRoot + " vers " + $lockRoot)
        & robocopy $isoRoot $lockRoot /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XJ /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw ("Robocopy a échoué (code {0})." -f $LASTEXITCODE) }
    } else {
        Write-Step 'OK' 'Contenu Lockpick déjà conforme, copie non refaite.'
    }
    foreach ($relative in $requiredIsoFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $lockRoot $relative))) {
            throw ("Fichier absent après copie : " + $relative)
        }
    }
    foreach ($relative in $sourceHashes.Keys) {
        $destinationPath = Join-Path $lockRoot $relative
        try {
            $destinationHash = Get-SharedSha256 -Path $destinationPath
        } catch {
            throw ("Lecture impossible de {0} : {1}" -f $destinationPath, $_.Exception.Message)
        }
        if ($destinationHash -ne $sourceHashes[$relative]) {
            throw ("SHA256 différent pour {0}`nISO {1}`nDestination {2}" -f $relative, $sourceHashes[$relative], $destinationHash)
        }
        Write-Step 'OK' ("Hash identique " + $relative)
    }
    $lockLogical = Get-LogicalDisk $lockLetter
    Write-Step 'OK' ("Partition {0} octets, libre {1} octets, libellé [{2}]" -f $lockLogical.Size, $lockLogical.FreeSpace, $lockLogical.VolumeName)

    if (Test-Path -LiteralPath $iconDestinationInRepo) {
        Assert-LockpickPng -Path $iconDestinationInRepo
        Write-Step 'OK' 'Icône versionnée lockpick.png conservée, aucune régénération.'
    } else {
        Write-Step 'WARN' 'theme\restor-pc\assets\lockpick.png est absent. Génération de secours.'
        Initialize-LockpickIconType
        $iconDirectory = Split-Path -Parent $iconDestinationInRepo
        if (-not (Test-Path -LiteralPath $iconDirectory)) { New-Item -ItemType Directory -Path $iconDirectory | Out-Null }
        $lockpickExecutable = Join-Path $isoRoot 'Programs\Lockpick\Lockpick.exe'
        $extracted = $null
        if (Test-Path -LiteralPath $lockpickExecutable) {
            $extracted = [LockpickIconExtract]::ExtractLargest($lockpickExecutable)
        }
        if ($extracted) {
            try { Save-ScaledLockpickPng -Image $extracted -Destination $iconDestinationInRepo }
            finally { $extracted.Dispose() }
            Write-Step 'OK' 'Icône de secours extraite depuis Lockpick.exe.'
        } else {
            $iconSource = Join-Path $isoRoot 'Programs\Lockpick\autorun.ico'
            if (-not (Test-Path -LiteralPath $iconSource)) { throw 'Aucune icône Lockpick disponible.' }
            $sourceImage = [System.Drawing.Image]::FromFile($iconSource)
            try { Save-ScaledLockpickPng -Image $sourceImage -Destination $iconDestinationInRepo }
            finally { $sourceImage.Dispose() }
            Write-Step 'OK' 'Icône de secours produite depuis autorun.ico.'
        }
        Assert-LockpickPng -Path $iconDestinationInRepo
    }
    $assetDir = $restorLetter + ':\EFI\BOOT\themes\restor-pc\assets'
    if (-not (Test-Path -LiteralPath $assetDir)) { throw 'Dossier d''assets rEFInd introuvable.' }
    $installedIcon = Join-Path $assetDir 'lockpick.png'
    $sourceIconHash = (Get-FileHash -LiteralPath $iconDestinationInRepo -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $iconDestinationInRepo -Destination $installedIcon -Force
    $installedIconHash = (Get-FileHash -LiteralPath $installedIcon -Algorithm SHA256).Hash
    if ($installedIconHash -ne $sourceIconHash) {
        throw ("SHA256 lockpick.png différent après copie.`nDépôt : {0}`nRESTOR-BOOT : {1}" -f $sourceIconHash, $installedIconHash)
    }
    Write-Step 'OK' ("lockpick.png copié, SHA256 " + $installedIconHash)

    $configBackup = $liveConfig + '.bak-' + $timestamp
    Copy-Item -LiteralPath $liveConfig -Destination $configBackup -Force
    $entry = @"
menuentry "LOCKPICK" {
    icon \EFI\BOOT\themes\restor-pc\assets\lockpick.png
    volume "LOCKPICK-EFI"
    loader \EFI\BOOT\BOOTX64.EFI
}
"@
    $configText = [IO.File]::ReadAllText($liveConfig)
    $pattern = '(?ms)^menuentry "LOCKPICK" \{.*?^\}[ \t]*\r?\n?'
    if ($configText.Contains('menuentry "LOCKPICK"')) {
        $updated = [regex]::Replace($configText, $pattern, ($entry.TrimEnd() + "`r`n"), 1)
    } else {
        if (-not $configText.EndsWith("`n")) { $configText += "`r`n" }
        $updated = $configText + "`r`n" + $entry.TrimEnd() + "`r`n"
    }
    foreach ($name in @('WIN CODE','WIN VESTY','MEMTEST86+','RESCUEGRID','LOCKPICK')) {
        $count = ([regex]::Matches($updated, [regex]::Escape('menuentry "' + $name + '"'))).Count
        if ($count -ne 1) { throw ("Entrée rEFInd {0} présente {1} fois." -f $name, $count) }
    }
    if (-not $updated.Contains('volume "LOCKPICK-EFI"') -or -not $updated.Contains('loader \EFI\BOOT\BOOTX64.EFI')) {
        throw 'Entrée LOCKPICK incomplète.'
    }
    [IO.File]::WriteAllText($liveConfig, $updated, (New-Object System.Text.ASCIIEncoding))
    if ((Get-SharedSha256 -Path $bootloaderPath) -ne $bootloaderBefore) {
        throw 'BOOTX64.EFI de rEFInd a changé.'
    }
    Write-Step 'OK' 'Entrée rEFInd LOCKPICK écrite.'

    foreach ($label in @('CODE-EFI','VESTY-EFI','RESCUE-EFI')) {
        $letter = Mount-Temporary $resolved[$label]
        $after = Get-VolumeFingerprint ($letter + ':\')
        if ($after -ne $protectedBefore[$label]) { throw ($label + ' a été modifié.') }
        Write-Step 'OK' ($label + ' inchangé.')
    }

    $testScript = Join-Path $PSScriptRoot 'Test-RestorBootManager.ps1'
    & $testScript -DiskNumber $script:DiskNumber
    Write-Step 'OK' 'Test-RestorBootManager.ps1 réussi.'
    Write-Step 'OK' ("LOCKPICK-EFI partition " + $lockPartition.PartitionNumber + " taille " + $lockPartition.Size)
}
finally {
    Remove-TemporaryMounts
    if ($script:IsoMountedByScript) {
        Dismount-DiskImage -ImagePath $ISOPath -ErrorAction SilentlyContinue | Out-Null
    } else {
        Dismount-DiskImage -ImagePath $ISOPath -ErrorAction SilentlyContinue | Out-Null
    }
}
