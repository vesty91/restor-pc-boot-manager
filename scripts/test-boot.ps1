<#
.SYNOPSIS
  Lance le menu rEFInd v1.0.0 dans QEMU, uniquement avec des images sous test\.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'test'))
$logDirectory = Join-Path $testRoot 'logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
$logFile = Join-Path $logDirectory ('boot-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-BootStep {
    param([string]$Level, [string]$Message)
    $line = "[{0}] {1}" -f $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Assert-QemuCommandSafe {
    param([string]$CommandText, [string[]]$ImagePaths)
    $forbidden = @('\\.\PhysicalDrive', '/dev/sd', '/dev/nvme', '\\?\Volume')
    foreach ($token in $forbidden) {
        if ($CommandText.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw ("Commande QEMU refusée, jeton interdit : " + $token)
        }
    }
    foreach ($path in $ImagePaths) {
        $full = [IO.Path]::GetFullPath($path)
        $prefix = $testRoot + [IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("Image hors de test\ : " + $full)
        }
    }
}

function Test-WhpxAvailable {
    param([string]$QemuPath)
    $help = & $QemuPath -accel help 2>&1 | Out-String
    if ($help -notmatch '(?im)^whpx\b') { return $false }
    $errorFile = Join-Path $logDirectory 'whpx-probe.txt'
    if (Test-Path -LiteralPath $errorFile) { Remove-Item -LiteralPath $errorFile -Force }
    $process = Start-Process -FilePath $QemuPath -PassThru -WindowStyle Hidden -RedirectStandardError $errorFile -ArgumentList @(
        '-machine', 'q35', '-accel', 'whpx', '-m', '32', '-display', 'none', '-nodefaults', '-serial', 'null'
    )
    $finished = $process.WaitForExit(2500)
    if (-not $finished) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        return $true
    }
    $probe = ''
    if (Test-Path -LiteralPath $errorFile) { $probe = Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue }
    return ($probe -notmatch 'whpx|WHPX|failed to initialize')
}

try {
    Assert-QemuCommandSafe -CommandText 'qemu \\.\PhysicalDrive0 /dev/nvme0n1 \\?\Volume{test}' -ImagePaths @()
    throw 'Le contrôle de sécurité aurait dû refuser la commande.'
} catch {
    if ($_.Exception.Message -notmatch 'PhysicalDrive') { throw }
    Write-BootStep 'OK' 'Commande contenant \\.\PhysicalDrive refusée.'
}
Write-BootStep 'INFO' ("Dépôt : " + $projectRoot)
. (Join-Path $PSScriptRoot 'check-qemu.ps1')
if ((Invoke-QemuCheck) -ne 0) {
    Write-BootStep 'ERROR' 'QEMU ou OVMF est absent. Aucune image physique n''est utilisée.'
    exit 1
}
$tools = Get-QemuToolSet
& (Join-Path $PSScriptRoot 'build-test-disk.ps1')
if ($LASTEXITCODE -ne 0) {
    Write-BootStep 'ERROR' ("Construction interrompue (code {0})." -f $LASTEXITCODE)
    exit $LASTEXITCODE
}

$images = @(
    'restor-boot.img',
    'code-efi.img',
    'vesty-efi.img',
    'rescue-efi.img',
    'lockpick-efi.img'
) | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $testRoot $_)) }
foreach ($image in $images) {
    if (-not (Test-Path -LiteralPath $image)) {
        Write-BootStep 'ERROR' ("Image virtuelle absente : " + $image)
        exit 1
    }
    $length = (Get-Item -LiteralPath $image).Length
    if ($length -ne 64MB) {
        Write-BootStep 'ERROR' ("Taille inattendue pour {0} : {1}" -f $image, $length)
        exit 1
    }
    Write-BootStep 'OK' ("Image virtuelle : " + $image)
}

$varsCopy = Join-Path $logDirectory 'OVMF_VARS.temp.fd'
if (Test-Path -LiteralPath $varsCopy) {
    Write-BootStep 'WARN' ("Remplacement de la copie OVMF_VARS : " + $varsCopy)
    Remove-Item -LiteralPath $varsCopy -Force
}
Copy-Item -LiteralPath $tools.OvmfVars -Destination $varsCopy -Force

$accel = 'tcg'
if (Test-WhpxAvailable -QemuPath $tools.Qemu) {
    $accel = 'whpx'
    Write-BootStep 'OK' 'Accélération WHPX disponible.'
} else {
    Write-BootStep 'WARN' 'WHPX indisponible. QEMU démarre avec -accel tcg.'
}

$qemuArgs = @(
    '-machine', 'q35',
    '-accel', $accel,
    '-m', '2048',
    '-smp', '2',
    '-vga', 'std',
    '-display', 'gtk,show-cursor=on',
    '-drive', ('if=pflash,format=raw,readonly=on,file=' + $tools.OvmfCode),
    '-drive', ('if=pflash,format=raw,file=' + $varsCopy),
    '-device', 'ahci,id=ahci'
)
for ($index = 0; $index -lt $images.Count; $index++) {
    $id = 'disk' + $index
    $qemuArgs += @('-drive', ('if=none,id=' + $id + ',format=raw,file=' + $images[$index]))
    $boot = if ($index -eq 0) { ',bootindex=1' } else { '' }
    $qemuArgs += @('-device', ('ide-hd,drive=' + $id + ',bus=ahci.' + $index + $boot))
}
$commandText = $tools.Qemu + ' ' + ($qemuArgs -join ' ')
Assert-QemuCommandSafe -CommandText $commandText -ImagePaths $images
Write-BootStep 'INFO' 'Contrôleur AHCI/SATA : OVMF voit les volumes RESTOR-BOOT, CODE-EFI, VESTY-EFI, RESCUE-EFI et LOCKPICK-EFI.'
Write-BootStep 'INFO' 'Les chargeurs Windows, RescueGrid, Lockpick et MemTest de ces images sont des stubs de test, sauf mt86plus.efi s''il a été fourni localement.'
Write-BootStep 'INFO' ("Commande QEMU : " + $commandText)
$process = Start-Process -FilePath $tools.Qemu -ArgumentList $qemuArgs -Wait -PassThru
Write-BootStep 'OK' ("QEMU terminé, code " + $process.ExitCode)
exit 0
