<#
.SYNOPSIS
  Recree le layout GPT RESTOR-PC sur un disque vierge, puis restaure le Golden Backup.

.DESCRIPTION
  OUTIL DESTRUCTIF. Refuse tout disque deja partitionne, IsBoot, IsSystem,
  ou dont l'identite ne correspond pas. Aucune commande de nettoyage
  destructif de disque n'est utilisee.

  Sans -Apply et -ConfirmRebuild "REBUILD-RESTOR-PC", reste en dry-run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [int]$DiskNumber,
    [Parameter(Mandatory)]
    [string]$BackupPath,
    [string]$ExpectedModel = 'SAMSUNG MZVLB256HAHQ-000L2',
    [AllowEmptyString()]
    [string]$ExpectedSerial = '0025_3881_91C0_0621',
    [switch]$Apply,
    [string]$ConfirmRebuild = '',
    [string]$ResultPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\RestorPc.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\RestorPc.Backup.psm1') -Force

$EfiType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$MsrType = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
$BasicType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$started = Get-Date
$script:PartitionsCreated = New-Object System.Collections.ArrayList

function Write-Step {
    param([string]$Level, [string]$Message)
    Write-Host ("[{0}] {1}" -f $Level, $Message)
}

function Invoke-RestorRecoveryBcd {
    param([Parameter(Mandatory)][string]$Arguments)
    Write-Step 'INFO' ("bcdedit " + $Arguments)
    $output = & cmd.exe /c ("bcdedit " + $Arguments)
    foreach ($line in @($output)) { if ($line) { Write-Host $line } }
    if ($LASTEXITCODE -ne 0) {
        throw ("bcdedit a echoue (code {0}) : {1}" -f $LASTEXITCODE, $Arguments)
    }
    return @($output)
}

function Update-RestorRescueGridBcd {
    param(
        [Parameter(Mandatory)][string]$RescueLetter,
        [Parameter(Mandatory)][string]$ToolsLetter,
        [Parameter(Mandatory)][string]$BackupRoot
    )
    if ($RescueLetter -notmatch '^[A-Za-z]$' -or $ToolsLetter -notmatch '^[A-Za-z]$') {
        throw 'Lettres Rescue/Tools invalides pour retarget BCD.'
    }
    if ($RescueLetter -eq 'C' -or $ToolsLetter -eq 'C') {
        throw 'Refus retarget BCD sur C:.'
    }

    $bcdDir = Join-Path ($RescueLetter + ':\') 'EFI\Microsoft\Boot'
    $store = Join-Path $bcdDir 'BCD'
    if (-not (Test-Path -LiteralPath $store -PathType Leaf)) {
        $backupBcd = Join-Path $BackupRoot 'BCD\RESCUE-EFI\BCD'
        if (Test-Path -LiteralPath $backupBcd -PathType Leaf) {
            New-Item -ItemType Directory -Path $bcdDir -Force | Out-Null
            Copy-Item -LiteralPath $backupBcd -Destination $store -Force
        }
    }

    $probe = ''
    $readable = $false
    if (Test-Path -LiteralPath $store -PathType Leaf) {
        $probe = & bcdedit.exe /store $store /enum all /v 2>&1 | Out-String
        $readable = ($LASTEXITCODE -eq 0)
    }

    if (-not $readable) {
        Write-Step 'INFO' 'BCD RescueGrid illisible ou absent. Creation d un magasin neuf (createstore)...'
        New-Item -ItemType Directory -Path $bcdDir -Force | Out-Null
        Get-ChildItem -LiteralPath $bcdDir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'BCD*' } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Invoke-RestorRecoveryBcd ("/createstore `"{0}`"" -f $store)
        Invoke-RestorRecoveryBcd ("/store `"{0}`" /create {{bootmgr}} /d `"Windows Boot Manager`"" -f $store) | Out-Null
        Invoke-RestorRecoveryBcd ("/store `"{0}`" /set {{bootmgr}} device boot" -f $store) | Out-Null
        $probe = & bcdedit.exe /store $store /enum all /v | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw 'bcdedit ne peut pas lire le BCD RESCUE-EFI apres createstore.'
        }
    }

    if ($probe -notmatch 'ae5534e0-51f0-11dd-93e7-001560b44f3a') {
        Invoke-RestorRecoveryBcd ("/store `"{0}`" /create {{ramdiskoptions}} /d `"Ramdisk Options`"" -f $store) | Out-Null
    }
    Invoke-RestorRecoveryBcd ("/store `"{0}`" /set {{ramdiskoptions}} ramdisksdidevice partition={1}:" -f $store, $ToolsLetter) | Out-Null
    Invoke-RestorRecoveryBcd ("/store `"{0}`" /set {{ramdiskoptions}} ramdisksdipath \WinPE\RescueGrid\boot.sdi" -f $store) | Out-Null

    $guid = $null
    $osloaderEnum = & bcdedit.exe /store $store /enum osloader /v | Out-String
    # Language-agnostic: GUID of the object whose description is RESTOR-PC RESCUEGRID,
    # without relying on localized Identificateur/Identifier headings.
    $guidMatch = [regex]::Match(
        $osloaderEnum,
        '(?is)(\{[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\})(?:(?!\{[0-9a-fA-F]{8}).)*?RESTOR-PC RESCUEGRID'
    )
    if ($guidMatch.Success) {
        $guid = $guidMatch.Groups[1].Value
    }
    if ([string]::IsNullOrWhiteSpace($guid)) {
        $created = Invoke-RestorRecoveryBcd ("/store `"{0}`" /create /d `"RESTOR-PC RESCUEGRID`" /application osloader" -f $store)
        $createdText = $created -join "`n"
        $guidMatch = [regex]::Match($createdText, '\{[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}')
        if (-not $guidMatch.Success) { throw 'GUID RESTOR-PC RESCUEGRID introuvable apres create.' }
        $guid = $guidMatch.Value
    }

    # Canonical loader + bootmgr settings for both existing and newly created entries.
    Invoke-RestorRecoveryBcd ("/store `"{0}`" /set {1} path \Windows\System32\Boot\winload.efi" -f $store, $guid) | Out-Null
    Invoke-RestorRecoveryBcd ("/store `"{0}`" /set {1} systemroot \Windows" -f $store, $guid) | Out-Null
    Invoke-RestorRecoveryBcd ("/store `"{0}`" /set {1} winpe yes" -f $store, $guid) | Out-Null
    Invoke-RestorRecoveryBcd ("/store `"{0}`" /set {1} detecthal yes" -f $store, $guid) | Out-Null
    Invoke-RestorRecoveryBcd ("/store `"{0}`" /displayorder {1} /addlast" -f $store, $guid) | Out-Null
    Invoke-RestorRecoveryBcd ("/store `"{0}`" /default {1}" -f $store, $guid) | Out-Null
    Invoke-RestorRecoveryBcd ("/store `"{0}`" /timeout 0" -f $store) | Out-Null

    $wimArg = ("ramdisk=[{0}:]\WinPE\RescueGrid\boot.wim,{{ramdiskoptions}}" -f $ToolsLetter)
    Invoke-RestorRecoveryBcd ("/store `"{0}`" /set {1} device {2}" -f $store, $guid, $wimArg) | Out-Null
    Invoke-RestorRecoveryBcd ("/store `"{0}`" /set {1} osdevice {2}" -f $store, $guid, $wimArg) | Out-Null

    $entryProbe = & bcdedit.exe /store $store /enum $guid /v | Out-String
    if ($LASTEXITCODE -ne 0 -or $entryProbe -notmatch 'RESTOR-PC RESCUEGRID') {
        throw ("BCD RescueGrid : l entree {0} n est pas RESTOR-PC RESCUEGRID." -f $guid)
    }
    foreach ($token in @(
            '\Windows\System32\Boot\winload.efi',
            '\Windows',
            '\WinPE\RescueGrid\boot.wim'
        )) {
        if ($entryProbe -notmatch [regex]::Escape($token)) {
            throw ("BCD RescueGrid : jeton canonique absent de {0} : {1}" -f $guid, $token)
        }
    }
    if ($entryProbe -notmatch '(?i)\bwinpe\b' -or $entryProbe -notmatch '(?i)\byes\b') {
        throw ("BCD RescueGrid : winpe yes manquant sur {0}." -f $guid)
    }
    if ($entryProbe -notmatch [regex]::Escape(('[{0}:]' -f $ToolsLetter)) -and $entryProbe -notmatch [regex]::Escape(('partition={0}:' -f $ToolsLetter))) {
        throw ("BCD RescueGrid : device non retargete vers {0}: pour {1}." -f $ToolsLetter, $guid)
    }
    $finalBcd = & bcdedit.exe /store $store /enum all /v | Out-String
    foreach ($token in @('RESTOR-PC RESCUEGRID', '\WinPE\RescueGrid\boot.wim', '\WinPE\RescueGrid\boot.sdi')) {
        if (-not $finalBcd.Contains($token)) {
            throw ("BCD RescueGrid incomplet apres retarget, jeton absent : " + $token)
        }
    }
    Write-Step 'OK' ("BCD RescueGrid retargete vers {0}:\WinPE\RescueGrid ({1})" -f $ToolsLetter, $guid)
}

function Get-RestorBackupTreeByteSize {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [int64]0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction Stop | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [int64]0 }
    return [int64]$sum
}

function Test-RestorRecoveryPayloadFits {
    param([Parameter(Mandatory)][string]$BackupRoot)
    $checks = @(
        @{ Name = 'RESTOR-BOOT'; Relative = 'ESP\RESTOR-BOOT'; Size = [int64]1GB; Factor = 0.90 },
        @{ Name = 'CODE-EFI'; Relative = 'ESP\CODE-EFI'; Size = [int64]512MB; Factor = 0.90 },
        @{ Name = 'VESTY-EFI'; Relative = 'ESP\VESTY-EFI'; Size = [int64]512MB; Factor = 0.90 },
        @{ Name = 'RESCUE-EFI'; Relative = 'ESP\RESCUE-EFI'; Size = [int64]512MB; Factor = 0.90 },
        @{ Name = 'LOCKPICK-EFI'; Relative = 'ESP\LOCKPICK-EFI'; Size = [int64]1GB; Factor = 0.90 },
        @{ Name = 'RESTOR-TOOLS'; Relative = 'RESTOR-TOOLS'; Size = [int64]64GB; Factor = 0.98 }
    )
    foreach ($check in $checks) {
        $source = Join-Path $BackupRoot $check.Relative
        $bytes = Get-RestorBackupTreeByteSize -Path $source
        $usable = [int64]([math]::Floor([double]$check.Size * [double]$check.Factor))
        if ($bytes -gt $usable) {
            throw ("Payload {0} trop volumineux pour la partition reconstruite ({1} octets > {2} utilisables sur {3})." -f $check.Name, $bytes, $usable, $check.Size)
        }
        Write-Step 'OK' ("Payload {0} : {1} octets / {2} utilisables." -f $check.Name, $bytes, $usable)
    }
}

function Get-RestorBlankDiskCandidate {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Serial
    )
    $disk = Get-Disk -Number $Number -ErrorAction Stop
    if ($null -eq $disk) { throw 'Disque introuvable.' }
    if ([bool]$disk.IsBoot) { throw 'Disque de demarrage refuse.' }
    if ([bool]$disk.IsSystem) { throw 'Disque systeme refuse.' }
    $modelName = ([string]$disk.FriendlyName).Trim()
    $serialValue = ConvertTo-NormalizedSerial ([string]$disk.SerialNumber)
    $expectedSerial = ConvertTo-NormalizedSerial $Serial
    if ($modelName -ne $Model.Trim()) {
        throw ("Modele inattendu : {0}" -f $modelName)
    }
    if ($serialValue -ne $expectedSerial) {
        throw ("Numero de serie inattendu : {0}" -f $serialValue)
    }
    $style = [string]$disk.PartitionStyle
    if ($style -eq 'RAW') {
        return [pscustomobject]@{ Disk = $disk; State = 'Raw' }
    }
    if ($style -eq 'GPT') {
        $nonReserved = @(Get-Partition -DiskNumber $Number -ErrorAction Stop | Where-Object { [string]$_.Type -ne 'Reserved' })
        if ($nonReserved.Count -eq 0) {
            return [pscustomobject]@{ Disk = $disk; State = 'EmptyGpt' }
        }
    }
    throw 'Disque deja partitionne. Reconstruction refusee. Aucune destruction automatique.'
}

function New-RestorRecoveryPartition {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][uint64]$Size,
        [Parameter(Mandatory)][string]$GptType,
        [Parameter(Mandatory)][string]$FileSystem,
        [Parameter(Mandatory)][string]$Label,
        [switch]$AssignLetter
    )
    if ($AssignLetter) {
        $partition = New-Partition -DiskNumber $Number -Size $Size -GptType $GptType -AssignDriveLetter
    } else {
        $partition = New-Partition -DiskNumber $Number -Size $Size -GptType $GptType
    }
    Start-Sleep -Milliseconds 400
    $partitionNumber = [int]$partition.PartitionNumber
    $letter = ''
    if ($null -ne $partition.PSObject.Properties['DriveLetter'] -and $null -ne $partition.DriveLetter) {
        $rawLetter = [string]$partition.DriveLetter
        if ($rawLetter -match '^[A-Za-z]$') { $letter = $rawLetter }
    }
    if ($AssignLetter -and $letter -notmatch '^[A-Za-z]$') {
        $refreshed = Get-Partition -DiskNumber $Number -PartitionNumber $partitionNumber
        if ($null -ne $refreshed) {
            $partition = $refreshed
            if ($null -ne $partition.PSObject.Properties['DriveLetter'] -and $null -ne $partition.DriveLetter) {
                $rawLetter = [string]$partition.DriveLetter
                if ($rawLetter -match '^[A-Za-z]$') { $letter = $rawLetter }
            }
        }
    }
    if ($AssignLetter) {
        if ($letter -notmatch '^[A-Za-z]$') {
            Add-PartitionAccessPath -DiskNumber $Number -PartitionNumber $partitionNumber -AssignDriveLetter
            Start-Sleep -Milliseconds 400
            $partition = Get-Partition -DiskNumber $Number -PartitionNumber $partitionNumber
            if ($null -eq $partition) { throw ("Partition introuvable apres creation : " + $Name) }
            $letter = ''
            if ($null -ne $partition.PSObject.Properties['DriveLetter'] -and $null -ne $partition.DriveLetter) {
                $rawLetter = [string]$partition.DriveLetter
                if ($rawLetter -match '^[A-Za-z]$') { $letter = $rawLetter }
            }
        }
        if ($letter -notmatch '^[A-Za-z]$') { throw ("Aucune lettre pour " + $Name) }
        if ($FileSystem -eq 'FAT32') {
            Format-Volume -DriveLetter $letter -FileSystem FAT32 -NewFileSystemLabel $Label -Confirm:$false -Force | Out-Null
        } else {
            Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false -Force | Out-Null
        }
        Set-RestorRecoveryGptName -Letter $letter -Name $Name -ExpectedGptType $GptType
        $volume = Get-Volume -DriveLetter $letter
        [void]$script:PartitionsCreated.Add([pscustomobject]@{
            Name            = $Name
            Label           = [string]$volume.FileSystemLabel
            DriveLetter     = $letter.ToUpperInvariant()
            PartitionNumber = [int]$partition.PartitionNumber
            Size            = [int64]$partition.Size
            GptType         = [string]$partition.GptType
            FileSystem      = [string]$volume.FileSystem
        })
        Write-Step 'OK' ("{0} {1}: {2} {3}" -f $Name, $letter.ToUpperInvariant(), $volume.FileSystem, $volume.FileSystemLabel)
        return
    }
    [void]$script:PartitionsCreated.Add([pscustomobject]@{
        Name            = $Name
        Label           = $Label
        DriveLetter     = ''
        PartitionNumber = [int]$partition.PartitionNumber
        Size            = [int64]$partition.Size
        GptType         = [string]$partition.GptType
        FileSystem      = ''
    })
    Write-Step 'OK' ("{0} cree (MSR)" -f $Name)
}

function Initialize-RestorGptNameType {
    if ('RestorRecoveryGptName' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RestorRecoveryGptName {
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

function Set-RestorRecoveryGptName {
    param(
        [Parameter(Mandatory)][string]$Letter,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ExpectedGptType
    )
    Initialize-RestorGptNameType
    $path = '\\.\' + $Letter + ':'
    $info = [RestorRecoveryGptName]::Get($path)
    $typeBytes = ([guid]$ExpectedGptType).ToByteArray()
    for ($i = 0; $i -lt 16; $i++) {
        if ($info[32 + $i] -ne $typeBytes[$i]) {
            throw ("Type GPT inattendu avant renommage de {0}." -f $Name)
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
    [RestorRecoveryGptName]::SetName($path, $setBuffer)
    $check = [RestorRecoveryGptName]::Get($path)
    $read = [Text.Encoding]::Unicode.GetString($check, 72, 72).Trim([char]0)
    if ($read -ne $Name) {
        throw ("Nom GPT relu = [{0}], attendu [{1}]." -f $read, $Name)
    }
    Write-Step 'OK' ("Nom GPT : " + $Name)
}

function Write-RestorRecoveryResult {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Payload
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($Path, ($Payload | ConvertTo-Json -Depth 8), $utf8)
}

$writeAllowed = $Apply -and $ConfirmRebuild -ceq 'REBUILD-RESTOR-PC'
if ($Apply -and -not $writeAllowed) {
    Write-Step 'WARN' 'Confirmation refusee. La phrase exacte est REBUILD-RESTOR-PC. Aucune modification.'
}
if (-not $writeAllowed) {
    Write-Step 'INFO' 'Mode : simulation. Aucune partition n est creee.'
}

$root = [IO.Path]::GetFullPath($BackupPath)
Write-Step 'INFO' 'Full Golden Backup integrity verification...'
$integrity = Test-RestorBackupIntegrity -BackupPath $root
if (-not $integrity.Valid) {
    Write-Step 'ERROR' 'Golden Backup integrity verification failed'
    foreach ($item in @($integrity.Failures)) { Write-Step 'ERROR' ([string]$item) }
    throw 'Reconstruction refusee : Golden Backup invalid.'
}
Write-Step 'OK' ("Golden Backup integrity verified: {0} files" -f $integrity.FilesVerified)
$manifestHash = [string]$integrity.ManifestSha256Actual
$manifestSnapshot = @(Get-RestorManifestSnapshot -BackupPath $root)

$candidate = Get-RestorBlankDiskCandidate -Number $DiskNumber -Model $ExpectedModel -Serial $ExpectedSerial
$disk = $candidate.Disk
$layoutBytes = [int64](16MB + 1GB + 512MB + 512MB + 64GB + 512MB + 1GB + 64MB)
# Raw: capacity is disk.Size. EmptyGpt: usable space is LargestFreeExtent after any Reserved/MSR.
$freeBytes = if ($candidate.State -eq 'EmptyGpt') {
    [int64]$disk.LargestFreeExtent
} else {
    [int64]$disk.Size
}
if ($freeBytes -lt $layoutBytes) {
    throw ("Espace libre insuffisant pour le layout RESTOR-PC ({0} octets libres, {1} requis)." -f $freeBytes, $layoutBytes)
}
Test-RestorRecoveryPayloadFits -BackupRoot $root
if ($candidate.State -eq 'EmptyGpt') {
    $reserved = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop | Where-Object {
        [string]$_.Type -eq 'Reserved' -or ([string]$_.GptType).ToLowerInvariant() -eq $MsrType.ToLowerInvariant()
    })
    foreach ($entry in $reserved) {
        if ([int64]$entry.Size -gt 128MB) {
            throw ("Partition Reserved trop grande ({0} octets). Reconstruction refusee." -f [int64]$entry.Size)
        }
    }
}
Write-Step 'OK' ("Disque cible valide, etat {0}, numero {1}." -f $candidate.State, $disk.Number)

$layoutPreview = @(
    'MSR 16 MiB',
    'RESTOR-BOOT EFI FAT32 1 GiB',
    'CODE-EFI EFI FAT32 512 MiB',
    'VESTY-EFI EFI FAT32 512 MiB',
    'RESTOR-TOOLS NTFS 64 GiB',
    'RESCUE-EFI EFI FAT32 512 MiB',
    'LOCKPICK-EFI EFI FAT32 1 GiB',
    'reste non alloue'
)
foreach ($line in $layoutPreview) { Write-Step 'INFO' ("Layout : " + $line) }

if (-not $writeAllowed) {
    Write-Step 'OK' 'Dry-run. -Apply et -ConfirmRebuild REBUILD-RESTOR-PC sont requis pour reconstruire.'
    Exit-RestorCommand -Code 0
}

Test-RestorAdministrator
$status = 'FAILED'
$filesRestored = 0
$filesVerified = 0
$hashMismatches = New-Object System.Collections.Generic.List[string]
$reportPath = if ([string]::IsNullOrWhiteSpace($ResultPath)) {
    Join-Path ([IO.Path]::GetFullPath((Join-Path $root '..'))) ('RECOVERY-RESULT-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
} else {
    [IO.Path]::GetFullPath($ResultPath)
}

try {
    if ($candidate.State -eq 'Raw') {
        Write-Step 'INFO' 'Initialize-Disk GPT...'
        Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -Confirm:$false
        Write-Step 'OK' 'GPT initialized'
    }

    $existingMsr = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop | Where-Object {
        [string]$_.Type -eq 'Reserved' -or ([string]$_.GptType).ToLowerInvariant() -eq $MsrType.ToLowerInvariant()
    })
    if ($existingMsr.Count -eq 0) {
        New-RestorRecoveryPartition -Number $DiskNumber -Name 'MSR' -Size 16MB -GptType $MsrType -FileSystem '' -Label 'MSR'
    } else {
        $msr = $existingMsr[0]
        [void]$script:PartitionsCreated.Add([pscustomobject]@{
            Name            = 'MSR'
            Label           = 'MSR'
            DriveLetter     = ''
            PartitionNumber = [int]$msr.PartitionNumber
            Size            = [int64]$msr.Size
            GptType         = [string]$msr.GptType
            FileSystem      = ''
        })
        Write-Step 'OK' 'MSR deja present apres Initialize-Disk'
    }

    New-RestorRecoveryPartition -Number $DiskNumber -Name 'RESTOR-BOOT' -Size 1GB -GptType $EfiType -FileSystem 'FAT32' -Label 'RESTOR-BOOT' -AssignLetter
    New-RestorRecoveryPartition -Number $DiskNumber -Name 'CODE-EFI' -Size 512MB -GptType $EfiType -FileSystem 'FAT32' -Label 'CODE-EFI' -AssignLetter
    New-RestorRecoveryPartition -Number $DiskNumber -Name 'VESTY-EFI' -Size 512MB -GptType $EfiType -FileSystem 'FAT32' -Label 'VESTY-EFI' -AssignLetter
    New-RestorRecoveryPartition -Number $DiskNumber -Name 'RESTOR-TOOLS' -Size 64GB -GptType $BasicType -FileSystem 'NTFS' -Label 'RESTOR-TOOLS' -AssignLetter
    New-RestorRecoveryPartition -Number $DiskNumber -Name 'RESCUE-EFI' -Size 512MB -GptType $EfiType -FileSystem 'FAT32' -Label 'RESCUE-EFI' -AssignLetter
    New-RestorRecoveryPartition -Number $DiskNumber -Name 'LOCKPICK-EFI' -Size 1GB -GptType $EfiType -FileSystem 'FAT32' -Label 'LOCKPICK-EF' -AssignLetter

    Write-Step 'INFO' 'Rechecking Golden Backup integrity before restore copy...'
    $recheck = Test-RestorBackupIntegrity -BackupPath $root
    $sameManifest = ([string]$recheck.ManifestSha256Actual).Equals($manifestHash, [StringComparison]::OrdinalIgnoreCase)
    if ((-not $recheck.Valid) -or (-not $sameManifest)) {
        throw 'Golden Backup integrity changed before restore copy.'
    }
    Write-Step 'OK' 'Golden Backup integrity unchanged'

    $byName = @{}
    foreach ($item in @($script:PartitionsCreated)) { $byName[$item.Name] = $item }
    foreach ($target in @('RESTOR-BOOT', 'CODE-EFI', 'VESTY-EFI', 'RESCUE-EFI', 'LOCKPICK-EFI')) {
        $letter = $byName[$target].DriveLetter
        $source = Join-Path $root ('ESP\' + $target)
        & robocopy.exe $source ($letter + ':\') '/E' '/COPY:DAT' '/DCOPY:DAT' '/R:2' '/W:1' '/XJ' | Out-Null
        if ($LASTEXITCODE -ge 8) { throw ("Copie de restauration echouee pour {0}." -f $target) }
        $check = Test-RestorRestoredTarget -TargetName $target -DestinationRoot ($letter + ':\') -ManifestSnapshot $manifestSnapshot
        $filesRestored += [int]$check.FilesExpected
        $filesVerified += [int]$check.FilesVerified
        foreach ($item in @($check.HashMismatches)) { if ($item) { $hashMismatches.Add($target + '\' + $item) } }
        foreach ($item in @($check.MissingFiles)) { if ($item) { $hashMismatches.Add('MISSING ' + $target + '\' + $item) } }
        if (-not $check.Valid) { throw ("Post-restore verification failed for {0}." -f $target) }
        Write-Step 'OK' ("Fichiers restaures : " + $target)
    }

    $toolsSource = Join-Path $root 'RESTOR-TOOLS'
    if (Test-Path -LiteralPath $toolsSource) {
        $toolsLetter = $byName['RESTOR-TOOLS'].DriveLetter
        $toolsDest = $toolsLetter + ':\'
        $mapped = @(
            @{ Backup = Join-Path $toolsSource 'RescueGrid\WinPE'; Live = Join-Path $toolsDest 'WinPE\RescueGrid' },
            @{ Backup = Join-Path $toolsSource 'RescueGrid\Project'; Live = Join-Path $toolsDest 'RescueGrid' }
        )
        foreach ($map in $mapped) {
            if (-not (Test-Path -LiteralPath $map.Backup)) { continue }
            New-Item -ItemType Directory -Path $map.Live -Force | Out-Null
            & robocopy.exe $map.Backup $map.Live '/E' '/COPY:DAT' '/DCOPY:DAT' '/R:2' '/W:1' '/XJ' | Out-Null
            if ($LASTEXITCODE -ge 8) { throw ("Copie RESTOR-TOOLS mappee echouee : " + $map.Live) }
        }
        $launcherRoot = Join-Path $toolsSource 'RescueGrid\Launchers'
        if (Test-Path -LiteralPath $launcherRoot) {
            Get-ChildItem -LiteralPath $launcherRoot -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $toolsDest $_.Name) -Force
            }
        }
        Get-ChildItem -LiteralPath $toolsSource -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $toolsDest $_.Name) -Force
        }

        $toolsExpected = 0
        $toolsVerified = 0
        foreach ($entry in @($manifestSnapshot)) {
            $relative = [string]$entry.RelativePath
            if (-not $relative.StartsWith('RESTOR-TOOLS\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $suffix = $relative.Substring('RESTOR-TOOLS\'.Length)
            $liveRelative = $null
            if ($suffix.StartsWith('RescueGrid\WinPE\', [StringComparison]::OrdinalIgnoreCase)) {
                $liveRelative = 'WinPE\RescueGrid\' + $suffix.Substring('RescueGrid\WinPE\'.Length)
            } elseif ($suffix.StartsWith('RescueGrid\Project\', [StringComparison]::OrdinalIgnoreCase)) {
                $liveRelative = 'RescueGrid\' + $suffix.Substring('RescueGrid\Project\'.Length)
            } elseif ($suffix.StartsWith('RescueGrid\Launchers\', [StringComparison]::OrdinalIgnoreCase)) {
                $liveRelative = $suffix.Substring('RescueGrid\Launchers\'.Length)
            } elseif ($suffix.StartsWith('RescueGrid\', [StringComparison]::OrdinalIgnoreCase)) {
                continue
            } else {
                $liveRelative = $suffix
            }
            $toolsExpected++
            $destFile = Join-Path $toolsDest $liveRelative
            if (-not (Test-Path -LiteralPath $destFile -PathType Leaf)) {
                $hashMismatches.Add('MISSING RESTOR-TOOLS\' + $liveRelative)
                continue
            }
            $actual = (Get-FileHash -LiteralPath $destFile -Algorithm SHA256).Hash
            $toolsVerified++
            if (-not $actual.Equals([string]$entry.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
                $hashMismatches.Add('RESTOR-TOOLS\' + $liveRelative)
            }
        }
        $filesRestored += $toolsExpected
        $filesVerified += $toolsVerified
        $toolsFailures = @($hashMismatches | Where-Object { $_ -like '*RESTOR-TOOLS*' })
        if ($toolsExpected -gt 0 -and $toolsFailures.Count -gt 0) {
            throw 'Post-restore verification failed for RESTOR-TOOLS.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $toolsDest 'WinPE\RescueGrid\boot.wim') -PathType Leaf)) {
            throw 'WinPE\RescueGrid\boot.wim absent apres restore mappe.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $toolsDest 'WinPE\RescueGrid\boot.sdi') -PathType Leaf)) {
            throw 'WinPE\RescueGrid\boot.sdi absent apres restore mappe.'
        }
        Write-Step 'OK' 'RESTOR-TOOLS restaure (layout live mappe, boot.wim + boot.sdi).'

        $rescueLetter = [string]$byName['RESCUE-EFI'].DriveLetter
        Update-RestorRescueGridBcd -RescueLetter $rescueLetter -ToolsLetter $toolsLetter -BackupRoot $root
    }

    $diskAfter = Get-Disk -Number $DiskNumber
    $unallocated = [int64]$diskAfter.LargestFreeExtent
    if ($hashMismatches.Count -gt 0) { throw 'Post-restore verification failed.' }
    $status = 'VALID'
    Write-Step 'OK' ("Recovery complete. UnallocatedBytes={0}" -f $unallocated)
} catch {
    Write-Step 'ERROR' $_.Exception.Message
    $status = 'FAILED'
    $report = [ordered]@{
        StartedAt            = $started.ToString('o')
        FinishedAt           = (Get-Date).ToString('o')
        DiskIdentity         = [ordered]@{ Model = $ExpectedModel; Serial = $ExpectedSerial }
        DiskNumber           = $DiskNumber
        PartitionLayout      = @($script:PartitionsCreated.ToArray())
        BackupManifestSha256 = $manifestHash
        PartitionsCreated    = @($script:PartitionsCreated | ForEach-Object { $_.Name })
        FilesRestored        = $filesRestored
        FilesVerified        = $filesVerified
        HashMismatches       = @($hashMismatches.ToArray())
        UnallocatedBytes     = 0
        Status               = 'FAILED'
        Error                = $_.Exception.Message
    }
    Write-RestorRecoveryResult -Path $reportPath -Payload $report
    throw
}

$diskFinal = Get-Disk -Number $DiskNumber
$report = [ordered]@{
    StartedAt            = $started.ToString('o')
    FinishedAt           = (Get-Date).ToString('o')
    DiskIdentity         = [ordered]@{ Model = $ExpectedModel; Serial = (ConvertTo-NormalizedSerial $ExpectedSerial) }
    DiskNumber           = $DiskNumber
    PartitionLayout      = @($script:PartitionsCreated.ToArray())
    BackupManifestSha256 = $manifestHash
    PartitionsCreated    = @($script:PartitionsCreated | ForEach-Object { $_.Name })
    FilesRestored        = $filesRestored
    FilesVerified        = $filesVerified
    HashMismatches       = @($hashMismatches.ToArray())
    UnallocatedBytes     = [int64]$diskFinal.LargestFreeExtent
    Status               = $status
}
Write-RestorRecoveryResult -Path $reportPath -Payload $report
Write-Step 'OK' ("Rapport : " + $reportPath)
Exit-RestorCommand -Code 0
