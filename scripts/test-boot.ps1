<#
.SYNOPSIS
  Lance le menu rEFInd v1.0.0 dans QEMU, uniquement avec des images sous test\.

.PARAMETER Accel
  tcg est le mode par défaut. whpx ne démarre que sur demande explicite.
  auto tente un vrai lancement WHPX, puis revient à TCG si ce lancement échoue.
#>
[CmdletBinding()]
param(
    [ValidateSet('tcg', 'whpx', 'auto')]
    [string]$Accel = 'tcg'
)

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

function ConvertTo-WindowsArgument {
    param([string]$Text)
    if ($Text -notmatch '[\s"]') { return $Text }
    $escaped = $Text -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-QemuArgumentLine {
    param(
        [string]$SelectedAccel,
        [string]$CodePath,
        [string]$VarsPath,
        [string[]]$ImagePaths
    )
    $qemuArgs = New-Object System.Collections.Generic.List[string]
    [void]$qemuArgs.Add('-machine')
    [void]$qemuArgs.Add('q35')
    [void]$qemuArgs.Add('-accel')
    [void]$qemuArgs.Add($SelectedAccel)
    [void]$qemuArgs.Add('-m')
    [void]$qemuArgs.Add('2048')
    [void]$qemuArgs.Add('-smp')
    [void]$qemuArgs.Add('2')
    [void]$qemuArgs.Add('-vga')
    [void]$qemuArgs.Add('std')
    [void]$qemuArgs.Add('-display')
    [void]$qemuArgs.Add('gtk,show-cursor=on')
    [void]$qemuArgs.Add('-drive')
    [void]$qemuArgs.Add('if=pflash,format=raw,readonly=on,file=' + $CodePath)
    [void]$qemuArgs.Add('-drive')
    [void]$qemuArgs.Add('if=pflash,format=raw,file=' + $VarsPath)
    [void]$qemuArgs.Add('-device')
    [void]$qemuArgs.Add('ich9-ahci,id=ahci')
    for ($index = 0; $index -lt $ImagePaths.Count; $index++) {
        $id = 'disk' + $index
        $bootIndex = if ($index -eq 0) { ',bootindex=1' } else { '' }
        [void]$qemuArgs.Add('-drive')
        [void]$qemuArgs.Add('if=none,id=' + $id + ',format=raw,file=' + $ImagePaths[$index])
        [void]$qemuArgs.Add('-device')
        [void]$qemuArgs.Add('ide-hd,drive=' + $id + ',bus=ahci.' + $index + $bootIndex)
    }
    $quoted = foreach ($part in $qemuArgs) { ConvertTo-WindowsArgument -Text $part }
    return ($quoted -join ' ')
}

function Start-QemuSession {
    param(
        [string]$QemuPath,
        [string]$ArgumentLine,
        [string]$StdoutPath,
        [string]$StderrPath
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $QemuPath
    $startInfo.Arguments = $ArgumentLine
    $startInfo.WorkingDirectory = $testRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $false
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $startInfo
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $exited = $proc.WaitForExit(5000)
    if ($exited) {
        $stdoutText = $stdoutTask.Result
        $stderrText = $stderrTask.Result
        [IO.File]::WriteAllText($StdoutPath, [string]$stdoutText)
        [IO.File]::WriteAllText($StderrPath, [string]$stderrText)
        return @{ Ok = ($proc.ExitCode -eq 0); ExitCode = $proc.ExitCode; Stderr = [string]$stderrText; Process = $proc; Running = $false }
    }
    return @{ Ok = $true; ExitCode = $null; Stderr = ''; Process = $proc; Running = $true; StdoutTask = $stdoutTask; StderrTask = $stderrTask; StdoutPath = $StdoutPath; StderrPath = $StderrPath }
}

try {
    Assert-QemuCommandSafe -CommandText 'qemu \\.\PhysicalDrive0 /dev/nvme0n1 \\?\Volume{test}' -ImagePaths @()
    throw 'Le contrôle de sécurité aurait dû refuser la commande.'
} catch {
    if ($_.Exception.Message -notmatch 'PhysicalDrive') { throw }
    Write-BootStep 'OK' 'aucune référence PhysicalDrive'
}
Write-BootStep 'OK' 'aucun disque physique touché'
Write-BootStep 'INFO' ("Dépôt : " + $projectRoot)
Write-BootStep 'INFO' ("Accélérateur demandé : " + $Accel)
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
}
Write-BootStep 'OK' '5 images virtuelles'

$varsCopy = Join-Path $logDirectory 'OVMF_VARS.temp.fd'
if (Test-Path -LiteralPath $varsCopy) {
    Write-BootStep 'WARN' ("Remplacement de la copie OVMF_VARS : " + $varsCopy)
    Remove-Item -LiteralPath $varsCopy -Force
}
Copy-Item -LiteralPath $tools.OvmfVars -Destination $varsCopy -Force

$attempts = if ($Accel -eq 'auto') { @('whpx', 'tcg') } else { @($Accel) }
$session = $null
$selectedAccel = $null
foreach ($candidate in $attempts) {
    if (Test-Path -LiteralPath $varsCopy) { Remove-Item -LiteralPath $varsCopy -Force }
    Copy-Item -LiteralPath $tools.OvmfVars -Destination $varsCopy -Force
    $argumentLine = Get-QemuArgumentLine -SelectedAccel $candidate -CodePath $tools.OvmfCode -VarsPath $varsCopy -ImagePaths $images
    $commandText = $tools.Qemu + ' ' + $argumentLine
    Assert-QemuCommandSafe -CommandText $commandText -ImagePaths $images
    $stdoutPath = Join-Path $logDirectory ('qemu-{0}-stdout.log' -f $candidate)
    $stderrPath = Join-Path $logDirectory ('qemu-{0}-stderr.log' -f $candidate)
    Write-BootStep 'INFO' ("Commande QEMU : " + $commandText)
    $session = Start-QemuSession -QemuPath $tools.Qemu -ArgumentLine $argumentLine -StdoutPath $stdoutPath -StderrPath $stderrPath
    if ($session.Ok) {
        $selectedAccel = $candidate
        break
    }
    Write-BootStep 'ERROR' ("QEMU {0} s'est arrêté, code {1}." -f $candidate, $session.ExitCode)
    Write-BootStep 'ERROR' ("stderr : " + $stderrPath)
    if ($session.Stderr) { Write-Host $session.Stderr }
    if ($Accel -eq 'auto' -and $candidate -eq 'whpx') {
        Write-BootStep 'WARN' 'Le lancement WHPX a échoué. Repli sur TCG.'
    }
}
if (-not $session -or -not $session.Ok) { exit 1 }
if ($selectedAccel -eq 'tcg') { Write-BootStep 'OK' 'accélérateur TCG' } else { Write-BootStep 'OK' 'accélérateur WHPX' }
Write-BootStep 'INFO' 'Contrôleur ich9-ahci. Les chargeurs des volumes simulés sont des stubs de test.'
if ($session.Running) {
    $session.Process.WaitForExit()
    $stdoutText = $session.StdoutTask.Result
    $stderrText = $session.StderrTask.Result
    [IO.File]::WriteAllText($session.StdoutPath, [string]$stdoutText)
    [IO.File]::WriteAllText($session.StderrPath, [string]$stderrText)
    if ($session.Process.ExitCode -ne 0) {
        Write-BootStep 'ERROR' ("QEMU terminé, code " + $session.Process.ExitCode)
        if ($stderrText) { Write-Host $stderrText }
        exit $session.Process.ExitCode
    }
}
Write-BootStep 'OK' 'QEMU terminé'
exit 0
