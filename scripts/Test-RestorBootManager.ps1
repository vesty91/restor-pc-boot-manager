[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(0,255)]
    [int]$DiskNumber
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PartitionByLabel {
    param([int]$Disk,[string]$Label)
    foreach ($p in Get-Partition -DiskNumber $Disk) {
        $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
        if ($v -and $v.FileSystemLabel -eq $Label) { return $p }
    }
    return $null
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
    foreach ($disk in (Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
        if ($disk.DeviceID -match '^([A-Za-z]):$') { [void]$used.Add([char]$Matches[1].ToUpperInvariant()) }
    }
    foreach ($letter in 'R','S','T','W') {
        if (Test-Path -LiteralPath ($letter + ':\')) { [void]$used.Add([char]$letter) }
        if (-not $used.Contains([char]$letter)) { return $letter }
    }
    throw 'Aucune lettre temporaire libre (R, S, T, W).'
}

$disk = Get-Disk -Number $DiskNumber
$labels = 'RESTOR-BOOT','CODE-EFI','VESTY-EFI','RESTOR-TOOLS','RESCUE-EFI'
$parts = @{}

foreach ($label in $labels) {
    $p = Get-PartitionByLabel -Disk $DiskNumber -Label $label
    if (-not $p) { throw ('Partition/volume manquant : ' + $label) }
    $parts[$label] = $p
}

$mounted = @()

function Mount-Temporary {
    param($Partition)
    if ($Partition.DriveLetter) { return ($Partition.DriveLetter + ':\') }
    $letter = Get-FreeDriveLetter
    $access = ($letter + ':\')
    Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath $access
    $script:mounted += [pscustomobject]@{ Partition=$Partition; Letter=$letter }
    return $access
}

try {
    $r = Mount-Temporary $parts['RESTOR-BOOT']
    $c = Mount-Temporary $parts['CODE-EFI']
    $v = Mount-Temporary $parts['VESTY-EFI']
    $rescue = Mount-Temporary $parts['RESCUE-EFI']
    $tools = Mount-Temporary $parts['RESTOR-TOOLS']

    $checks = [ordered]@{
        'rEFInd'          = Join-Path $r 'EFI\BOOT\BOOTX64.EFI'
        'refind.conf'     = Join-Path $r 'EFI\BOOT\refind.conf'
        'theme.conf'      = Join-Path $r 'EFI\BOOT\themes\restor-pc\theme.conf'
        'WIN CODE icon'   = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\win_code.png'
        'WIN VESTY icon'  = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\win_vesty.png'
        'MemTest icon'    = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\memtest86plus.png'
        'rescuegrid.png'  = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\rescuegrid.png'
        'MemTest EFI'     = Join-Path $r 'EFI\TOOLS\MEMTEST\mt86plus.efi'
        'CODE bootmgfw'   = Join-Path $c 'EFI\Microsoft\Boot\bootmgfw.efi'
        'CODE BCD'        = Join-Path $c 'EFI\Microsoft\Boot\BCD'
        'VESTY bootmgfw'  = Join-Path $v 'EFI\Microsoft\Boot\bootmgfw.efi'
        'VESTY BCD'       = Join-Path $v 'EFI\Microsoft\Boot\BCD'
        'RESCUE bootmgfw' = Join-Path $rescue 'EFI\Microsoft\Boot\bootmgfw.efi'
        'RESCUE BCD'      = Join-Path $rescue 'EFI\Microsoft\Boot\BCD'
        'boot.wim'        = Join-Path $tools 'WinPE\RescueGrid\boot.wim'
        'boot.sdi'        = Join-Path $tools 'WinPE\RescueGrid\boot.sdi'
        'RescueGrid desktop' = Join-Path $tools 'RescueGrid\agent\windows\Setup-WinPEDesktop.ps1'
    }

    $failed = $false
    foreach ($item in $checks.GetEnumerator()) {
        $ok = Test-Path -LiteralPath $item.Value
        if (-not $ok) { $failed = $true }
        [pscustomobject]@{
            Check = $item.Key
            Status = if ($ok) { 'OK' } else { 'MISSING' }
            Path = $item.Value
        }
    }

    $configPath = Join-Path $r 'EFI\BOOT\refind.conf'
    $configText = ''
    if (Test-Path -LiteralPath $configPath) {
        $configText = Get-Content -LiteralPath $configPath -Raw
    }
    foreach ($entryName in @('WIN CODE', 'WIN VESTY', 'MEMTEST86+', 'RESCUEGRID')) {
        $present = $configText.Contains('menuentry "' + $entryName + '"')
        if (-not $present) { $failed = $true }
        [pscustomobject]@{
            Check = ('refind ' + $entryName)
            Status = if ($present) { 'OK' } else { 'MISSING' }
            Path = $configPath
        }
    }

    $bcdPath = Join-Path $rescue 'EFI\Microsoft\Boot\BCD'
    $bcdOk = $false
    $bcdDetail = 'BCD RescueGrid illisible'
    if (Test-Path -LiteralPath $bcdPath) {
        $bcdText = (& bcdedit.exe /store $bcdPath /enum all /v | Out-String)
        $hasDescription = $bcdText.Contains('RESTOR-PC RESCUEGRID')
        $hasWim = $bcdText.Contains('\WinPE\RescueGrid\boot.wim')
        $hasSdi = $bcdText.Contains('\WinPE\RescueGrid\boot.sdi')
        $bcdOk = $hasDescription -and $hasWim -and $hasSdi
        $bcdDetail = if ($bcdOk) { 'RESTOR-PC RESCUEGRID -> WinPE\RescueGrid' } else { 'BCD sans cible WinPE RescueGrid' }
    }
    if (-not $bcdOk) { $failed = $true }
    [pscustomobject]@{
        Check = 'BCD RescueGrid'
        Status = if ($bcdOk) { 'OK' } else { 'MISSING' }
        Path = $bcdDetail
    }

    [pscustomobject]@{
        DiskNumber = $disk.Number
        FriendlyName = $disk.FriendlyName
        IsBoot = $disk.IsBoot
        IsSystem = $disk.IsSystem
        LargestFreeExtentGB = [math]::Round($disk.LargestFreeExtent / 1GB,2)
    }

    if ($failed) { throw 'Validation RESTOR-PC échouée.' }
    Write-Host 'Validation RESTOR-PC réussie.' -ForegroundColor Green
}
finally {
    foreach ($m in $mounted) {
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $m.Partition.PartitionNumber -AccessPath ($m.Letter + ':\') -ErrorAction SilentlyContinue
    }
}
