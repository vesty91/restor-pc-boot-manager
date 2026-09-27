<#
.SYNOPSIS
  Sauvegarde en lecture le boot manager RESTOR-PC vers un Golden Backup.

.DESCRIPTION
  Identifie le NVMe par modèle et numéro de série. Copie les ESP et les
  fichiers RescueGrid indispensables. N'écrit jamais sur les partitions sources.
#>
[CmdletBinding()]
param(
    [string]$DestinationRoot = 'C:\RESTOR-PC-BACKUP',
    [string]$ExpectedModel = 'SAMSUNG MZVLB256HAHQ-000L2',
    [string]$ExpectedSerial = '0025_3881_91C0_0621',
    [string]$ExpectedVestySha256 = 'CC67BBF03D668EE61DE3A4F620C3855DF4D2430F2D2BCB473658CF1CE53331F6'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\RestorPc.Common.psm1') -Force

$BackupVersion = '1.1.0'
$EfiType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$BasicType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:AddedMounts = @()
$script:ReservedLetters = New-Object 'System.Collections.Generic.HashSet[string]'
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Errors = New-Object System.Collections.Generic.List[string]
$script:DiskNumber = $null

function Write-Step {
    param([string]$Level, [string]$Message)
    Write-Host ("[{0}] {1}" -f $Level, $Message)
}

function Add-WarningText {
    param([string]$Message)
    $script:Warnings.Add($Message)
    Write-Step 'WARN' $Message
}

function Add-ErrorText {
    param([string]$Message)
    $script:Errors.Add($Message)
    Write-Step 'ERROR' $Message
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Ouvrez PowerShell en administrateur. Le script ne fait que lire et copier.'
    }
}

function Get-RestorDisk {
    $selection = Resolve-RestorDiskSelection -Disks @(Get-Disk) -Model $ExpectedModel -Serial $ExpectedSerial
    switch ($selection.Code) {
        'Ok' { return $selection.Disk }
        'None' { throw 'Aucun disque ne correspond au modèle et au numéro de série RESTOR-PC.' }
        'Ambiguous' { throw 'Plusieurs disques correspondent au modèle et au numéro de série RESTOR-PC.' }
        'NotGpt' { throw 'Le disque identifié n''est pas GPT.' }
        'NotNvme' { throw 'Le disque identifié n''est pas NVMe.' }
        default { throw ("Identification NVMe inattendue : " + $selection.Code) }
    }
}

function Get-PartitionSignature {
    param([int]$DiskNumber)
    @(Get-Partition -DiskNumber $DiskNumber | Sort-Object PartitionNumber | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}' -f $_.PartitionNumber, $_.Offset, $_.Size, $_.GptType, $_.Guid
    })
}

function Get-FreeDriveLetter {
    $used = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($volume in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter)) {
        [void]$used.Add(([string]$volume.DriveLetter).ToUpperInvariant())
    }
    foreach ($partition in @(Get-Partition -ErrorAction SilentlyContinue)) {
        $letterText = [string]$partition.DriveLetter
        if ($letterText -match '^[A-Za-z]$') { [void]$used.Add($letterText.ToUpperInvariant()) }
    }
    foreach ($logical in @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
        if ($logical.DeviceID -match '^([A-Za-z]):$') { [void]$used.Add($Matches[1].ToUpperInvariant()) }
    }
    foreach ($reserved in $script:ReservedLetters) { [void]$used.Add($reserved) }
    return Resolve-RestorTemporaryLetter -UsedLetter @($used)
}

function Mount-SourcePartition {
    param($Partition)
    $fresh = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $Partition.PartitionNumber
    if ($fresh.DiskNumber -ne $script:DiskNumber) { throw 'La partition ne appartient pas au NVMe RESTOR-PC.' }
    $letterText = [string]$fresh.DriveLetter
    if ($letterText -match '^[A-Za-z]$') {
        Write-Step 'INFO' ("Lettre existante {0}: conservée pour la partition {1}." -f $letterText.ToUpperInvariant(), $fresh.PartitionNumber)
        return [pscustomobject]@{ Letter = $letterText.ToUpperInvariant(); Added = $false; PartitionNumber = $fresh.PartitionNumber }
    }
    $letter = Get-FreeDriveLetter
    [void]$script:ReservedLetters.Add($letter)
    $access = $letter + ':\'
    Write-Step 'INFO' ("Montage temporaire {0}: sur la partition {1}." -f $letter, $fresh.PartitionNumber)
    Add-PartitionAccessPath -DiskNumber $script:DiskNumber -PartitionNumber $fresh.PartitionNumber -AccessPath $access
    $script:AddedMounts += [pscustomobject]@{ Letter = $letter; PartitionNumber = $fresh.PartitionNumber }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        if ($volume -and $volume.FileSystem) { break }
        Start-Sleep -Milliseconds 300
    }
    return [pscustomobject]@{ Letter = $letter; Added = $true; PartitionNumber = $fresh.PartitionNumber }
}

function Remove-AddedMounts {
    foreach ($mount in @($script:AddedMounts)) {
        $access = $mount.Letter + ':\'
        Write-Step 'INFO' ("Retrait de la lettre temporaire {0}: partition {1}." -f $mount.Letter, $mount.PartitionNumber)
        Remove-PartitionAccessPath -DiskNumber $script:DiskNumber -PartitionNumber $mount.PartitionNumber -AccessPath $access -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 200
        $still = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $mount.PartitionNumber
        $left = [string]$still.DriveLetter
        if ($left -match '^[A-Za-z]$' -and $left.ToUpperInvariant() -eq $mount.Letter) {
            Add-ErrorText ("La lettre temporaire {0}: est encore présente sur la partition {1}." -f $mount.Letter, $mount.PartitionNumber)
        } else {
            Write-Step 'OK' ("Lettre temporaire {0}: retirée." -f $mount.Letter)
        }
    }
}

function Copy-WithRobocopy {
    param([string]$Source, [string]$Destination, [string]$LogPath)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $robocopyArguments = @(
        $Source, $Destination,
        '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:1', '/XJ', '/ZB',
        '/NP', ('/LOG:' + $LogPath)
    )
    & robocopy.exe @robocopyArguments | Out-Null
    $code = $LASTEXITCODE
    if (-not (Test-RobocopySuccessCode -ExitCode $code)) {
        throw ("Robocopy a échoué pour {0} (code {1})." -f $Source, $code)
    }
    Write-Step 'OK' ("Copie {0} (robocopy {1})." -f $Source, $code)
}

function Copy-SharedFile {
    param([string]$Source, [string]$Destination)
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (-not ('RestorLockedFileCopy' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RestorLockedFileCopy {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr template);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr proc, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disable, ref TOKEN_PRIVILEGES state, uint len, IntPtr prev, IntPtr ret);
    [StructLayout(LayoutKind.Sequential)] struct LUID_AND_ATTRIBUTES { public long Luid; public uint Attr; }
    [StructLayout(LayoutKind.Sequential)] struct TOKEN_PRIVILEGES { public uint Count; public LUID_AND_ATTRIBUTES Priv; }
    public static void Copy(string source, string destination) {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0028, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
        long luid;
        if (!LookupPrivilegeValue(null, "SeBackupPrivilege", out luid)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var state = new TOKEN_PRIVILEGES { Count = 1, Priv = new LUID_AND_ATTRIBUTES { Luid = luid, Attr = 2 } };
        if (!AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var handle = CreateFile(source, 0x80000000, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        using (var input = new FileStream(handle, FileAccess.Read))
        using (var output = File.Create(destination)) { input.CopyTo(output); }
    }
}
'@
    }
    try {
        $inputStream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $outputStream = [IO.File]::Create($Destination)
            try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
        } finally { $inputStream.Dispose() }
    } catch {
        Write-Step 'WARN' ("Lecture partagée impossible, copie en lecture seule de " + $Source)
        [RestorLockedFileCopy]::Copy($Source, $Destination)
    }
}

function Get-GptPartitionName {
    param([string]$Letter)
    $code = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class RestorPartitionNameReader {
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
            var name = Marshal.PtrToStringUni(IntPtr.Add(buffer, 72), 36);
            return (name ?? "").TrimEnd('\0', ' ');
        } finally { Marshal.FreeHGlobal(buffer); handle.Dispose(); }
    }
}
'@
    if (-not ('RestorPartitionNameReader' -as [type])) { Add-Type -TypeDefinition $code }
    return [RestorPartitionNameReader]::Read('\\.\' + $Letter + ':')
}

function Get-RelativeHashLines {
    param([string]$Root, [string[]]$ExcludedNames)
    return @(Get-RestorManifestLine -Root $Root -ExcludedNames $ExcludedNames)
}

if ($MyInvocation.InvocationName -ne '.') {
    $backup = $null
    try {
        Assert-Administrator
        New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
        Start-Transcript -LiteralPath (Join-Path $DestinationRoot 'last-run.log') -Force | Out-Null
        $disk = Get-RestorDisk
        $script:DiskNumber = [int]$disk.Number
        Write-Step 'OK' ("NVMe {0} série {1} disque {2}." -f $disk.FriendlyName.Trim(), (ConvertTo-NormalizedSerial $disk.SerialNumber), $disk.Number)
        $before = Get-PartitionSignature -DiskNumber $script:DiskNumber
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = Join-Path $DestinationRoot ("v{0}-GOLDEN-{1}" -f $BackupVersion, $stamp)
        if (Test-Path -LiteralPath $backup) { throw ("Le dossier existe déjà : " + $backup) }
        foreach ($directory in @(
            'ESP\RESTOR-BOOT', 'ESP\CODE-EFI', 'ESP\VESTY-EFI', 'ESP\RESCUE-EFI', 'ESP\LOCKPICK-EFI',
            'RESTOR-TOOLS\RescueGrid', 'BCD\CODE-EFI', 'BCD\VESTY-EFI', 'BCD\RESCUE-EFI', 'Metadata', 'Manifests'
        )) {
            New-Item -ItemType Directory -Path (Join-Path $backup $directory) -Force | Out-Null
        }

        $expectations = @(
            @{ Key = 'RESTOR-BOOT'; Labels = @('RESTOR-BOOT'); FileSystem = 'FAT32'; Gpt = $EfiType; Min = 800MB; Max = 1300MB; Role = 'efi' },
            @{ Key = 'CODE-EFI'; Labels = @('CODE-EFI'); FileSystem = 'FAT32'; Gpt = $EfiType; Min = 400MB; Max = 700MB; Role = 'efi' },
            @{ Key = 'VESTY-EFI'; Labels = @('VESTY-EFI'); FileSystem = 'FAT32'; Gpt = $EfiType; Min = 400MB; Max = 700MB; Role = 'efi' },
            @{ Key = 'RESCUE-EFI'; Labels = @('RESCUE-EFI'); FileSystem = 'FAT32'; Gpt = $EfiType; Min = 400MB; Max = 700MB; Role = 'efi' },
            @{ Key = 'LOCKPICK-EFI'; Labels = @('LOCKPICK-EFI', 'LOCKPICK-EF'); FileSystem = 'FAT32'; Gpt = $EfiType; Min = 800MB; Max = 1300MB; Role = 'efi' },
            @{ Key = 'RESTOR-TOOLS'; Labels = @('RESTOR-TOOLS'); FileSystem = 'NTFS'; Gpt = $BasicType; Min = 60GB; Max = 70GB; Role = 'tools' }
        )
        $resolved = @{}
        $layout = @()
        foreach ($partition in @(Get-Partition -DiskNumber $script:DiskNumber | Sort-Object PartitionNumber)) {
            if ($partition.DiskNumber -ne $script:DiskNumber) { throw 'Partition hors du NVMe RESTOR-PC.' }
            if ([string]$partition.Type -eq 'Reserved') {
                $layout += [ordered]@{ PartitionNumber = $partition.PartitionNumber; Offset = $partition.Offset; Size = $partition.Size; GptType = [string]$partition.GptType; Guid = [string]$partition.Guid; DriveLetter = ''; FileSystem = ''; FileSystemLabel = 'MSR' }
                continue
            }
            $mount = Mount-SourcePartition -Partition $partition
            $volume = Get-Volume -DriveLetter $mount.Letter
            $label = ([string]$volume.FileSystemLabel).Trim()
            $gptName = ''
            try { $gptName = Get-GptPartitionName -Letter $mount.Letter } catch { Add-WarningText ("Nom GPT illisible sur {0}: {1}" -f $mount.Letter, $_.Exception.Message) }
            $layout += [ordered]@{
                PartitionNumber = $partition.PartitionNumber
                Offset = $partition.Offset
                Size = $partition.Size
                GptType = [string]$partition.GptType
                Guid = [string]$partition.Guid
                DriveLetter = $mount.Letter
                FileSystem = [string]$volume.FileSystem
                FileSystemLabel = $label
                GptName = $gptName
            }
            foreach ($expected in $expectations) {
                $nameMatch = $expected.Labels -contains $label -or $expected.Labels -contains $gptName
                if (-not $nameMatch) { continue }
                if ($resolved.ContainsKey($expected.Key)) { throw ("Plusieurs partitions correspondent à " + $expected.Key) }
                if ([string]$volume.FileSystem -ne $expected.FileSystem) { throw ("Système de fichiers inattendu pour " + $expected.Key) }
                if (([string]$partition.GptType).ToLowerInvariant() -ne $expected.Gpt.ToLowerInvariant()) { throw ("Type GPT inattendu pour " + $expected.Key) }
                if ($partition.Size -lt $expected.Min -or $partition.Size -gt $expected.Max) { throw ("Taille inattendue pour " + $expected.Key) }
                $resolved[$expected.Key] = [pscustomobject]@{ Partition = $partition; Mount = $mount; Label = $label; Volume = $volume }
            }
        }
        foreach ($expected in $expectations) {
            if (-not $resolved.ContainsKey($expected.Key)) { throw ("Partition introuvable : " + $expected.Key) }
            Write-Step 'OK' ("{0} partition {1} lettre {2}:" -f $expected.Key, $resolved[$expected.Key].Partition.PartitionNumber, $resolved[$expected.Key].Mount.Letter)
        }

        foreach ($key in @('RESTOR-BOOT', 'CODE-EFI', 'VESTY-EFI', 'RESCUE-EFI', 'LOCKPICK-EFI')) {
            $source = $resolved[$key].Mount.Letter + ':\'
            $destination = Join-Path $backup ("ESP\" + $key)
            try {
                Copy-WithRobocopy -Source $source -Destination $destination -LogPath (Join-Path $backup ("Metadata\robocopy-{0}.log" -f $key))
            } catch {
                Add-WarningText $_.Exception.Message
            }
        }
        foreach ($key in @('CODE-EFI', 'VESTY-EFI', 'RESCUE-EFI')) {
            $bcdSource = Join-Path ($resolved[$key].Mount.Letter + ':\EFI\Microsoft\Boot') 'BCD'
            $bcdDestination = Join-Path $backup ("BCD\" + $key + "\BCD")
            $espDestination = Join-Path $backup ("ESP\" + $key + "\EFI\Microsoft\Boot\BCD")
            if (-not (Test-Path -LiteralPath $bcdSource)) {
                Add-WarningText ("BCD absent de " + $key + " : " + $bcdSource)
                continue
            }
            Copy-SharedFile -Source $bcdSource -Destination $bcdDestination
            Copy-SharedFile -Source $bcdSource -Destination $espDestination
            $enumPath = Join-Path $backup ("Metadata\BCD-{0}.txt" -f $key)
            & bcdedit.exe /store $bcdDestination /enum all | Out-File -FilePath $enumPath -Encoding utf8
            if ($LASTEXITCODE -ne 0) { Add-WarningText ("bcdedit n'a pas pu lire le BCD de " + $key) }
            else { Write-Step 'OK' ("BCD lu : " + $key) }
        }

        $toolsLetter = $resolved['RESTOR-TOOLS'].Mount.Letter
        $toolsRoot = $toolsLetter + ':\'
        $inventory = New-Object System.Collections.Generic.List[string]
        $inventory.Add('Inventaire RESTOR-TOOLS')
        foreach ($entry in @(Get-ChildItem -LiteralPath $toolsRoot -Force)) {
            $inventory.Add(('{0} {1}' -f $(if ($entry.PSIsContainer) { 'DIR' } else { 'FILE' }), $entry.Name))
        }
        $rescueCopies = @(
            @{ Source = Join-Path $toolsRoot 'WinPE\RescueGrid'; Destination = Join-Path $backup 'RESTOR-TOOLS\RescueGrid\WinPE'; Label = 'WinPE\RescueGrid' },
            @{ Source = Join-Path $toolsRoot 'RescueGrid'; Destination = Join-Path $backup 'RESTOR-TOOLS\RescueGrid\Project'; Label = 'RescueGrid' }
        )
        foreach ($copy in $rescueCopies) {
            if (Test-Path -LiteralPath $copy.Source) {
                Copy-WithRobocopy -Source $copy.Source -Destination $copy.Destination -LogPath (Join-Path $backup ('Metadata\robocopy-' + ($copy.Label -replace '\\', '-') + '.log'))
                $inventory.Add(('COPIE ' + $copy.Source + ' -> ' + $copy.Destination))
            } else {
                Add-WarningText ("Chemin RescueGrid absent : " + $copy.Source)
                $inventory.Add(('ABSENT ' + $copy.Source))
            }
        }
        foreach ($launcher in @('Start-RescueGrid.cmd', 'Start-RescueGrid-Console.cmd', 'README_USB.txt')) {
            $launcherSource = Join-Path $toolsRoot $launcher
            if (Test-Path -LiteralPath $launcherSource) {
                Copy-SharedFile -Source $launcherSource -Destination (Join-Path $backup ("RESTOR-TOOLS\RescueGrid\Launchers\" + $launcher))
                $inventory.Add(('COPIE ' + $launcherSource))
            }
        }
        $bootWim = Join-Path $toolsRoot 'WinPE\RescueGrid\boot.wim'
        if (-not (Test-Path -LiteralPath $bootWim)) {
            $alternate = Get-ChildItem -LiteralPath $toolsRoot -Filter 'boot.wim' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($alternate) { Add-WarningText ("WinPE\RescueGrid\boot.wim est absent. Autre boot.wim vu : " + $alternate.FullName) }
            else { Add-WarningText 'Aucun boot.wim RescueGrid trouvé sur RESTOR-TOOLS.' }
        } else {
            Write-Step 'OK' ("boot.wim RescueGrid : " + $bootWim)
        }
        $inventory.Add('NON COPIE : Downloads, ISO, Tools, $RECYCLE.BIN, System Volume Information')
        Set-Content -LiteralPath (Join-Path $backup 'RESTOR-TOOLS\INVENTORY.txt') -Value ($inventory -join "`r`n") -Encoding UTF8

        $refindPath = Join-Path ($resolved['RESTOR-BOOT'].Mount.Letter + ':\EFI\BOOT') 'refind.conf'
        if (-not (Test-Path -LiteralPath $refindPath)) { Add-ErrorText ("refind.conf installé introuvable : " + $refindPath) }
        else {
            $refindText = [IO.File]::ReadAllText($refindPath)
            Set-Content -LiteralPath (Join-Path $backup 'Metadata\REFIND-CONFIG.txt') -Value $refindText -Encoding UTF8
            foreach ($entryName in @('WIN CODE', 'WIN VESTY', 'MEMTEST86+', 'RESCUEGRID', 'LOCKPICK')) {
                $count = ([regex]::Matches($refindText, [regex]::Escape('menuentry "' + $entryName + '"'))).Count
                if ($count -ne 1) { Add-ErrorText ("Entrée {0} présente {1} fois." -f $entryName, $count) }
                else { Write-Step 'OK' ("Entrée unique : " + $entryName) }
            }
        }
        $assetRoot = $resolved['RESTOR-BOOT'].Mount.Letter + ':\EFI\BOOT\themes\restor-pc\assets'
        foreach ($asset in @('win_code.png', 'win_vesty.png', 'memtest86plus.png', 'rescuegrid.png', 'lockpick.png', 'background.png', 'selection_big.png', 'selection_small.png')) {
            $assetPath = Join-Path $assetRoot $asset
            if (-not (Test-Path -LiteralPath $assetPath)) { Add-WarningText ("Asset absent du boot installé : " + $asset) }
        }
        $vestyInstalled = Join-Path $assetRoot 'win_vesty.png'
        if (Test-Path -LiteralPath $vestyInstalled) {
            $vestyHash = (Get-FileHash -LiteralPath $vestyInstalled -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($vestyHash -ne $ExpectedVestySha256.ToUpperInvariant()) {
                Add-WarningText ("WIN VESTY installé SHA256 {0} différent de {1}" -f $vestyHash, $ExpectedVestySha256)
            } else {
                Write-Step 'OK' ("WIN VESTY installé SHA256 " + $vestyHash)
            }
        }
        foreach ($required in @(
            'ESP\RESTOR-BOOT\EFI\BOOT\BOOTX64.EFI',
            'ESP\RESTOR-BOOT\EFI\BOOT\refind.conf',
            'ESP\RESTOR-BOOT\EFI\BOOT\themes\restor-pc\assets\win_vesty.png'
        )) {
            if (-not (Test-Path -LiteralPath (Join-Path $backup $required))) { Add-ErrorText ("Fichier critique absent de la copie : " + $required) }
        }

        Get-Disk -Number $script:DiskNumber | Format-List * | Out-File (Join-Path $backup 'Metadata\Get-Disk.txt') -Encoding utf8
        Get-Partition -DiskNumber $script:DiskNumber | Export-Csv (Join-Path $backup 'Metadata\Get-Partition.csv') -NoTypeInformation -Encoding utf8
        Get-Volume | Export-Csv (Join-Path $backup 'Metadata\Get-Volume.csv') -NoTypeInformation -Encoding utf8
        @(
            ('Model=' + ([string]$disk.FriendlyName).Trim()),
            ('Serial=' + (ConvertTo-NormalizedSerial $disk.SerialNumber)),
            ('DiskNumber=' + $disk.Number),
            ('PartitionStyle=' + $disk.PartitionStyle),
            ('BusType=' + $disk.BusType),
            ('Size=' + $disk.Size)
        ) | Set-Content -LiteralPath (Join-Path $backup 'Metadata\NVME-IDENTITY.txt') -Encoding UTF8
        $layout | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backup 'Metadata\PARTITION-LAYOUT.json') -Encoding UTF8
        $gitCommit = (& git -C $ProjectRoot rev-parse HEAD).Trim()
        $gitStatus = @(& git -C $ProjectRoot status --porcelain)
        $gitTags = @(& git -C $ProjectRoot tag --points-at HEAD)
        @(
            ('HEAD=' + $gitCommit),
            'porcelain:',
            ($gitStatus -join "`r`n"),
            'tags:',
            ($gitTags -join "`r`n")
        ) | Set-Content -LiteralPath (Join-Path $backup 'Metadata\GIT-STATE.txt') -Encoding UTF8
        if (@($gitStatus | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            Add-WarningText 'git status --porcelain n''est pas vide. Le backup n''est pas marqué VALID.'
        }
        $after = Get-PartitionSignature -DiskNumber $script:DiskNumber
        if (($before -join "`n") -ne ($after -join "`n")) { Add-ErrorText 'La table des partitions a changé pendant la sauvegarde.' }
        else { Write-Step 'OK' 'Table GPT inchangée (numéro, offset, taille, type, GUID).' }

        $status = 'VALID'
        if ($script:Errors.Count -gt 0) { $status = 'FAILED' }
        elseif ($script:Warnings.Count -gt 0) { $status = 'WARNING' }
        @'
# Restauration RESTOR-PC

Ce dossier est une copie en lecture. PARTITION-LAYOUT.json est informatif :
il ne doit pas servir à recréer le partitionnement sans confirmation explicite.

La restauration des fichiers se fait avec scripts\Restore-RestorBootManager.ps1.
Sans -Apply et -ConfirmRestore RESTOR-PC, le script reste en simulation.
'@ | Set-Content -LiteralPath (Join-Path $backup 'README-RESTORE.md') -Encoding UTF8

        $info = [ordered]@{
            BackupVersion = $BackupVersion
            CreatedAt = (Get-Date).ToString('o')
            ComputerName = $env:COMPUTERNAME
            GitCommit = $gitCommit
            GitTags = @($gitTags)
            ExpectedModel = $ExpectedModel
            ExpectedSerial = (ConvertTo-NormalizedSerial $ExpectedSerial)
            ActualModel = ([string]$disk.FriendlyName).Trim()
            ActualSerial = (ConvertTo-NormalizedSerial $disk.SerialNumber)
            DiskNumber = [int]$disk.Number
            DiskSize = [int64]$disk.Size
            Partitions = $layout
            RefindEntries = @('WIN CODE', 'WIN VESTY', 'MEMTEST86+', 'RESCUEGRID', 'LOCKPICK')
            ManifestSha256 = ''
            Status = $status
            Warnings = @($script:Warnings)
            Errors = @($script:Errors)
        }
        $infoPath = Join-Path $backup 'BACKUP-INFO.json'
        $info | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $infoPath -Encoding UTF8
        $manifestLines = [string[]]@(Get-RelativeHashLines -Root $backup -ExcludedNames @('SHA256-MANIFEST.txt'))
        $manifestPath = Join-Path $backup 'Manifests\SHA256-MANIFEST.txt'
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllLines($manifestPath, $manifestLines, $utf8)
        $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToUpperInvariant()
        $info.ManifestSha256 = $manifestHash
        $info | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $infoPath -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $DestinationRoot 'LATEST-GOLDEN.txt') -Value (@($backup, $status, $manifestHash) -join "`r`n") -Encoding UTF8
        Write-Step $(if ($status -eq 'VALID') { 'OK' } elseif ($status -eq 'WARNING') { 'WARN' } else { 'ERROR' }) ("Backup {0} : {1}" -f $status, $backup)
        Write-Step 'INFO' ("Manifest SHA256 " + $manifestHash)
        if ($status -eq 'FAILED') { exit 1 }
        exit 0
    } catch {
        Add-ErrorText $_.Exception.Message
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            @{ Status = 'FAILED'; Errors = @($script:Errors); Warnings = @($script:Warnings) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backup 'BACKUP-INFO.json') -Encoding UTF8
        }
        exit 1
    } finally {
        if ($null -ne $script:DiskNumber) { Remove-AddedMounts }
        try { Stop-Transcript | Out-Null } catch {
            # Best-effort : aucun transcript actif, ou transcript déjà arrêté. Ne bloque pas le bilan du backup.
            Write-Verbose ("Stop-Transcript ignoré : " + $_.Exception.Message)
        }
    }
}
