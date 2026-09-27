<#
.SYNOPSIS
  Affiche l'inventaire du VHDX de laboratoire s'il est associe a un disque.
#>
[CmdletBinding()]
param(
    [string]$LabRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($LabRoot)) {
    $LabRoot = Join-Path $repoRoot 'test\vhd\restore-lab'
}
$lab = [IO.Path]::GetFullPath($LabRoot)
$vhdPath = Join-Path $lab 'restor-restore-lab.vhdx'
if (-not (Test-Path -LiteralPath $vhdPath -PathType Leaf)) {
    Write-Host '[ERROR] VHDX absent.'
    exit 1
}
$image = Get-DiskImage -ImagePath $vhdPath
if (-not $image.Attached) {
    Write-Host '[ERROR] VHDX non attache. Association disque non prouvee.'
    exit 1
}
$disk = Get-DiskImage -ImagePath $vhdPath | Get-Disk
if ($null -eq $disk -or [int]$disk.Number -ne [int]$image.Number) {
    Write-Host '[ERROR] Le disque retourne ne correspond pas au VHDX.'
    exit 1
}
Write-Host ("VHDX : {0}" -f $vhdPath)
Write-Host ("DiskNumber : {0}" -f $disk.Number)
foreach ($partition in @(Get-Partition -DiskNumber $disk.Number)) {
    $letter = [string]$partition.DriveLetter
    $label = ''
    $fileSystem = ''
    if ($letter -match '^[A-Za-z]$') {
        $volume = Get-Volume -DriveLetter $letter
        $label = [string]$volume.FileSystemLabel
        $fileSystem = [string]$volume.FileSystem
    }
    Write-Host ("Partition {0} lettre {1} label {2} size {3} fs {4} gpt {5}" -f $partition.PartitionNumber, $letter, $label, $partition.Size, $fileSystem, $partition.GptType)
}
Write-Host '[OK] virtual disk associated with VHDX'
exit 0
