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
    $used = @(Get-Volume | Where-Object DriveLetter | ForEach-Object { [char]$_.DriveLetter })
    foreach ($letter in 'R','S','T','U','W','X','Y','Z') {
        if ([char]$letter -notin $used) { return $letter }
    }
    throw 'Aucune lettre temporaire libre.'
}

$disk = Get-Disk -Number $DiskNumber
$labels = 'RESTOR-BOOT','CODE-EFI','VESTY-EFI','RESTOR-TOOLS'
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

    $checks = [ordered]@{
        'rEFInd'          = Join-Path $r 'EFI\BOOT\BOOTX64.EFI'
        'refind.conf'     = Join-Path $r 'EFI\BOOT\refind.conf'
        'theme.conf'      = Join-Path $r 'EFI\BOOT\themes\restor-pc\theme.conf'
        'WIN CODE icon'   = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\win_code.png'
        'WIN VESTY icon'  = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\win_vesty.png'
        'MemTest icon'    = Join-Path $r 'EFI\BOOT\themes\restor-pc\assets\memtest86plus.png'
        'MemTest EFI'     = Join-Path $r 'EFI\TOOLS\MEMTEST\mt86plus.efi'
        'CODE bootmgfw'   = Join-Path $c 'EFI\Microsoft\Boot\bootmgfw.efi'
        'CODE BCD'        = Join-Path $c 'EFI\Microsoft\Boot\BCD'
        'VESTY bootmgfw'  = Join-Path $v 'EFI\Microsoft\Boot\bootmgfw.efi'
        'VESTY BCD'       = Join-Path $v 'EFI\Microsoft\Boot\BCD'
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
