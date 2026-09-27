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

function Get-RestorBlankDiskCandidate {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Serial
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
    $nonReserved = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue | Where-Object { [string]$_.Type -ne 'Reserved' })
    if ($style -eq 'RAW') {
        return [pscustomobject]@{ Disk = $disk; State = 'Raw' }
    }
    if ($style -eq 'GPT' -and $nonReserved.Count -eq 0) {
        return [pscustomobject]@{ Disk = $disk; State = 'EmptyGpt' }
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

    $existingMsr = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Where-Object {
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
        & robocopy.exe $toolsSource ($toolsLetter + ':\') '/E' '/COPY:DAT' '/DCOPY:DAT' '/R:2' '/W:1' '/XJ' | Out-Null
        if ($LASTEXITCODE -ge 8) { throw 'Copie RESTOR-TOOLS echouee.' }
        Write-Step 'OK' 'RESTOR-TOOLS restaure.'
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
