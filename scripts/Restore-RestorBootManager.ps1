<#
.SYNOPSIS
  Restaure des fichiers EFI depuis un Golden Backup. Simulation par défaut.

.DESCRIPTION
  Sans -Apply et -ConfirmRestore RESTOR-PC, aucune écriture n'est faite.
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
    [string]$ExpectedModel = 'SAMSUNG MZVLB256HAHQ-000L2',
    [string]$ExpectedSerial = '0025_3881_91C0_0621'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Level, [string]$Message)
    Write-Host ("[{0}] {1}" -f $Level, $Message)
}

function ConvertTo-NormalizedSerial {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value.Trim().TrimEnd('.').ToUpperInvariant())
}

function Get-RestorDisk {
    $expectedSerialNorm = ConvertTo-NormalizedSerial $ExpectedSerial
    $matches = @()
    foreach ($candidate in @(Get-Disk)) {
        $serial = ConvertTo-NormalizedSerial ([string]$candidate.SerialNumber)
        $model = ([string]$candidate.FriendlyName).Trim()
        if ($model -eq $ExpectedModel.Trim() -and $serial -eq $expectedSerialNorm) { $matches += $candidate }
    }
    if ($matches.Count -ne 1) { throw 'NVMe RESTOR-PC introuvable ou ambigu. Restauration annulée.' }
    $disk = $matches[0]
    if ([string]$disk.PartitionStyle -ne 'GPT') { throw 'Le NVMe RESTOR-PC n''est pas GPT.' }
    if ([string]$disk.BusType -ne 'NVMe') { throw 'Le disque identifié n''est pas NVMe.' }
    return $disk
}

$targets = @()
if ($AllEfi -or $RestorBoot) { $targets += 'RESTOR-BOOT' }
if ($AllEfi -or $CodeEfi) { $targets += 'CODE-EFI' }
if ($AllEfi -or $VestyEfi) { $targets += 'VESTY-EFI' }
if ($AllEfi -or $RescueEfi) { $targets += 'RESCUE-EFI' }
if ($AllEfi -or $LockpickEfi) { $targets += 'LOCKPICK-EFI' }
$targets = @($targets | Select-Object -Unique)
$writeAllowed = $Apply -and $ConfirmRestore -eq 'RESTOR-PC'
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
    if ($writeAllowed) { throw 'Restauration refusée : le backup n''est pas VALID.' }
}

$disk = Get-RestorDisk
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
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Restauration refusée : PowerShell n''est pas administrateur.'
}
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
    $preRoot = Join-Path 'C:\RESTOR-PC-BACKUP' ('PRE-RESTORE-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $preRoot -Force | Out-Null
    foreach ($target in $targets) {
        $preDest = Join-Path $preRoot $target
        New-Item -ItemType Directory -Path $preDest -Force | Out-Null
        & robocopy.exe ($chosen[$target].Letter + ':\') $preDest '/E' '/COPY:DAT' '/DCOPY:DAT' '/R:2' '/W:1' '/XJ' | Out-Null
        if ($LASTEXITCODE -ge 8) { throw ("Pré-backup échoué pour {0}. Restauration annulée, aucune copie du Golden Backup n'a été écrite." -f $target) }
        Write-Step 'OK' ("Pré-backup {0} : {1}" -f $target, $preDest)
    }
    foreach ($target in $targets) {
        & robocopy.exe (Join-Path $root ("ESP\" + $target)) ($chosen[$target].Letter + ':\') '/E' '/COPY:DAT' '/DCOPY:DAT' '/R:2' '/W:1' '/XJ' | Out-Null
        if ($LASTEXITCODE -ge 8) { throw ("Copie de restauration échouée pour {0}. Le pré-backup est dans {1}." -f $target, $preRoot) }
        Write-Step 'OK' ("Fichiers restaurés : " + $target)
    }
} finally {
    foreach ($mount in @($added)) {
        Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $mount.PartitionNumber -AccessPath ($mount.Letter + ':\') -ErrorAction SilentlyContinue
        Write-Step 'INFO' ("Lettre temporaire {0}: retirée." -f $mount.Letter)
    }
}

