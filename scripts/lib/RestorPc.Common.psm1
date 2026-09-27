<#
.SYNOPSIS
  Fonctions pures du boot manager. Aucun accès disque.
#>

Set-StrictMode -Version Latest

function ConvertTo-NormalizedSerial {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value.Trim().TrimEnd('.').ToUpperInvariant())
}

function Resolve-RestorDiskSelection {
    param(
        [object[]]$Disks = @(),
        [AllowEmptyString()][string]$Model = '',
        [AllowNull()][AllowEmptyString()][string]$Serial = ''
    )
    $expectedSerial = ConvertTo-NormalizedSerial $Serial
    $matchedDisks = New-Object System.Collections.ArrayList
    foreach ($candidate in @($Disks)) {
        if ($null -eq $candidate) { continue }
        $serial = ConvertTo-NormalizedSerial ([string]$candidate.SerialNumber)
        $modelName = ([string]$candidate.FriendlyName).Trim()
        if ($modelName -eq $Model.Trim() -and $serial -eq $expectedSerial) {
            [void]$matchedDisks.Add($candidate)
        }
    }
    if ($matchedDisks.Count -eq 0) {
        return [pscustomobject]@{ Code = 'None'; Disk = $null }
    }
    if ($matchedDisks.Count -gt 1) {
        return [pscustomobject]@{ Code = 'Ambiguous'; Disk = $null }
    }
    $disk = $matchedDisks[0]
    if ([string]$disk.PartitionStyle -ne 'GPT') {
        return [pscustomobject]@{ Code = 'NotGpt'; Disk = $disk }
    }
    if ([string]$disk.BusType -ne 'NVMe') {
        return [pscustomobject]@{ Code = 'NotNvme'; Disk = $disk }
    }
    return [pscustomobject]@{ Code = 'Ok'; Disk = $disk }
}

function Get-RestorRestoreTarget {
    param(
        [switch]$RestorBoot,
        [switch]$CodeEfi,
        [switch]$VestyEfi,
        [switch]$RescueEfi,
        [switch]$LockpickEfi,
        [switch]$AllEfi
    )
    $targets = @()
    if ($AllEfi -or $RestorBoot) { $targets += 'RESTOR-BOOT' }
    if ($AllEfi -or $CodeEfi) { $targets += 'CODE-EFI' }
    if ($AllEfi -or $VestyEfi) { $targets += 'VESTY-EFI' }
    if ($AllEfi -or $RescueEfi) { $targets += 'RESCUE-EFI' }
    if ($AllEfi -or $LockpickEfi) { $targets += 'LOCKPICK-EFI' }
    return @($targets | Select-Object -Unique)
}

function Test-RobocopySuccessCode {
    param($ExitCode)
    return -not ($ExitCode -ge 8)
}

function Resolve-RestorTemporaryLetter {
    param([string[]]$UsedLetter = @())
    $used = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($letter in @($UsedLetter)) {
        if (-not [string]::IsNullOrWhiteSpace($letter)) {
            [void]$used.Add($letter.ToUpperInvariant())
        }
    }
    foreach ($letter in @('R', 'S', 'T', 'W', 'Z', 'L')) {
        if (-not $used.Contains($letter)) { return $letter }
    }
    throw 'Aucune lettre temporaire libre parmi R, S, T, W, Z, L.'
}

function Get-RestorManifestLine {
    param([string]$Root, [string[]]$ExcludedNames = @())
    $lines = New-Object System.Collections.Generic.List[string]
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName)
    foreach ($file in $files) {
        if ($ExcludedNames -contains $file.Name -and $file.DirectoryName -eq (Join-Path $Root 'Manifests')) { continue }
        if ($file.Name -eq 'BACKUP-INFO.json' -and $file.DirectoryName -eq $Root) { continue }
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
        $lines.Add(('{0}  {1}' -f $hash, $relative))
    }
    return @($lines | Sort-Object { $_.Substring(66) })
}

function Exit-RestorCommand {
    param([int]$Code = 0)
    if ($env:RESTOR_PC_INLINE_TEST -eq '1') {
        throw ("RESTOR-PC-EXIT:{0}" -f $Code)
    }
    exit $Code
}

Export-ModuleMember -Function @(
    'ConvertTo-NormalizedSerial',
    'Resolve-RestorDiskSelection',
    'Get-RestorRestoreTarget',
    'Test-RobocopySuccessCode',
    'Resolve-RestorTemporaryLetter',
    'Get-RestorManifestLine',
    'Exit-RestorCommand'
)
