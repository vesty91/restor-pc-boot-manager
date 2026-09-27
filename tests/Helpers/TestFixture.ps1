Set-StrictMode -Version Latest

$script:RestorVestyHash = 'CC67BBF03D668EE61DE3A4F620C3855DF4D2430F2D2BCB473658CF1CE53331F6'

function Get-RestorUtf8 {
    New-Object System.Text.UTF8Encoding $false
}

function Write-RestorTextFile {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Content, (Get-RestorUtf8))
}

function Update-RestorTestManifest {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Status = 'VALID'
    )
    $lines = @(Get-RestorManifestLine -Root $Root -ExcludedNames @('SHA256-MANIFEST.txt'))
    $manifestPath = Join-Path $Root 'Manifests\SHA256-MANIFEST.txt'
    $parent = Split-Path -Parent $manifestPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllLines($manifestPath, [string[]]$lines, (Get-RestorUtf8))
    $hash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $info = [ordered]@{
        Status          = $Status
        ManifestSha256  = $hash
        ExpectedModel   = 'RESTOR-PC TEST NVME'
        ExpectedSerial  = 'TEST_SERIAL_0001'
    }
    [IO.File]::WriteAllText((Join-Path $Root 'BACKUP-INFO.json'), ($info | ConvertTo-Json), (Get-RestorUtf8))
}

function Sync-RestorTestManifestHash {
    param([Parameter(Mandatory)][string]$Root)
    $manifestPath = Join-Path $Root 'Manifests\SHA256-MANIFEST.txt'
    $hash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToUpperInvariant()
    $infoPath = Join-Path $Root 'BACKUP-INFO.json'
    $info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $info.ManifestSha256 = $hash
    [IO.File]::WriteAllText($infoPath, ($info | ConvertTo-Json), (Get-RestorUtf8))
}

function Set-RestorTestBackupStatus {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Status
    )
    $infoPath = Join-Path $Root 'BACKUP-INFO.json'
    $info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $info.Status = $Status
    [IO.File]::WriteAllText($infoPath, ($info | ConvertTo-Json), (Get-RestorUtf8))
}

function New-RestorTestGoldenBackup {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Status = 'VALID'
    )
    if (Test-Path -LiteralPath $Root) {
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $vestySource = Join-Path $RepoRoot 'theme\restor-pc\assets\win_vesty.png'
    $vestyHash = (Get-FileHash -LiteralPath $vestySource -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($vestyHash -ne $script:RestorVestyHash) {
        throw 'La fixture refuse win_vesty.png : le hash du depot a change.'
    }
    $files = @{
        'ESP\RESTOR-BOOT\EFI\BOOT\BOOTX64.EFI' = 'TEST EFI FILE RESTOR-BOOT'
        'ESP\CODE-EFI\EFI\Microsoft\Boot\bootmgfw.efi' = 'TEST EFI FILE CODE'
        'ESP\VESTY-EFI\EFI\Microsoft\Boot\bootmgfw.efi' = 'TEST EFI FILE VESTY'
        'ESP\RESCUE-EFI\EFI\Microsoft\Boot\bootmgfw.efi' = 'TEST EFI FILE RESCUE'
        'ESP\LOCKPICK-EFI\EFI\BOOT\BOOTX64.EFI' = 'TEST EFI FILE LOCKPICK'
        'BCD\CODE-EFI\BCD' = 'TEST BCD CODE'
        'BCD\VESTY-EFI\BCD' = 'TEST BCD VESTY'
        'BCD\RESCUE-EFI\BCD' = 'TEST BCD RESCUE'
        'Metadata\NVME-IDENTITY.txt' = "Model: RESTOR-PC TEST NVME`r`nSerial: TEST_SERIAL_0001`r`n"
        'Metadata\PARTITION-LAYOUT.json' = '{"note":"synthetic fixture"}'
        'Metadata\REFIND-CONFIG.txt' = 'synthetic refind copy'
        'Metadata\GIT-STATE.txt' = 'synthetic'
        'RESTOR-TOOLS\RescueGrid\WinPE\boot.wim' = 'TEST BOOT WIM PLACEHOLDER'
        'RESTOR-TOOLS\RescueGrid\WinPE\boot.sdi' = 'TEST BOOT SDI PLACEHOLDER'
    }
    foreach ($relative in $files.Keys) {
        Write-RestorTextFile -Path (Join-Path $Root $relative) -Content $files[$relative]
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'config\refind.conf') -Destination (Join-Path $Root 'ESP\RESTOR-BOOT\EFI\BOOT\refind.conf') -Force
    $vestyDestination = Join-Path $Root 'ESP\RESTOR-BOOT\EFI\BOOT\themes\restor-pc\assets\win_vesty.png'
    $vestyParent = Split-Path -Parent $vestyDestination
    New-Item -ItemType Directory -Path $vestyParent -Force | Out-Null
    Copy-Item -LiteralPath $vestySource -Destination $vestyDestination -Force
    Update-RestorTestManifest -Root $Root -Status $Status
    return $Root
}

function Invoke-RestorChecked {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Parameter = @{}
    )
    $previous = $env:RESTOR_PC_INLINE_TEST
    $env:RESTOR_PC_INLINE_TEST = '1'
    $global:RestorCaptured = New-Object System.Collections.Generic.List[string]
    Mock Write-Host -MockWith {
        param($Object)
        $global:RestorCaptured.Add([string]$Object)
    }
    try {
        & $Path @Parameter
        return [pscustomobject]@{ Code = 0; Output = @($global:RestorCaptured); Error = '' }
    } catch {
        $message = [string]$_.Exception.Message
        if ($message -like 'RESTOR-PC-EXIT:*') {
            $codeText = $message.Substring('RESTOR-PC-EXIT:'.Length)
            return [pscustomobject]@{ Code = [int]$codeText; Output = @($global:RestorCaptured); Error = '' }
        }
        return [pscustomobject]@{ Code = 1; Output = @($global:RestorCaptured); Error = $message }
    } finally {
        if ($null -eq $previous) {
            Remove-Item Env:\RESTOR_PC_INLINE_TEST -ErrorAction SilentlyContinue
        } else {
            $env:RESTOR_PC_INLINE_TEST = $previous
        }
    }
}
