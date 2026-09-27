<#
.SYNOPSIS
  Restaure des fichiers EFI depuis un Golden Backup. Simulation par défaut.

.DESCRIPTION
  Sans -Apply et -ConfirmRestore RESTOR-PC, aucune écriture n'est faite.
  Avec -Apply, l'intégrité complète du Golden Backup est vérifiée avant tout
  accès disque, puis une seconde fois après PRE-RESTORE et avant la copie.
  Cette version ne recrée, ne formate et ne redimensionne aucune partition.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BackupPath,
    [switch]$RestorBoot,
    [switch]$CodeEfi,
    [switch]$VestyEfi,
    [switch]$RescueEfi,
    [switch]$LockpickEfi,
    [switch]$AllEfi,
    [switch]$Apply,
    [string]$ConfirmRestore = '',
    [string]$PreRestoreRoot = 'C:\RESTOR-PC-BACKUP',
    [string]$ExpectedModel = 'SAMSUNG MZVLB256HAHQ-000L2',
    [string]$ExpectedSerial = '0025_3881_91C0_0621'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\RestorPc.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\RestorPc.Backup.psm1') -Force

function Write-Step {
    param([string]$Level, [string]$Message)
    Write-Host ("[{0}] {1}" -f $Level, $Message)
}

function Get-RestorDisk {
    param(
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Serial
    )
    $selection = Resolve-RestorDiskSelection -Disks @(Get-Disk) -Model $Model -Serial $Serial
    switch ($selection.Code) {
        'Ok' { return $selection.Disk }
        'None' { throw 'NVMe RESTOR-PC introuvable ou ambigu. Restauration annulée.' }
        'Ambiguous' { throw 'NVMe RESTOR-PC introuvable ou ambigu. Restauration annulée.' }
        'NotGpt' { throw 'Le NVMe RESTOR-PC n''est pas GPT.' }
        'NotNvme' { throw 'Le disque identifié n''est pas NVMe.' }
        default { throw ("Identification NVMe inattendue : " + $selection.Code) }
    }
}

$targets = @(Get-RestorRestoreTarget -RestorBoot:$RestorBoot -CodeEfi:$CodeEfi -VestyEfi:$VestyEfi -RescueEfi:$RescueEfi -LockpickEfi:$LockpickEfi -AllEfi:$AllEfi)
$writeAllowed = $Apply -and $ConfirmRestore -ceq 'RESTOR-PC'
if ($Apply -and -not $writeAllowed) {
    Write-Step 'WARN' 'Confirmation refusée. La phrase exacte est RESTOR-PC. Aucune écriture.'
}
if (-not $writeAllowed) {
    Write-Step 'INFO' 'Mode : simulation. Aucune partition n''est modifiée.'
    Write-Step 'OK' 'Dry-run. -Apply et -ConfirmRestore RESTOR-PC sont requis pour écrire.'
}
if ($targets.Count -eq 0) {
    Write-Step 'INFO' 'Aucune cible demandée. Les cibles possibles sont -RestorBoot, -CodeEfi, -VestyEfi, -RescueEfi, -LockpickEfi, -AllEfi.'
}

$root = [IO.Path]::GetFullPath($BackupPath)
if ($writeAllowed) {
    Write-Step 'INFO' 'Full Golden Backup integrity verification...'
    $integrity = Test-RestorBackupIntegrity -BackupPath $root
    if (-not $integrity.Valid) {
        Write-Step 'ERROR' 'Golden Backup integrity verification failed'
        foreach ($item in @($integrity.Failures)) { Write-Step 'ERROR' ([string]$item) }
        $detail = @($integrity.Failures) -join ' '
        if ([string]$integrity.Status -cne 'VALID') {
            throw ("Restauration refusée : le backup n'est pas VALID. " + $detail)
        }
        throw ("Restauration refusée : Golden Backup integrity verification failed. " + $detail)
    }
    Write-Step 'OK' ("Golden Backup integrity verified: {0} files" -f $integrity.FilesVerified)
    $integrityManifestHash = [string]$integrity.ManifestSha256Actual
    $manifestSnapshot = @(Get-RestorManifestSnapshot -BackupPath $root)
    $restoreStarted = Get-Date
} else {
    $infoPath = Join-Path $root 'BACKUP-INFO.json'
    $manifestPath = Join-Path $root 'Manifests\SHA256-MANIFEST.txt'
    if (-not (Test-Path -LiteralPath $infoPath) -or -not (Test-Path -LiteralPath $manifestPath)) {
        throw 'Backup incomplet : BACKUP-INFO.json ou le manifeste est absent.'
    }
    $info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ([string]$info.ManifestSha256 -ne $manifestHash) { throw 'Le manifeste du backup ne correspond pas à ManifestSha256.' }
    Write-Step 'OK' 'Manifeste du backup cohérent.'
    if ([string]$info.Status -ne 'VALID') {
        Write-Step 'ERROR' ("Le backup est {0}. -Apply serait refusé." -f $info.Status)
    }
}

$disk = Get-RestorDisk -Model $ExpectedModel -Serial $ExpectedSerial
Write-Step 'OK' ("NVMe confirmé, disque {0}." -f $disk.Number)
foreach ($target in $targets) {
    $source = Join-Path $root ("ESP\" + $target)
    if (-not (Test-Path -LiteralPath $source)) {
        throw ("La copie {0} est absente. Si la partition a disparu du NVMe, une reconstruction GPT manuelle est nécessaire. Elle n'est pas automatisée." -f $target)
    }
    if (-not $writeAllowed) {
        Write-Step 'INFO' ("Dry-run {0} : recopier les fichiers de {1} vers la partition existante du même nom, après contrôle de taille et de type GPT." -f $target, $source)
    }
}

if (-not $writeAllowed) {
    Write-Step 'OK' 'Aucune écriture effectuée.'
    Exit-RestorCommand -Code 0
}

Test-RestorAdministrator
if ($targets.Count -eq 0) { throw 'Restauration refusée : aucune partition cible.' }

$rules = @{
    'RESTOR-BOOT' = @{ Labels = @('RESTOR-BOOT'); FileSystem = 'FAT32'; Gpt = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'; Min = 800MB; Max = 1300MB }
    'CODE-EFI' = @{ Labels = @('CODE-EFI'); FileSystem = 'FAT32'; Gpt = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'; Min = 400MB; Max = 700MB }
    'VESTY-EFI' = @{ Labels = @('VESTY-EFI'); FileSystem = 'FAT32'; Gpt = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'; Min = 400MB; Max = 700MB }
    'RESCUE-EFI' = @{ Labels = @('RESCUE-EFI'); FileSystem = 'FAT32'; Gpt = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'; Min = 400MB; Max = 700MB }
    'LOCKPICK-EFI' = @{ Labels = @('LOCKPICK-EFI', 'LOCKPICK-EF'); FileSystem = 'FAT32'; Gpt = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'; Min = 800MB; Max = 1300MB }
}
$added = @()
try {
    $chosen = @{}
    $takenLetters = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($partition in @(Get-Partition -DiskNumber $disk.Number)) {
        if ([string]$partition.Type -eq 'Reserved') { continue }
        $letter = [string]$partition.DriveLetter
        $addedLetter = $false
        $mayMatch = $false
        foreach ($target in $targets) {
            if ($chosen.ContainsKey($target)) { continue }
            $rule = $rules[$target]
            if (([string]$partition.GptType).ToLowerInvariant() -eq $rule.Gpt -and $partition.Size -ge $rule.Min -and $partition.Size -le $rule.Max) { $mayMatch = $true }
        }
        if (-not $mayMatch) { continue }
        if ($letter -notmatch '^[A-Za-z]$') {
            $letter = ''
            foreach ($candidate in @('R', 'S', 'T', 'W', 'Z', 'L')) {
                if ($takenLetters.Contains($candidate)) { continue }
                if (Test-Path -LiteralPath ($candidate + ':\')) { continue }
                $letter = $candidate
                break
            }
            if ($letter -notmatch '^[A-Za-z]$') { throw 'Aucune lettre temporaire libre pour identifier les partitions.' }
            [void]$takenLetters.Add($letter)
            Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath ($letter + ':\')
            $added += [pscustomobject]@{ Letter = $letter; PartitionNumber = $partition.PartitionNumber }
            $addedLetter = $true
            Start-Sleep -Milliseconds 400
        }
        $volume = Get-Volume -DriveLetter $letter
        $label = ([string]$volume.FileSystemLabel).Trim()
        foreach ($target in $targets) {
            $rule = $rules[$target]
            if ($rule.Labels -notcontains $label) { continue }
            if ($chosen.ContainsKey($target)) { throw ("Plusieurs partitions correspondent à " + $target) }
            if ([string]$volume.FileSystem -ne $rule.FileSystem) { throw ("Système de fichiers inattendu pour " + $target) }
            if (([string]$partition.GptType).ToLowerInvariant() -ne $rule.Gpt) { throw ("Type GPT inattendu pour " + $target) }
            if ($partition.Size -lt $rule.Min -or $partition.Size -gt $rule.Max) { throw ("Taille inattendue pour " + $target) }
            $chosen[$target] = [pscustomobject]@{ Letter = $letter.ToUpperInvariant(); PartitionNumber = $partition.PartitionNumber; Added = $addedLetter }
        }
    }
    foreach ($target in $targets) {
        if (-not $chosen.ContainsKey($target)) {
            throw ("Partition {0} introuvable. Reconstruction GPT non automatisée : la partition doit déjà exister." -f $target)
        }
    }
    $preRootParent = Resolve-RestorPreRestoreRoot -Path $PreRestoreRoot
    $preRoot = Join-Path $preRootParent ('PRE-RESTORE-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $preRoot -Force | Out-Null
    foreach ($target in $targets) {
        $preDest = Join-Path $preRoot $target
        New-Item -ItemType Directory -Path $preDest -Force | Out-Null
        & robocopy.exe ($chosen[$target].Letter + ':\') $preDest '/E' '/COPY:DAT' '/DCOPY:DAT' '/R:2' '/W:1' '/XJ' | Out-Null
        if ($LASTEXITCODE -ge 8) { throw ("Pré-backup échoué pour {0}. Restauration annulée, aucune copie du Golden Backup n'a été écrite." -f $target) }
        Write-Step 'OK' ("Pré-backup {0} : {1}" -f $target, $preDest)
    }
    Write-Step 'INFO' 'Rechecking Golden Backup integrity before restore copy...'
    $recheck = Test-RestorBackupIntegrity -BackupPath $root
    $sameManifest = ([string]$recheck.ManifestSha256Actual).Equals([string]$integrityManifestHash, [StringComparison]::OrdinalIgnoreCase)
    if ((-not $recheck.Valid) -or (-not $sameManifest)) {
        Write-Step 'ERROR' 'Golden Backup integrity verification failed'
        foreach ($item in @($recheck.Failures)) { Write-Step 'ERROR' ([string]$item) }
        if (-not $sameManifest) {
            Write-Step 'ERROR' 'Le manifeste n''est plus celui vérifié avant l''accès disque.'
        }
        throw 'Golden Backup integrity changed before restore copy.'
    }
    Write-Step 'OK' 'Golden Backup integrity unchanged'
    $robocopyResults = New-Object System.Collections.ArrayList
    $checks = New-Object System.Collections.ArrayList
    $missingAll = New-Object System.Collections.Generic.List[string]
    $mismatchAll = New-Object System.Collections.Generic.List[string]
    $filesExpected = 0
    $filesVerified = 0
    $extraPreserved = 0
    $reportPath = Join-Path $preRoot 'RESTORE-RESULT.json'
    $utf8Report = New-Object System.Text.UTF8Encoding $false
    function Write-RestorFailedReport {
        param(
            [Parameter(Mandatory)][string]$Reason,
            [string]$FailingTarget = ''
        )
        $report = [ordered]@{
            Version               = '1.3.0'
            StartedAt             = $restoreStarted.ToString('o')
            FinishedAt            = (Get-Date).ToString('o')
            BackupPath            = $root
            BackupManifestSha256  = $integrityManifestHash
            Targets               = @($targets)
            PreRestorePath        = $preRoot
            FilesExpected         = $filesExpected
            FilesVerified         = $filesVerified
            MissingFiles          = @($missingAll.ToArray())
            HashMismatches        = @($mismatchAll.ToArray())
            ExtraFilesPreserved   = $extraPreserved
            RobocopyResults       = @($robocopyResults.ToArray())
            FailingTarget         = $FailingTarget
            FailureReason         = $Reason
            Status                = 'FAILED'
        }
        [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 6), $utf8Report)
        Write-Step 'ERROR' ("RESTORE-RESULT.json écrit : " + $reportPath)
    }
    foreach ($target in $targets) {
        & robocopy.exe (Join-Path $root ("ESP\" + $target)) ($chosen[$target].Letter + ':\') '/E' '/COPY:DAT' '/DCOPY:DAT' '/R:2' '/W:1' '/XJ' | Out-Null
        $copyCode = $LASTEXITCODE
        [void]$robocopyResults.Add([pscustomobject]@{ Target = $target; ExitCode = $copyCode; Phase = 'Golden' })
        if ($copyCode -ge 8) {
            Write-RestorFailedReport -Reason ("Robocopy failed for " + $target) -FailingTarget $target
            throw ("Copie de restauration échouée pour {0}. Le pré-backup est dans {1}." -f $target, $preRoot)
        }
        Write-Step 'OK' ("Fichiers restaurés : " + $target)
        $destination = $chosen[$target].Letter + ':\'
        $check = Test-RestorRestoredTarget -TargetName $target -DestinationRoot $destination -ManifestSnapshot $manifestSnapshot
        [void]$checks.Add($check)
        $filesExpected += [int]$check.FilesExpected
        $filesVerified += [int]$check.FilesVerified
        $extraPreserved += [int]$check.ExtraFilesPreserved
        foreach ($item in @($check.MissingFiles)) { if (-not [string]::IsNullOrWhiteSpace([string]$item)) { $missingAll.Add($target + '\' + $item) } }
        foreach ($item in @($check.HashMismatches)) { if (-not [string]::IsNullOrWhiteSpace([string]$item)) { $mismatchAll.Add($target + '\' + $item) } }
        if (-not $check.Valid) {
            Write-RestorFailedReport -Reason ("Post-copy verification failed for " + $target) -FailingTarget $target
            Write-Step 'ERROR' 'Post-restore verification failed'
            Write-Step 'ERROR' ("Aucune restauration automatique du contenu précédent. Pré-backup : " + $preRoot)
            throw ("Post-restore verification failed for {0}. Le pré-backup est dans {1}." -f $target, $preRoot)
        }
        Write-Step 'OK' ("Vérification post-copie valide : " + $target)
    }
    $restoreValid = ($missingAll.Count -eq 0) -and ($mismatchAll.Count -eq 0)
    foreach ($check in @($checks)) { if (-not $check.Valid) { $restoreValid = $false } }
    $reportStatus = $(if ($restoreValid) { 'VALID' } else { 'FAILED' })
    $report = [ordered]@{
        Version               = '1.3.0'
        StartedAt             = $restoreStarted.ToString('o')
        FinishedAt            = (Get-Date).ToString('o')
        BackupPath            = $root
        BackupManifestSha256  = $integrityManifestHash
        Targets               = @($targets)
        PreRestorePath        = $preRoot
        FilesExpected         = $filesExpected
        FilesVerified         = $filesVerified
        MissingFiles          = @($missingAll.ToArray())
        HashMismatches        = @($mismatchAll.ToArray())
        ExtraFilesPreserved   = $extraPreserved
        RobocopyResults       = @($robocopyResults.ToArray())
        Status                = $reportStatus
    }
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 6), $utf8Report)
    if (-not $restoreValid) {
        Write-Step 'ERROR' 'Post-restore verification failed'
        Write-Step 'ERROR' ("Aucune restauration automatique du contenu précédent. Pré-backup : " + $preRoot)
        throw ("Post-restore verification failed. Le pré-backup est dans {0}." -f $preRoot)
    }
    Write-Step 'OK' ("Post-restore verification valid: {0} files" -f $filesVerified)
} finally {
    foreach ($mount in @($added)) {
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $mount.PartitionNumber -AccessPath ($mount.Letter + ':\') -ErrorAction SilentlyContinue
        Write-Step 'INFO' ("Lettre temporaire {0}: retirée." -f $mount.Letter)
    }
}

