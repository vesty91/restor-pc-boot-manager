[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(0,255)]
    [int]$DiskNumber,

    [Parameter()]
    [string]$DestinationRoot = 'C:\RESTOR-PC-BACKUP'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Ouvrez PowerShell en administrateur.'
    }
}

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

Assert-Administrator

$disk = Get-Disk -Number $DiskNumber
$requiredLabels = 'RESTOR-BOOT','CODE-EFI','VESTY-EFI'
$parts = @{}

foreach ($label in $requiredLabels) {
    $p = Get-PartitionByLabel -Disk $DiskNumber -Label $label
    if (-not $p) { throw ('Volume requis introuvable : ' + $label) }
    $parts[$label] = $p
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $DestinationRoot $timestamp
New-Item -ItemType Directory -Path $backup -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $backup 'Metadata') -Force | Out-Null

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

function Copy-Efi {
    param([string]$Source,[string]$Destination,[switch]$ExcludeBCD)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $args = @($Source,$Destination,'/E','/COPY:DAT','/DCOPY:DAT','/R:2','/W:1','/XJ')
    if ($ExcludeBCD) { $args += @('/XF','BCD','BCD.LOG','BCD.LOG1','BCD.LOG2') }
    & robocopy @args | Out-Null
    if ($LASTEXITCODE -ge 8) { throw ('Robocopy a échoué pour ' + $Source + ' (code ' + $LASTEXITCODE + ').') }
}

try {
    $r = Mount-Temporary $parts['RESTOR-BOOT']
    $c = Mount-Temporary $parts['CODE-EFI']
    $v = Mount-Temporary $parts['VESTY-EFI']

    Copy-Efi $r (Join-Path $backup 'RESTOR-BOOT')
    Copy-Efi $c (Join-Path $backup 'CODE-EFI') -ExcludeBCD
    Copy-Efi $v (Join-Path $backup 'VESTY-EFI') -ExcludeBCD

    bcdedit /store (Join-Path $c 'EFI\Microsoft\Boot\BCD') /enum all /v | Out-File (Join-Path $backup 'Metadata\BCD-WIN-CODE.txt') -Encoding utf8
    bcdedit /store (Join-Path $v 'EFI\Microsoft\Boot\BCD') /enum all /v | Out-File (Join-Path $backup 'Metadata\BCD-WIN-VESTY.txt') -Encoding utf8

    Get-Disk -Number $DiskNumber | Format-List * | Out-File (Join-Path $backup 'Metadata\disk.txt') -Encoding utf8
    Get-Partition -DiskNumber $DiskNumber | Select-Object DiskNumber,PartitionNumber,DriveLetter,Type,GptType,Guid,Offset,Size | Export-Csv (Join-Path $backup 'Metadata\partitions.csv') -NoTypeInformation -Encoding utf8

    Get-ChildItem $backup -Recurse -File | Where-Object Name -ne 'SHA256-MANIFEST.txt' | ForEach-Object {
        $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
        '{0}  {1}' -f $hash.Hash,$_.FullName.Substring($backup.Length + 1)
    } | Set-Content (Join-Path $backup 'SHA256-MANIFEST.txt') -Encoding ascii

    Write-Host ('Sauvegarde terminée : ' + $backup) -ForegroundColor Green
}
finally {
    foreach ($m in $mounted) {
        Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $m.Partition.PartitionNumber -AccessPath ($m.Letter + ':\') -ErrorAction SilentlyContinue
    }
}
