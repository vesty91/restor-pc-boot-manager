<#
.SYNOPSIS
  Verification en lecture seule d'un Golden Backup RESTOR-PC.
#>

Set-StrictMode -Version Latest

$script:RestorVestyRelativePath = 'ESP\RESTOR-BOOT\EFI\BOOT\themes\restor-pc\assets\win_vesty.png'
$script:RestorRefindRelativePath = 'ESP\RESTOR-BOOT\EFI\BOOT\refind.conf'
$script:RestorBootWimRelativePath = 'RESTOR-TOOLS\RescueGrid\WinPE\boot.wim'
$script:RestorBootSdiRelativePath = 'RESTOR-TOOLS\RescueGrid\WinPE\boot.sdi'
$script:RestorDefaultVestySha256 = 'CC67BBF03D668EE61DE3A4F620C3855DF4D2430F2D2BCB473658CF1CE53331F6'

function Get-RestorRequiredBackupRelativePath {
    @(
        'ESP\RESTOR-BOOT\EFI\BOOT\refind.conf',
        'ESP\RESTOR-BOOT\EFI\BOOT\BOOTX64.EFI',
        'ESP\RESTOR-BOOT\EFI\TOOLS\MEMTEST\mt86plus.efi',
        'ESP\CODE-EFI\EFI\Microsoft\Boot\bootmgfw.efi',
        'ESP\VESTY-EFI\EFI\Microsoft\Boot\bootmgfw.efi',
        'ESP\RESCUE-EFI\EFI\Microsoft\Boot\bootmgfw.efi',
        'ESP\LOCKPICK-EFI\EFI\BOOT\BOOTX64.EFI',
        'ESP\LOCKPICK-EFI\EFI\Microsoft\Boot\BCD',
        'ESP\LOCKPICK-EFI\boot\boot.sdi',
        'ESP\LOCKPICK-EFI\sources\boot.wim',
        'BCD\CODE-EFI\BCD',
        'BCD\VESTY-EFI\BCD',
        'BCD\RESCUE-EFI\BCD',
        'Metadata\NVME-IDENTITY.txt',
        'Metadata\PARTITION-LAYOUT.json',
        'Metadata\REFIND-CONFIG.txt',
        'Metadata\GIT-STATE.txt',
        'RESTOR-TOOLS\RescueGrid\Project\agent\windows\Setup-WinPEDesktop.ps1',
        'RESTOR-TOOLS\RescueGrid\Project\agent\windows\Start-RescueGrid.ps1'
    )
}

function Test-RestorBackupMetadataPath {
    param([string]$RelativePath)
    $comparer = [StringComparer]::OrdinalIgnoreCase
    if ($comparer.Equals($RelativePath, 'BACKUP-INFO.json')) { return $true }
    if ($comparer.Equals($RelativePath, 'Manifests\SHA256-MANIFEST.txt')) { return $true }
    return $false
}

function Resolve-RestorBackupEntryPath {
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $rejected = [pscustomobject]@{ Safe = $false; FullPath = '' }
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $rejected }
    $normalized = $RelativePath.Replace('/', '\')
    if ($normalized.StartsWith('\\') -or $normalized.StartsWith('\')) { return $rejected }
    if ($normalized -match '^[A-Za-z]:') { return $rejected }
    if ($normalized.Contains(':')) { return $rejected }
    foreach ($segment in @($normalized.Split('\'))) {
        if ($segment -eq '..') { return $rejected }
    }
    $combined = Join-Path $BackupRoot $normalized
    $full = [IO.Path]::GetFullPath($combined)
    $prefix = $BackupRoot.TrimEnd('\') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $rejected }
    return [pscustomobject]@{ Safe = $true; FullPath = $full }
}

function Test-RestorBackupIntegrity {
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [string]$ExpectedVestySha256 = $script:RestorDefaultVestySha256
    )

    $failures = New-Object System.Collections.Generic.List[string]
    $missingFiles = New-Object System.Collections.Generic.List[string]
    $hashMismatches = New-Object System.Collections.Generic.List[string]
    $unexpectedFiles = New-Object System.Collections.Generic.List[string]
    $invalidLines = New-Object System.Collections.Generic.List[string]
    $duplicateEntries = New-Object System.Collections.Generic.List[string]
    $unsafePaths = New-Object System.Collections.Generic.List[string]
    $structureFailures = New-Object System.Collections.Generic.List[string]
    $observedPaths = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)

    $status = ''
    $expectedManifestHash = ''
    $actualManifestHash = ''
    $manifestHashValid = $false
    $filesExpected = 0
    $filesVerified = 0
    $vestyHashValid = $false
    $refindConfigValid = $false
    $rescueGridValid = $false
    $infoReadable = $false
    $root = ''

    try {
        $root = [IO.Path]::GetFullPath($BackupPath)
    } catch {
        $failures.Add('BackupPath illisible.')
        $root = ''
    }

    $rootExists = -not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)
    if (-not $rootExists -and [string]::IsNullOrWhiteSpace(($failures | Select-Object -First 1))) {
        $failures.Add('BackupPath absent.')
    }

    $infoPath = ''
    $manifestPath = ''
    if ($rootExists) {
        $infoPath = Join-Path $root 'BACKUP-INFO.json'
        $manifestPath = Join-Path $root 'Manifests\SHA256-MANIFEST.txt'
        $infoExists = Test-Path -LiteralPath $infoPath -PathType Leaf
        $manifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
        if (-not $infoExists) { $failures.Add('BACKUP-INFO.json absent.') }
        if (-not $manifestExists) { $failures.Add('SHA256-MANIFEST.txt absent.') }

        if ($infoExists) {
            try {
                $info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $infoReadable = $true
                if ($null -ne $info.PSObject.Properties['Status']) { $status = [string]$info.Status }
                if ($null -ne $info.PSObject.Properties['ManifestSha256']) { $expectedManifestHash = ([string]$info.ManifestSha256).Trim() }
            } catch {
                $failures.Add('BACKUP-INFO.json illisible.')
            }
        }

        if ($manifestExists) {
            $actualManifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToUpperInvariant()
        }

        if ($infoReadable -and $manifestExists) {
            $manifestHashValid = -not [string]::IsNullOrWhiteSpace($expectedManifestHash) -and
                $expectedManifestHash.Equals($actualManifestHash, [StringComparison]::OrdinalIgnoreCase)
            if (-not $manifestHashValid) { $failures.Add('ManifestSha256 ne correspond pas au fichier manifeste.') }
        }

        if ($infoReadable -and -not [string]::Equals($status, 'VALID', [StringComparison]::Ordinal)) {
            $failures.Add('Status du backup : ' + $status)
        }

        if ($manifestExists) {
            $lines = @(Get-Content -LiteralPath $manifestPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            foreach ($line in $lines) {
                $manifestMatch = [regex]::Match([string]$line, '^([A-Fa-f0-9]{64})  (.+)$')
                if (-not $manifestMatch.Success) {
                    $invalidLines.Add([string]$line)
                    $failures.Add('Ligne manifeste illisible : ' + $line)
                    continue
                }
                $expectedHash = $manifestMatch.Groups[1].Value
                $relative = $manifestMatch.Groups[2].Value
                $key = $relative.Replace('/', '\')
                $observedPaths.Add($key)
                if ($seen.ContainsKey($key)) {
                    $duplicateEntries.Add($relative)
                    $failures.Add('Doublon manifeste : ' + $relative)
                    continue
                }
                $resolved = Resolve-RestorBackupEntryPath -BackupRoot $root -RelativePath $key
                if (-not $resolved.Safe) {
                    $unsafePaths.Add($relative)
                    $failures.Add('Chemin manifeste dangereux : ' + $relative)
                    $seen[$key] = $relative
                    continue
                }
                $seen[$key] = $relative
                $filesExpected++
                if (-not (Test-Path -LiteralPath $resolved.FullPath -PathType Leaf)) {
                    $missingFiles.Add($relative)
                    $failures.Add('Fichier absent : ' + $relative)
                    continue
                }
                $actualHash = (Get-FileHash -LiteralPath $resolved.FullPath -Algorithm SHA256).Hash
                $filesVerified++
                if (-not $actualHash.Equals($expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
                    $hashMismatches.Add($relative)
                    $failures.Add('Fichier modifié : ' + $relative)
                }
            }

            if ($observedPaths.Count -gt 1) {
                $sortedPaths = [string[]]@($observedPaths.ToArray() | Sort-Object)
                $currentPaths = [string[]]$observedPaths.ToArray()
                if (($currentPaths -join "`n") -ne ($sortedPaths -join "`n")) {
                    $failures.Add('Le manifeste n''est pas trié.')
                }
            }
        }

        $prefix = $root.TrimEnd('\') + [IO.Path]::DirectorySeparatorChar
        $onDisk = @()
        try {
            $onDisk = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop)
        } catch {
            $failures.Add('Lecture du backup impossible.')
        }
        foreach ($file in $onDisk) {
            $full = [IO.Path]::GetFullPath($file.FullName)
            if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $unsafePaths.Add($full)
                $failures.Add('Chemin manifeste dangereux : ' + $full)
                continue
            }
            $relativeOnDisk = $full.Substring($prefix.Length)
            if (Test-RestorBackupMetadataPath -RelativePath $relativeOnDisk) { continue }
            if (-not $seen.ContainsKey($relativeOnDisk)) {
                $unexpectedFiles.Add($relativeOnDisk)
                $failures.Add('Fichier hors manifeste : ' + $relativeOnDisk)
            }
        }

        foreach ($required in @(Get-RestorRequiredBackupRelativePath)) {
            $requiredFull = Join-Path $root $required
            if (-not (Test-Path -LiteralPath $requiredFull -PathType Leaf)) {
                $structureFailures.Add($required)
                $failures.Add('Structure absente : ' + $required)
            }
        }

        $vestyResolved = Resolve-RestorBackupEntryPath -BackupRoot $root -RelativePath $script:RestorVestyRelativePath
        if ($vestyResolved.Safe -and (Test-Path -LiteralPath $vestyResolved.FullPath -PathType Leaf)) {
            $vestyHash = (Get-FileHash -LiteralPath $vestyResolved.FullPath -Algorithm SHA256).Hash
            $vestyHashValid = $vestyHash.Equals($ExpectedVestySha256, [StringComparison]::OrdinalIgnoreCase)
            if (-not $vestyHashValid) { $failures.Add('WIN VESTY SHA256 ' + $vestyHash.ToUpperInvariant()) }
        } else {
            $failures.Add('win_vesty.png absent de la copie RESTOR-BOOT.')
        }

        $configResolved = Resolve-RestorBackupEntryPath -BackupRoot $root -RelativePath $script:RestorRefindRelativePath
        if ($configResolved.Safe -and (Test-Path -LiteralPath $configResolved.FullPath -PathType Leaf)) {
            $configText = [IO.File]::ReadAllText($configResolved.FullPath)
            $refindConfigValid = $true
            foreach ($entryName in @('WIN CODE', 'WIN VESTY', 'MEMTEST86+', 'RESCUEGRID', 'LOCKPICK')) {
                $count = ([regex]::Matches($configText, [regex]::Escape('menuentry "' + $entryName + '"'))).Count
                if ($count -ne 1) {
                    $refindConfigValid = $false
                    $failures.Add(("Entrée {0} présente {1} fois." -f $entryName, $count))
                }
            }
        }

        $wimResolved = Resolve-RestorBackupEntryPath -BackupRoot $root -RelativePath $script:RestorBootWimRelativePath
        $sdiResolved = Resolve-RestorBackupEntryPath -BackupRoot $root -RelativePath $script:RestorBootSdiRelativePath
        $hasWim = $wimResolved.Safe -and (Test-Path -LiteralPath $wimResolved.FullPath -PathType Leaf)
        $hasSdi = $sdiResolved.Safe -and (Test-Path -LiteralPath $sdiResolved.FullPath -PathType Leaf)
        if ($hasWim -and $hasSdi) {
            $rescueGridValid = $true
        } else {
            if (-not $hasWim) { $failures.Add('boot.wim RescueGrid absent de la sauvegarde.') }
            if (-not $hasSdi) { $failures.Add('boot.sdi RescueGrid absent de la sauvegarde.') }
        }
    }

    $valid = $failures.Count -eq 0
    return [pscustomobject]@{
        Valid                  = $valid
        Status                 = $status
        ManifestHashValid      = $manifestHashValid
        ManifestSha256Expected = $expectedManifestHash
        ManifestSha256Actual   = $actualManifestHash
        FilesExpected          = $filesExpected
        FilesVerified          = $filesVerified
        MissingFiles           = [string[]]$missingFiles.ToArray()
        HashMismatches         = [string[]]$hashMismatches.ToArray()
        UnexpectedFiles        = [string[]]$unexpectedFiles.ToArray()
        InvalidManifestLines   = [string[]]$invalidLines.ToArray()
        DuplicateEntries       = [string[]]$duplicateEntries.ToArray()
        UnsafePaths            = [string[]]$unsafePaths.ToArray()
        StructureFailures      = [string[]]$structureFailures.ToArray()
        VestyHashValid         = $vestyHashValid
        RefindConfigValid      = $refindConfigValid
        RescueGridValid        = $rescueGridValid
        Failures               = [string[]]$failures.ToArray()
    }
}

function Get-RestorManifestSnapshot {
    param([Parameter(Mandatory)][string]$BackupPath)
    $root = [IO.Path]::GetFullPath($BackupPath)
    $manifestPath = Join-Path $root 'Manifests\SHA256-MANIFEST.txt'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'SHA256-MANIFEST.txt absent.'
    }
    $entries = New-Object System.Collections.ArrayList
    $lines = @(Get-Content -LiteralPath $manifestPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($line in $lines) {
        $manifestMatch = [regex]::Match([string]$line, '^([A-Fa-f0-9]{64})  (.+)$')
        if (-not $manifestMatch.Success) { throw ('Ligne manifeste illisible : ' + $line) }
        $relative = $manifestMatch.Groups[2].Value.Replace('/', '\')
        $resolved = Resolve-RestorBackupEntryPath -BackupRoot $root -RelativePath $relative
        if (-not $resolved.Safe) { throw ('Chemin manifeste dangereux : ' + $relative) }
        [void]$entries.Add([pscustomobject]@{
            RelativePath = $relative
            Sha256       = $manifestMatch.Groups[1].Value.ToUpperInvariant()
        })
    }
    return @($entries.ToArray())
}

function Test-RestorRestoredTarget {
    param(
        [Parameter(Mandatory)][string]$TargetName,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)]$ManifestSnapshot,
        [string]$RelativePrefix = ''
    )
    $prefix = if ([string]::IsNullOrWhiteSpace($RelativePrefix)) {
        'ESP\' + $TargetName + '\'
    } else {
        $RelativePrefix.Replace('/', '\').TrimEnd('\') + '\'
    }
    $missing = New-Object System.Collections.Generic.List[string]
    $mismatches = New-Object System.Collections.Generic.List[string]
    $expectedRelative = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $filesExpected = 0
    $filesVerified = 0
    foreach ($entry in @($ManifestSnapshot)) {
        $relative = [string]$entry.RelativePath
        if (-not $relative.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $leaf = $relative.Substring($prefix.Length)
        $resolved = Resolve-RestorBackupEntryPath -BackupRoot $DestinationRoot -RelativePath $leaf
        $filesExpected++
        if (-not $resolved.Safe) {
            $missing.Add($leaf)
            continue
        }
        $expectedRelative[$leaf] = [string]$entry.Sha256
        if (-not (Test-Path -LiteralPath $resolved.FullPath -PathType Leaf)) {
            $missing.Add($leaf)
            continue
        }
        $actual = (Get-FileHash -LiteralPath $resolved.FullPath -Algorithm SHA256).Hash
        $filesVerified++
        if (-not $actual.Equals([string]$entry.Sha256, [StringComparison]::OrdinalIgnoreCase)) {
            $mismatches.Add($leaf)
        }
    }
    $extra = 0
    if (Test-Path -LiteralPath $DestinationRoot) {
        $destRoot = (Resolve-Path -LiteralPath $DestinationRoot).ProviderPath
        $destPrefix = $destRoot.TrimEnd('\') + [IO.Path]::DirectorySeparatorChar
        $onDisk = @(Get-ChildItem -LiteralPath $DestinationRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
        foreach ($file in $onDisk) {
            $full = (Resolve-Path -LiteralPath $file.FullName).ProviderPath
            if (-not $full.StartsWith($destPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $relativeOnDisk = $full.Substring($destPrefix.Length)
            if (-not $expectedRelative.ContainsKey($relativeOnDisk)) { $extra++ }
        }
    }
    $valid = ($filesExpected -gt 0) -and ($missing.Count -eq 0) -and ($mismatches.Count -eq 0)
    return [pscustomobject]@{
        Target              = $TargetName
        FilesExpected       = $filesExpected
        FilesVerified       = $filesVerified
        MissingFiles        = [string[]]$missing.ToArray()
        HashMismatches      = [string[]]$mismatches.ToArray()
        ExtraFilesPreserved = $extra
        Valid               = $valid
    }
}

Export-ModuleMember -Function @(
    'Test-RestorBackupIntegrity',
    'Get-RestorManifestSnapshot',
    'Test-RestorRestoredTarget'
)
