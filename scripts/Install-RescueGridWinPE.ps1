<#
.SYNOPSIS
  Installe le WinPE RescueGrid sur le NVMe RESTOR-PC sans repartitionner.

.DESCRIPTION
  Identifie le NVMe par modèle, numéro de série et labels.
  Copie boot.wim et boot.sdi sur RESTOR-TOOLS, prépare le BCD de RESCUE-EFI
  et ajoute l'entrée RESCUEGRID dans rEFInd.

  Ce script ne formate aucune partition et ne modifie ni CODE-EFI ni VESTY-EFI.
#>
[CmdletBinding()]
param(
    [string]$ExpectedModel = 'SAMSUNG MZVLB256HAHQ-000L2',

    [string]$ExpectedSerial = '0025_3881_91C0_0621',

    [string]$WinPERoot = 'C:\WinPE',

    [string]$BackupRoot = 'C:\RESTOR-PC-BACKUP',

    [string]$RescueGridRepo = '',

    [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EfiType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$MsrType = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
$BasicType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$script:Mounted = @()
$script:DiskNumber = $null

function Write-Step {
    param([string]$Level, [string]$Message)
    Write-Host ("[{0}] {1}" -f $Level, $Message)
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Ouvrez PowerShell en administrateur."
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
    foreach ($letter in 'R','S','T','W') {
        if (Test-Path -LiteralPath ($letter + ':\')) { [void]$used.Add([char]$letter) }
        if (-not $used.Contains([char]$letter)) { return $letter }
    }
    throw 'Aucune lettre temporaire libre (R, S, T, W).'
}

function Get-LogicalDisk {
    param([Parameter(Mandatory)][string]$Letter)
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $Letter + ":'")
        if ($disk -and $disk.FileSystem) { return $disk }
        Start-Sleep -Milliseconds 400
    }
    throw ("Volume {0}: illisible après montage." -f $Letter)
}

function Mount-Temporary {
    param($Partition)
    if ($Partition.DriveLetter -and ([string]$Partition.DriveLetter) -match '^[A-Za-z]$') {
        return ([string]$Partition.DriveLetter).ToUpperInvariant()
    }
    $letter = Get-FreeDriveLetter
    $access = ($letter + ':\')
    Add-PartitionAccessPath -DiskNumber $script:DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath $access
    $script:Mounted += [pscustomobject]@{
        PartitionNumber = $Partition.PartitionNumber
        Letter          = $letter
    }
    return $letter
}

function Remove-TemporaryMounts {
    foreach ($mount in $script:Mounted) {
        Remove-PartitionAccessPath -DiskNumber $script:DiskNumber -PartitionNumber $mount.PartitionNumber -AccessPath ($mount.Letter + ':\') -ErrorAction SilentlyContinue
    }
    $script:Mounted = @()
}

function Test-SizeNear {
    param([uint64]$Actual, [uint64]$Expected, [uint64]$Tolerance)
    $delta = [math]::Abs([int64]$Actual - [int64]$Expected)
    return ($delta -le [int64]$Tolerance)
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

function Get-VolumeFileHashes {
    param([Parameter(Mandatory)][string]$Root)
    $lines = New-Object System.Collections.Generic.List[string]
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch 'System Volume Information' } |
        Sort-Object FullName)
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\')
        try {
            $hash = Get-SharedSha256 -Path $file.FullName
            $lines.Add(('{0}  {1}' -f $hash, $relative))
        } catch {
            $item = Get-Item -LiteralPath $file.FullName -Force
            $lines.Add(('LOCKED {0} {1:o}  {2}' -f $item.Length, $item.LastWriteTimeUtc, $relative))
            Write-Step 'WARN' ("Fichier verrouillé, contrôle par taille et date : " + $file.FullName)
        }
    }
    return ($lines -join "`r`n")
}

function Invoke-Bcd {
    param([Parameter(Mandatory)][string]$Arguments)
    Write-Step 'OK' ("bcdedit " + $Arguments)
    $output = & cmd.exe /c ("bcdedit " + $Arguments)
    $code = $LASTEXITCODE
    foreach ($line in @($output)) { if ($line) { Write-Host $line } }
    if ($code -ne 0) {
        throw ("bcdedit a échoué (code {0}) : {1}" -f $code, $Arguments)
    }
    return @($output)
}

function Get-BcdOsLoaderIds {
    param([Parameter(Mandatory)][string]$Store)
    $raw = & bcdedit.exe /store $Store /enum osloader /v | Out-String
    if ($LASTEXITCODE -ne 0) { return @() }
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($raw -split '\r?\n')) {
        if ($line -match '(?i)identificateur|identifier' -and $line -match '(\{[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\})') {
            $ids.Add($Matches[1])
        }
    }
    return @($ids | Select-Object -Unique)
}

function Set-RescueGridMenuEntry {
    param([Parameter(Mandatory)][string]$ConfigPath)
    $entry = @"
menuentry "RESCUEGRID" {
    icon \EFI\BOOT\themes\restor-pc\assets\rescuegrid.png
    volume "RESCUE-EFI"
    loader \EFI\Microsoft\Boot\bootmgfw.efi
    ostype Windows
}
"@
    $text = [IO.File]::ReadAllText($ConfigPath)
    $pattern = '(?ms)^menuentry "RESCUEGRID" \{.*?^\}[ \t]*\r?\n?'
    if ($text.Contains('menuentry "RESCUEGRID"')) {
        $updated = [regex]::Replace($text, $pattern, ($entry.TrimEnd() + "`r`n"), 1)
    } else {
        $suffix = $text
        if (-not $suffix.EndsWith("`n")) { $suffix += "`r`n" }
        $updated = $suffix + "`r`n" + $entry.TrimEnd() + "`r`n"
    }
    foreach ($name in @('WIN CODE', 'WIN VESTY', 'MEMTEST86+', 'RESCUEGRID')) {
        if (-not $updated.Contains('menuentry "' + $name + '"')) {
            throw ("Entrée rEFInd absente après mise à jour : " + $name)
        }
    }
    $ascii = New-Object System.Text.ASCIIEncoding
    [IO.File]::WriteAllText($ConfigPath, $updated, $ascii)
}

Assert-Administrator

$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $RescueGridRepo) {
    $RescueGridRepo = Join-Path (Split-Path -Parent $projectRoot) 'restor-pc-rescuegrid'
}

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
    throw ("NVMe RESTOR-PC introuvable ou ambigu. Attendu : {0} / {1}`nDisques vus :`n{2}" -f $ExpectedModel, $ExpectedSerial, $found)
}

$disk = $matches[0]
$script:DiskNumber = $disk.Number
Write-Step 'OK' ("NVMe identifié : Disk {0} / {1} / {2}" -f $disk.Number, $disk.FriendlyName, $disk.SerialNumber)

if ($disk.PartitionStyle -ne 'GPT') { throw 'Le NVMe RESTOR-PC n''est pas GPT.' }
if ($disk.BusType -ne 'NVMe') { throw 'Le disque identifié n''est pas NVMe.' }

$partitions = @(Get-Partition -DiskNumber $disk.Number | Sort-Object PartitionNumber)
if ($partitions.Count -ne 6) {
    throw ("Structure refusée : {0} partition(s), 6 attendues. Aucune modification effectuée." -f $partitions.Count)
}

$expectations = @(
    @{ Number = 1; Role = 'MSR';          Type = $MsrType;   Label = $null;           FileSystem = $null;   Size = 16MB;    Tolerance = 1MB }
    @{ Number = 2; Role = 'RESTOR-BOOT';  Type = $EfiType;   Label = 'RESTOR-BOOT';   FileSystem = 'FAT32'; Size = 1024MB; Tolerance = 8MB }
    @{ Number = 3; Role = 'CODE-EFI';     Type = $EfiType;   Label = 'CODE-EFI';      FileSystem = 'FAT32'; Size = 512MB;  Tolerance = 8MB }
    @{ Number = 4; Role = 'VESTY-EFI';    Type = $EfiType;   Label = 'VESTY-EFI';     FileSystem = 'FAT32'; Size = 512MB;  Tolerance = 8MB }
    @{ Number = 5; Role = 'RESTOR-TOOLS'; Type = $BasicType; Label = 'RESTOR-TOOLS';  FileSystem = 'NTFS';  Size = 64GB;   Tolerance = 64MB }
    @{ Number = 6; Role = 'RESCUE-EFI';   Type = $EfiType;   Label = 'RESCUE-EFI';    FileSystem = 'FAT32'; Size = 512MB;  Tolerance = 8MB }
)

$resolved = @{}
try {
    foreach ($expected in $expectations) {
        $partition = $partitions | Where-Object { $_.PartitionNumber -eq $expected.Number } | Select-Object -First 1
        if (-not $partition) { throw ("Partition {0} absente." -f $expected.Number) }
        $actualType = ([string]$partition.GptType).ToLowerInvariant()
        if ($actualType -ne $expected.Type) {
            throw ("Partition {0} : type GPT {1}, attendu {2}." -f $expected.Number, $actualType, $expected.Type)
        }
        if (-not (Test-SizeNear -Actual $partition.Size -Expected $expected.Size -Tolerance $expected.Tolerance)) {
            throw ("Partition {0} : taille {1}, attendue environ {2}." -f $expected.Number, $partition.Size, $expected.Size)
        }
        if (-not $expected.Label) {
            Write-Step 'OK' ("Partition {0} MSR conforme." -f $expected.Number)
            continue
        }
        $letter = Mount-Temporary $partition
        $logical = Get-LogicalDisk $letter
        $label = [string]$logical.VolumeName
        $fileSystem = [string]$logical.FileSystem
        if ($label -ne $expected.Label -or $fileSystem -ne $expected.FileSystem) {
            throw ("Partition {0} ({1}:) label/FS = [{2}] [{3}], attendu [{4}] [{5}]." -f $expected.Number, $letter, $label, $fileSystem, $expected.Label, $expected.FileSystem)
        }
        $resolved[$expected.Label] = [pscustomobject]@{
            Partition  = $partition
            Letter     = $letter
            FileSystem = $fileSystem
        }
        Write-Step 'OK' ("{0} = {1}: {2} {3}" -f $expected.Label, $letter, $fileSystem, $label)
    }

    $protectedBefore = @{
        'CODE-EFI'  = Get-VolumeFileHashes (($resolved['CODE-EFI'].Letter) + ':\')
        'VESTY-EFI' = Get-VolumeFileHashes (($resolved['VESTY-EFI'].Letter) + ':\')
    }

    $refindPreview = Join-Path ($resolved['RESTOR-BOOT'].Letter + ':\') 'EFI\BOOT\refind.conf'
    if (Test-Path -LiteralPath $refindPreview) {
        Copy-Item -LiteralPath $refindPreview -Destination (Join-Path $env:TEMP 'restor-refind-before.conf') -Force
    }

    if ($PreflightOnly) {
        Set-Content -LiteralPath (Join-Path $env:TEMP 'restor-rescuegrid-disk.txt') -Value ([string]$disk.Number) -Encoding ascii
        Write-Step 'OK' 'Précontrôle terminé. Aucune écriture sur le NVMe.'
        return
    }

    $bootWim = Join-Path $WinPERoot 'media\sources\boot.wim'
    $bootSdi = Join-Path $WinPERoot 'media\Boot\boot.sdi'
    $iso = Join-Path $WinPERoot 'RescueGridWinPE.iso'
    foreach ($requiredFile in @($bootWim, $bootSdi)) {
        if (-not (Test-Path -LiteralPath $requiredFile)) {
            throw ("Fichier WinPE manquant : " + $requiredFile)
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $BackupRoot ($timestamp + '-pre-rescuegrid')
    New-Item -ItemType Directory -Path (Join-Path $backup 'Metadata') -Force | Out-Null
    Write-Step 'OK' ("Sauvegarde : " + $backup)

    $restorRoot = $resolved['RESTOR-BOOT'].Letter + ':\'
    $rescueRoot = $resolved['RESCUE-EFI'].Letter + ':\'
    $toolsRoot = $resolved['RESTOR-TOOLS'].Letter + ':\'

    $liveConfig = Join-Path $restorRoot 'EFI\BOOT\refind.conf'
    $liveTheme = Join-Path $restorRoot 'EFI\BOOT\themes\restor-pc\theme.conf'
    $liveAssets = Join-Path $restorRoot 'EFI\BOOT\themes\restor-pc\assets'
    if (-not (Test-Path -LiteralPath $liveConfig)) { throw 'refind.conf introuvable sur RESTOR-BOOT.' }

    $bootloader = Join-Path $restorRoot 'EFI\BOOT\BOOTX64.EFI'
    if (-not (Test-Path -LiteralPath $bootloader)) { throw 'BOOTX64.EFI introuvable sur RESTOR-BOOT.' }
    $bootloaderHashBefore = Get-SharedSha256 -Path $bootloader
    Copy-Item -LiteralPath $bootloader -Destination (Join-Path $backup 'BOOTX64.EFI') -Force
    Copy-Item -LiteralPath $liveConfig -Destination (Join-Path $backup 'refind.conf') -Force
    if (Test-Path -LiteralPath $liveTheme) {
        Copy-Item -LiteralPath $liveTheme -Destination (Join-Path $backup 'theme.conf') -Force
    }
    if (Test-Path -LiteralPath $liveAssets) {
        Copy-Item -LiteralPath $liveAssets -Destination (Join-Path $backup 'assets') -Recurse -Force
    }
    $rescueBackup = Join-Path $backup 'RESCUE-EFI'
    New-Item -ItemType Directory -Path $rescueBackup -Force | Out-Null
    & robocopy $rescueRoot $rescueBackup /E /COPY:DAT /R:1 /W:1 /XJ /XD "System Volume Information" /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw ("Sauvegarde RESCUE-EFI échouée (robocopy {0})." -f $LASTEXITCODE) }

    $existingBcd = Join-Path $rescueRoot 'EFI\Microsoft\Boot\BCD'
    if (Test-Path -LiteralPath $existingBcd) {
        & bcdedit.exe /store $existingBcd /enum all /v | Out-File (Join-Path $backup 'Metadata\BCD-RESCUEGRID-before.txt') -Encoding utf8
    } else {
        Set-Content -LiteralPath (Join-Path $backup 'Metadata\BCD-RESCUEGRID-before.txt') -Value 'BCD RescueGrid absent avant installation.' -Encoding utf8
    }

    Get-Disk -Number $disk.Number | Format-List * | Out-File (Join-Path $backup 'Metadata\Get-Disk.txt') -Encoding utf8
    Get-Partition -DiskNumber $disk.Number |
        Select-Object DiskNumber, PartitionNumber, DriveLetter, Type, GptType, Guid, Offset, Size |
        Export-Csv (Join-Path $backup 'Metadata\Get-Partition.csv') -NoTypeInformation -Encoding utf8
    $protectedBefore['CODE-EFI'] | Set-Content (Join-Path $backup 'Metadata\CODE-EFI.sha256') -Encoding ascii
    $protectedBefore['VESTY-EFI'] | Set-Content (Join-Path $backup 'Metadata\VESTY-EFI.sha256') -Encoding ascii

    $hashLines = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -LiteralPath $backup -Recurse -File | Where-Object { $_.Name -ne 'SHA256-MANIFEST.txt' } | ForEach-Object {
        $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
        $hashLines.Add(('{0}  {1}' -f $hash.Hash, $_.FullName.Substring($backup.Length).TrimStart('\')))
    }
    $hashLines | Set-Content (Join-Path $backup 'SHA256-MANIFEST.txt') -Encoding ascii
    Write-Step 'OK' 'Sauvegarde et empreintes SHA256 écrites.'

    $wimDestinationDir = Join-Path $toolsRoot 'WinPE\RescueGrid'
    New-Item -ItemType Directory -Path $wimDestinationDir -Force | Out-Null
    Copy-Item -LiteralPath $bootWim -Destination (Join-Path $wimDestinationDir 'boot.wim') -Force
    Copy-Item -LiteralPath $bootSdi -Destination (Join-Path $wimDestinationDir 'boot.sdi') -Force
    $sourceWimHash = (Get-FileHash -LiteralPath $bootWim -Algorithm SHA256).Hash
    $destWimHash = (Get-FileHash -LiteralPath (Join-Path $wimDestinationDir 'boot.wim') -Algorithm SHA256).Hash
    if ($sourceWimHash -ne $destWimHash) { throw 'Le boot.wim copié ne correspond pas à la source.' }
    Write-Step 'OK' ("boot.wim copié vers {0} ({1})" -f (Join-Path $wimDestinationDir 'boot.wim'), $destWimHash)

    if (Test-Path -LiteralPath $iso) {
        $isoDir = Join-Path $toolsRoot 'ISO'
        New-Item -ItemType Directory -Path $isoDir -Force | Out-Null
        Copy-Item -LiteralPath $iso -Destination (Join-Path $isoDir 'RescueGridWinPE.iso') -Force
        Write-Step 'OK' 'ISO archivée dans \ISO\RescueGridWinPE.iso'
    } else {
        Write-Step 'WARN' 'ISO absente, archive non copiée.'
    }

    $usbScript = Join-Path $RescueGridRepo 'agent\windows\winpe\Create-RescueGridUSB.ps1'
    if (-not (Test-Path -LiteralPath $usbScript)) {
        throw ("Create-RescueGridUSB.ps1 introuvable : " + $usbScript)
    }
    & $usbScript -TargetDrive ($resolved['RESTOR-TOOLS'].Letter + ':') -WinPEBasePath $WinPERoot
    $lockpick = Join-Path $RescueGridRepo 'Lockpick'
    if (Test-Path -LiteralPath $lockpick) {
        $lockDest = Join-Path $toolsRoot 'RescueGrid\Lockpick'
        New-Item -ItemType Directory -Path $lockDest -Force | Out-Null
        Copy-Item -Path (Join-Path $lockpick '*') -Destination $lockDest -Recurse -Force
    }
    $assetSource = Join-Path $RescueGridRepo 'agent\windows\assets'
    if (Test-Path -LiteralPath $assetSource) {
        $assetDest = Join-Path $toolsRoot 'RescueGrid\agent\windows\assets'
        New-Item -ItemType Directory -Path $assetDest -Force | Out-Null
        Copy-Item -Path (Join-Path $assetSource '*') -Destination $assetDest -Recurse -Force
    }
    foreach ($needed in @(
        'RescueGrid\agent\windows\Setup-WinPEDesktop.ps1',
        'RescueGrid\agent\windows\Start-RescueGrid.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $toolsRoot $needed))) {
            throw ("Fichier RescueGrid manquant après copie : " + $needed)
        }
    }
    Write-Step 'OK' 'Dossier RescueGrid déposé sur RESTOR-TOOLS.'

    function ConvertTo-ComparableText {
        param([string]$Text)
        $lines = @($Text -split '\r?\n' | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' })
        return ($lines -join "`n")
    }

    $firmwareBefore = ConvertTo-ComparableText (& bcdedit.exe /enum '{fwbootmgr}' | Out-String)
    $rescueLetter = $resolved['RESCUE-EFI'].Letter
    $toolsLetter = $resolved['RESTOR-TOOLS'].Letter
    if ($rescueLetter -eq 'C' -or $toolsLetter -eq 'C') { throw 'Refus : une cible résolue sur C:.' }
    $rescueCheck = Get-LogicalDisk $rescueLetter
    $toolsCheck = Get-LogicalDisk $toolsLetter
    if ($rescueCheck.VolumeName -ne 'RESCUE-EFI') { throw 'Refus bcdboot : la lettre Rescue n''est plus RESCUE-EFI.' }
    if ($toolsCheck.VolumeName -ne 'RESTOR-TOOLS') { throw 'Refus : la lettre Tools n''est plus RESTOR-TOOLS.' }

    $store = Join-Path $rescueRoot 'EFI\Microsoft\Boot\BCD'
    $bcdDir = Split-Path -Parent $store
    if (Test-Path -LiteralPath $bcdDir) {
        Get-ChildItem -LiteralPath $bcdDir -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'BCD*' } |
            Remove-Item -Force
        Write-Step 'OK' 'Ancien magasin BCD de RESCUE-EFI retiré avant reconstruction.'
    }
    Write-Step 'OK' ("bcdboot /s {0}: /f UEFI /nofirmwaresync" -f $rescueLetter)
    & bcdboot.exe $env:SystemRoot /s ($rescueLetter + ':') /f UEFI /nofirmwaresync
    if ($LASTEXITCODE -ne 0) { throw ("bcdboot a échoué (code {0})." -f $LASTEXITCODE) }
    $firmwareAfter = ConvertTo-ComparableText (& bcdedit.exe /enum '{fwbootmgr}' | Out-String)
    $bootloaderHashAfter = Get-SharedSha256 -Path $bootloader
    if ($bootloaderHashBefore -ne $bootloaderHashAfter) {
        throw 'BOOTX64.EFI de rEFInd a changé pendant bcdboot. Arrêt. Restaurez la sauvegarde.'
    }
    if ($firmwareBefore -ne $firmwareAfter) {
        $firmwareBefore | Out-File (Join-Path $backup 'Metadata\firmware-before.txt') -Encoding utf8
        $firmwareAfter | Out-File (Join-Path $backup 'Metadata\firmware-after.txt') -Encoding utf8
        throw 'Le microprogramme UEFI a changé pendant bcdboot. Arrêt avant toute autre modification de démarrage.'
    }
    Write-Step 'OK' 'bcdboot terminé sans modification du firmware.'

    if (-not (Test-Path -LiteralPath $store)) { throw ("BCD introuvable après bcdboot : " + $store) }
    $storeFull = [IO.Path]::GetFullPath($store)
    $rescueFull = [IO.Path]::GetFullPath($rescueRoot)
    if (-not $storeFull.StartsWith($rescueFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refus : le magasin BCD n''est pas sur RESCUE-EFI.'
    }

    $enumAll = & bcdedit.exe /store $store /enum all /v | Out-String
    if ($enumAll -notmatch 'ae5534e0-51f0-11dd-93e7-001560b44f3a') {
        Invoke-Bcd ("/store `"{0}`" /create {{ramdiskoptions}} /d `"Ramdisk Options`"" -f $store) | Out-Null
    }
    Invoke-Bcd ("/store `"{0}`" /set {{ramdiskoptions}} ramdisksdidevice partition={1}:" -f $store, $toolsLetter) | Out-Null
    Invoke-Bcd ("/store `"{0}`" /set {{ramdiskoptions}} ramdisksdipath \WinPE\RescueGrid\boot.sdi" -f $store) | Out-Null

    $created = Invoke-Bcd ("/store `"{0}`" /create /d `"RESTOR-PC RESCUEGRID`" /application osloader" -f $store)
    $createdText = $created -join "`n"
    $guidMatch = [regex]::Match($createdText, '\{[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}')
    if (-not $guidMatch.Success) { throw 'GUID de l''entrée RESTOR-PC RESCUEGRID introuvable.' }
    $guid = $guidMatch.Value

    $wimArg = ("ramdisk=[{0}:]\WinPE\RescueGrid\boot.wim,{{ramdiskoptions}}" -f $toolsLetter)
    Invoke-Bcd ("/store `"{0}`" /set {1} device {2}" -f $store, $guid, $wimArg) | Out-Null
    Invoke-Bcd ("/store `"{0}`" /set {1} osdevice {2}" -f $store, $guid, $wimArg) | Out-Null
    Invoke-Bcd ("/store `"{0}`" /set {1} path \Windows\System32\Boot\winload.efi" -f $store, $guid) | Out-Null
    Invoke-Bcd ("/store `"{0}`" /set {1} systemroot \Windows" -f $store, $guid) | Out-Null
    Invoke-Bcd ("/store `"{0}`" /set {1} winpe yes" -f $store, $guid) | Out-Null
    Invoke-Bcd ("/store `"{0}`" /set {1} detecthal yes" -f $store, $guid) | Out-Null
    Invoke-Bcd ("/store `"{0}`" /displayorder {1} /addlast" -f $store, $guid) | Out-Null
    Invoke-Bcd ("/store `"{0}`" /default {1}" -f $store, $guid) | Out-Null
    Invoke-Bcd ("/store `"{0}`" /timeout 0" -f $store) | Out-Null

    foreach ($other in (Get-BcdOsLoaderIds -Store $store)) {
        if ($other.Trim('{}').Equals($guid.Trim('{}'), [StringComparison]::OrdinalIgnoreCase)) { continue }
        $deleteArgs = ("/store `"{0}`" /delete {1} /f" -f $store, $other)
        Write-Step 'OK' ("bcdedit " + $deleteArgs)
        $deleteOutput = & cmd.exe /c ("bcdedit " + $deleteArgs)
        foreach ($line in @($deleteOutput)) { if ($line) { Write-Host $line } }
        if ($LASTEXITCODE -ne 0) {
            $deleteText = @($deleteOutput) -join "`n"
            if ($deleteText -match 'introuvable|not found') {
                Write-Step 'WARN' ("Entrée déjà absente : " + $other)
                continue
            }
            throw ("bcdedit a échoué (code {0}) : {1}" -f $LASTEXITCODE, $deleteArgs)
        }
    }

    $finalBcd = & bcdedit.exe /store $store /enum all /v | Out-String
    $finalBcd | Out-File (Join-Path $backup 'Metadata\BCD-RESCUEGRID-after.txt') -Encoding utf8
    foreach ($token in @('RESTOR-PC RESCUEGRID', '\WinPE\RescueGrid\boot.wim', '\WinPE\RescueGrid\boot.sdi')) {
        if (-not $finalBcd.Contains($token)) {
            throw ("BCD RescueGrid incomplet, jeton absent : " + $token)
        }
    }
    Write-Step 'OK' 'BCD RescueGrid pointe vers WinPE\RescueGrid.'

    $iconSource = Join-Path $projectRoot 'theme\restor-pc\assets\rescuegrid.png'
    if (-not (Test-Path -LiteralPath $iconSource)) { throw ("Icône absente du dépôt : " + $iconSource) }
    $iconDestDir = Join-Path $restorRoot 'EFI\BOOT\themes\restor-pc\assets'
    if (-not (Test-Path -LiteralPath $iconDestDir)) { throw 'Dossier d''assets rEFInd introuvable sur RESTOR-BOOT.' }
    Copy-Item -LiteralPath $iconSource -Destination (Join-Path $iconDestDir 'rescuegrid.png') -Force

    $configBackup = $liveConfig + '.bak-' + $timestamp
    Copy-Item -LiteralPath $liveConfig -Destination $configBackup -Force
    Set-RescueGridMenuEntry -ConfigPath $liveConfig
    Write-Step 'OK' ("Entrée RESCUEGRID écrite. Copie : " + $configBackup)

    $protectedAfter = @{
        'CODE-EFI'  = Get-VolumeFileHashes (($resolved['CODE-EFI'].Letter) + ':\')
        'VESTY-EFI' = Get-VolumeFileHashes (($resolved['VESTY-EFI'].Letter) + ':\')
    }
    foreach ($name in @('CODE-EFI', 'VESTY-EFI')) {
        if ($protectedBefore[$name] -ne $protectedAfter[$name]) {
            throw ($name + ' a été modifié. Restaurez la sauvegarde avant de redémarrer.')
        }
        Write-Step 'OK' ($name + ' inchangé.')
    }

    Set-Content -LiteralPath (Join-Path $env:TEMP 'restor-rescuegrid-disk.txt') -Value ([string]$disk.Number) -Encoding ascii
    Write-Step 'OK' 'Installation RescueGrid terminée.'
}
finally {
    Remove-TemporaryMounts
}
