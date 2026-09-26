[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(0,255)]
    [int]$DiskNumber
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PngSize {
    param([string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $header = New-Object byte[] 24
        if ($stream.Read($header, 0, 24) -lt 24) { return $null }
        $signature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        for ($index = 0; $index -lt 8; $index++) {
            if ($header[$index] -ne $signature[$index]) { return $null }
        }
        if ([Text.Encoding]::ASCII.GetString($header, 12, 4) -ne 'IHDR') { return $null }
        $width = ([int]$header[16] -shl 24) -bor ([int]$header[17] -shl 16) -bor ([int]$header[18] -shl 8) -bor [int]$header[19]
        $height = ([int]$header[20] -shl 24) -bor ([int]$header[21] -shl 16) -bor ([int]$header[22] -shl 8) -bor [int]$header[23]
        return [pscustomobject]@{ Width = $width; Height = $height }
    } finally {
        $stream.Dispose()
    }
}

function Get-PartitionByLabel {
    param([int]$Disk,[string]$Label)
    foreach ($p in Get-Partition -DiskNumber $Disk) {
        $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
        if ($v -and $v.FileSystemLabel -eq $Label) { return $p }
    }
    return $null
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
    foreach ($disk in (Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
        if ($disk.DeviceID -match '^([A-Za-z]):$') { [void]$used.Add([char]$Matches[1].ToUpperInvariant()) }
    }
    foreach ($letter in 'R','S','T','W') {
        if (Test-Path -LiteralPath ($letter + ':\')) { [void]$used.Add([char]$letter) }
        if (-not $used.Contains([char]$letter)) { return $letter }
    }
    throw 'Aucune lettre temporaire libre (R, S, T, W).'
}

$disk = Get-Disk -Number $DiskNumber
$labels = 'RESTOR-BOOT','CODE-EFI','VESTY-EFI','RESTOR-TOOLS','RESCUE-EFI','LOCKPICK-EFI'
$parts = @{}

foreach ($label in $labels) {
    $p = Get-PartitionByLabel -Disk $DiskNumber -Label $label
    if (-not $p -and $label -eq 'LOCKPICK-EFI') {
        foreach ($candidate in (Get-Partition -DiskNumber $DiskNumber)) {
            if ($candidate.Type -eq 'Reserved') { continue }
            if ($candidate.Size -lt 900MB -or $candidate.Size -gt 1200MB) { continue }
            $probe = $candidate.DriveLetter
            $temporaryProbe = $false
            if (-not $probe) {
                $probe = Get-FreeDriveLetter
                Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $candidate.PartitionNumber -AccessPath ($probe + ':\')
                $temporaryProbe = $true
            }
            $hasLockpick = Test-Path -LiteralPath ($probe + ':\Programs\Lockpick\Lockpick.exe')
            if ($temporaryProbe) {
                Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $candidate.PartitionNumber -AccessPath ($probe + ':\') -ErrorAction SilentlyContinue
            }
            if ($hasLockpick) { $p = $candidate; break }
        }
    }
    if (-not $p) { throw ('Partition/volume manquant : ' + $label) }
    $parts[$label] = $p
}

$mounted = @()

function Mount-Temporary {
    param($Partition)
    if ($Partition.DriveLetter) { return ($Partition.DriveLetter + ':\') }
    $letter = Get-FreeDriveLetter
    $access = ($letter + ':\')
    Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath $access
    $script:mounted += [pscustomobject]@{ Partition=$Partition; Letter=$letter }
    return $access
}

try {
    $r = Mount-Temporary $parts['RESTOR-BOOT']
    $c = Mount-Temporary $parts['CODE-EFI']
    $v = Mount-Temporary $parts['VESTY-EFI']
    $rescue = Mount-Temporary $parts['RESCUE-EFI']
    $tools = Mount-Temporary $parts['RESTOR-TOOLS']
    $lock = Mount-Temporary $parts['LOCKPICK-EFI']
    $lockLetter = $lock.Substring(0, 1)
    $lockFat = [string](Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $lockLetter + ":'")).VolumeName
    if ($lockFat -ne 'LOCKPICK-EFI') {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RestorPartitionName {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(SafeFileHandle handle, uint code, IntPtr inBuffer, uint inSize, IntPtr outBuffer, uint outSize, out uint returned, IntPtr overlapped);
    public static string Read(string path) {
        var handle = CreateFile(path, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        var buffer = Marshal.AllocHGlobal(144);
        try {
            uint returned;
            if (!DeviceIoControl(handle, 0x00070048, IntPtr.Zero, 0, buffer, 144, out returned, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var data = new byte[72];
            Marshal.Copy(IntPtr.Add(buffer, 72), data, 0, 72);
            return System.Text.Encoding.Unicode.GetString(data).TrimEnd('\0');
        } finally { Marshal.FreeHGlobal(buffer); handle.Dispose(); }
    }
}
'@
        $gptName = [RestorPartitionName]::Read('\\.\' + $lockLetter + ':')
        if ($gptName -ne 'LOCKPICK-EFI') {
            throw ("Nom LOCKPICK-EFI absent. FAT=[" + $lockFat + "] GPT=[" + $gptName + "]")
        }
    }

    $checks = [ordered]@{
        'rEFInd'          = Join-Path $r 'EFI\BOOT\BOOTX64.EFI'
        'refind.conf'     = Join-Path $r 'EFI\BOOT\refind.conf'
        'theme.conf'      = Join-Path $r 'EFI\BOOT\themes\restor-pc\theme.conf'
        'WIN CODE icon'   = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\win_code.png'
        'WIN VESTY icon'  = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\win_vesty.png'
        'MemTest icon'    = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\memtest86plus.png'
        'rescuegrid.png'  = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\rescuegrid.png'
        'MemTest EFI'     = Join-Path $r 'EFI\TOOLS\MEMTEST\mt86plus.efi'
        'CODE bootmgfw'   = Join-Path $c 'EFI\Microsoft\Boot\bootmgfw.efi'
        'CODE BCD'        = Join-Path $c 'EFI\Microsoft\Boot\BCD'
        'VESTY bootmgfw'  = Join-Path $v 'EFI\Microsoft\Boot\bootmgfw.efi'
        'VESTY BCD'       = Join-Path $v 'EFI\Microsoft\Boot\BCD'
        'RESCUE bootmgfw' = Join-Path $rescue 'EFI\Microsoft\Boot\bootmgfw.efi'
        'RESCUE BCD'      = Join-Path $rescue 'EFI\Microsoft\Boot\BCD'
        'boot.wim'        = Join-Path $tools 'WinPE\RescueGrid\boot.wim'
        'boot.sdi'        = Join-Path $tools 'WinPE\RescueGrid\boot.sdi'
        'RescueGrid desktop' = Join-Path $tools 'RescueGrid\agent\windows\Setup-WinPEDesktop.ps1'
        'lockpick.png'    = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\lockpick.png'
        'LOCKPICK BOOTX64' = Join-Path $lock 'EFI\BOOT\BOOTX64.EFI'
        'LOCKPICK EFI BCD' = Join-Path $lock 'EFI\Microsoft\Boot\BCD'
        'LOCKPICK boot BCD' = Join-Path $lock 'boot\BCD'
        'LOCKPICK boot.sdi' = Join-Path $lock 'boot\boot.sdi'
        'LOCKPICK boot.wim' = Join-Path $lock 'sources\boot.wim'
        'LOCKPICK exe'    = Join-Path $lock 'Programs\Lockpick\Lockpick.exe'
    }

    $failed = $false
    foreach ($item in $checks.GetEnumerator()) {
        $ok = Test-Path -LiteralPath $item.Value
        if (-not $ok) { $failed = $true }
        [pscustomobject]@{
            Check = $item.Key
            Status = if ($ok) { 'OK' } else { 'MISSING' }
            Path = $item.Value
        }
    }

    $configPath = Join-Path $r 'EFI\BOOT\refind.conf'
    $configText = ''
    if (Test-Path -LiteralPath $configPath) {
        $configText = Get-Content -LiteralPath $configPath -Raw
    }
    foreach ($entryName in @('WIN CODE', 'WIN VESTY', 'MEMTEST86+', 'RESCUEGRID', 'LOCKPICK')) {
        $present = ([regex]::Matches($configText, [regex]::Escape('menuentry "' + $entryName + '"'))).Count -eq 1
        if (-not $present) { $failed = $true }
        [pscustomobject]@{
            Check = ('refind ' + $entryName)
            Status = if ($present) { 'OK' } else { 'MISSING' }
            Path = $configPath
        }
    }
    $lockEntryOk = $configText.Contains('volume "LOCKPICK-EFI"') -and $configText.Contains('loader \EFI\BOOT\BOOTX64.EFI')
    if (-not $lockEntryOk) { $failed = $true }
    [pscustomobject]@{
        Check = 'LOCKPICK loader'
        Status = if ($lockEntryOk) { 'OK' } else { 'MISSING' }
        Path = $configPath
    }

    $iconPath = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\lockpick.png'
    $iconSize = $null
    if (Test-Path -LiteralPath $iconPath) { $iconSize = Get-PngSize -Path $iconPath }
    $iconOk = ($null -ne $iconSize) -and ($iconSize.Width -eq 176) -and ($iconSize.Height -eq 176)
    if (-not $iconOk) { $failed = $true }
    $iconDetail = if ($iconOk) { '176x176' } elseif ($iconSize) { ('{0}x{1}' -f $iconSize.Width, $iconSize.Height) } else { 'PNG invalide ou absent' }
    [pscustomobject]@{
        Check = 'lockpick.png 176x176'
        Status = if ($iconOk) { 'OK' } else { 'MISSING' }
        Path = $iconDetail
    }

    $bcdPath = Join-Path $rescue 'EFI\Microsoft\Boot\BCD'
    $bcdOk = $false
    $bcdDetail = 'BCD RescueGrid illisible'
    if (Test-Path -LiteralPath $bcdPath) {
        $bcdText = (& bcdedit.exe /store $bcdPath /enum all /v | Out-String)
        $hasDescription = $bcdText.Contains('RESTOR-PC RESCUEGRID')
        $hasWim = $bcdText.Contains('\WinPE\RescueGrid\boot.wim')
        $hasSdi = $bcdText.Contains('\WinPE\RescueGrid\boot.sdi')
        $bcdOk = $hasDescription -and $hasWim -and $hasSdi
        $bcdDetail = if ($bcdOk) { 'RESTOR-PC RESCUEGRID -> WinPE\RescueGrid' } else { 'BCD sans cible WinPE RescueGrid' }
    }
    if (-not $bcdOk) { $failed = $true }
    [pscustomobject]@{
        Check = 'BCD RescueGrid'
        Status = if ($bcdOk) { 'OK' } else { 'MISSING' }
        Path = $bcdDetail
    }

    [pscustomobject]@{
        DiskNumber = $disk.Number
        FriendlyName = $disk.FriendlyName
        IsBoot = $disk.IsBoot
        IsSystem = $disk.IsSystem
        LargestFreeExtentGB = [math]::Round($disk.LargestFreeExtent / 1GB,2)
    }

    if ($failed) { throw 'Validation RESTOR-PC échouée.' }
    Write-Host 'Validation RESTOR-PC réussie.' -ForegroundColor Green
}
finally {
    foreach ($m in $mounted) {
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $m.Partition.PartitionNumber -AccessPath ($m.Letter + ':\') -ErrorAction SilentlyContinue
    }
}
