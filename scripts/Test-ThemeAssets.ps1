<#
.SYNOPSIS
  Vérifie le thème RESTOR-PC et l'en-tête PNG des icônes, sans ImageMagick.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$themeRoot = Join-Path $repoRoot 'theme\restor-pc'
$assetsRoot = Join-Path $themeRoot 'assets'
$winVestyHash = 'CC67BBF03D668EE61DE3A4F620C3855DF4D2430F2D2BCB473658CF1CE53331F6'
$failed = $false

function Get-BeUInt32 {
    param([byte[]]$Buffer, [int]$Offset)
    $value = ([uint64]$Buffer[$Offset] -shl 24) -bor ([uint64]$Buffer[$Offset + 1] -shl 16) -bor ([uint64]$Buffer[$Offset + 2] -shl 8) -bor [uint64]$Buffer[$Offset + 3]
    return [uint32]$value
}

function Get-PngCrc32 {
    param([byte[]]$Buffer, [int]$Offset, [int]$Count)
    $polynomial = [uint32]3988292384
    $crc = [uint32]::MaxValue
    for ($i = 0; $i -lt $Count; $i++) {
        $crc = [uint32]($crc -bxor $Buffer[$Offset + $i])
        for ($bit = 0; $bit -lt 8; $bit++) {
            $shifted = [uint32]($crc -shr 1)
            if (($crc -band 1) -ne 0) { $crc = [uint32]($shifted -bxor $polynomial) }
            else { $crc = $shifted }
        }
    }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}

function Test-PngCompatibleDepth {
    param([int]$ColorType, [int]$BitDepth)
    $allowed = @{
        0 = @(1, 2, 4, 8, 16)
        2 = @(8, 16)
        3 = @(1, 2, 4, 8)
        4 = @(8, 16)
        6 = @(8, 16)
    }
    if (-not $allowed.ContainsKey($ColorType)) { return $false }
    return $allowed[$ColorType] -contains $BitDepth
}

function Test-PngFile {
    param(
        [string]$Path,
        [int]$ExpectedWidth = 0,
        [int]$ExpectedHeight = 0
    )
    $name = Split-Path -Leaf $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host ("[ERROR] PNG absent : {0}" -f $Path)
        return $false
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 33) {
        Write-Host ("[ERROR] {0} : fichier vide ou trop court." -f $name)
        return $false
    }
    $signature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    for ($index = 0; $index -lt $signature.Length; $index++) {
        if ($bytes[$index] -ne $signature[$index]) {
            Write-Host ("[ERROR] {0} : signature PNG invalide." -f $name)
            return $false
        }
    }
    $length = Get-BeUInt32 -Buffer $bytes -Offset 8
    $type = [Text.Encoding]::ASCII.GetString($bytes, 12, 4)
    if ($length -ne 13 -or $type -ne 'IHDR') {
        Write-Host ("[ERROR] {0} : IHDR absent ou longueur {1}." -f $name, $length)
        return $false
    }
    $storedCrc = Get-BeUInt32 -Buffer $bytes -Offset 29
    $computedCrc = Get-PngCrc32 -Buffer $bytes -Offset 12 -Count 17
    if ($storedCrc -ne $computedCrc) {
        Write-Host ("[ERROR] {0} : CRC IHDR incorrect." -f $name)
        return $false
    }
    $width = [int](Get-BeUInt32 -Buffer $bytes -Offset 16)
    $height = [int](Get-BeUInt32 -Buffer $bytes -Offset 20)
    $bitDepth = [int]$bytes[24]
    $colorType = [int]$bytes[25]
    $compression = [int]$bytes[26]
    $filter = [int]$bytes[27]
    if ($compression -ne 0 -or $filter -ne 0) {
        Write-Host ("[ERROR] {0} : méthode de compression ou de filtre IHDR invalide." -f $name)
        return $false
    }
    if (-not (Test-PngCompatibleDepth -ColorType $colorType -BitDepth $bitDepth)) {
        Write-Host ("[ERROR] {0} : profondeur {1} incompatible avec le type couleur {2}." -f $name, $bitDepth, $colorType)
        return $false
    }
    if ($ExpectedWidth -gt 0 -and ($width -ne $ExpectedWidth -or $height -ne $ExpectedHeight)) {
        Write-Host ("[ERROR] {0} : {1}x{2}, attendu {3}x{4}." -f $name, $width, $height, $ExpectedWidth, $ExpectedHeight)
        return $false
    }
    if ($width -le 0 -or $height -le 0) {
        Write-Host ("[ERROR] {0} : dimensions IHDR invalides." -f $name)
        return $false
    }
    return $true
}

$themePath = Join-Path $themeRoot 'theme.conf'
if (-not (Test-Path -LiteralPath $themePath -PathType Leaf)) {
    Write-Host '[ERROR] theme\restor-pc\theme.conf est absent.'
    exit 1
}
$themeText = Get-Content -LiteralPath $themePath -Raw
foreach ($assetName in @('background.png', 'selection_big.png', 'selection_small.png')) {
    if ($themeText -notlike ('*' + $assetName + '*')) {
        $failed = $true
        Write-Host ("[ERROR] theme.conf ne référence pas {0}." -f $assetName)
    }
}
if ($themeText -notmatch '(?m)^big_icon_size\s+176\s*$') {
    $failed = $true
    Write-Host '[ERROR] big_icon_size 176 est absent de theme.conf.'
}

$icons = @(
    'win_code.png',
    'win_vesty.png',
    'memtest86plus.png',
    'rescuegrid.png',
    'lockpick.png'
)
foreach ($icon in $icons) {
    if (-not (Test-PngFile -Path (Join-Path $assetsRoot $icon) -ExpectedWidth 176 -ExpectedHeight 176)) {
        $failed = $true
    }
}
foreach ($chrome in @('background.png', 'selection_big.png', 'selection_small.png')) {
    if (-not (Test-PngFile -Path (Join-Path $assetsRoot $chrome))) {
        $failed = $true
    }
}

$vestyPath = Join-Path $assetsRoot 'win_vesty.png'
if (Test-Path -LiteralPath $vestyPath -PathType Leaf) {
    $hash = (Get-FileHash -LiteralPath $vestyPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($hash -ne $winVestyHash) {
        $failed = $true
        Write-Host ("[ERROR] WIN VESTY SHA256 {0}, attendu {1}." -f $hash, $winVestyHash)
    }
}

if ($failed) { exit 1 }
Write-Host '[OK] theme assets valid'
exit 0
