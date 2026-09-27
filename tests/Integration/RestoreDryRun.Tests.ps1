Describe 'Restore-RestorBootManager dry-run' {
    BeforeAll {
    $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:RestoreScript = Join-Path $script:RepoRoot 'scripts\Restore-RestorBootManager.ps1'
    Import-Module (Join-Path $script:RepoRoot 'scripts\lib\RestorPc.Common.psm1') -Force
    . (Join-Path $PSScriptRoot '..\Helpers\TestFixture.ps1')

    function script:New-RestorFakeDisk {
        param(
            [string]$Style = 'GPT',
            [string]$Bus = 'NVMe',
            [int]$Number = 99,
            [string]$Model = 'RESTOR-PC TEST NVME',
            [string]$Serial = 'TEST_SERIAL_0001'
        )
        [pscustomobject]@{
            FriendlyName   = $Model
            SerialNumber   = $Serial
            PartitionStyle = $Style
            BusType        = $Bus
            Number         = $Number
        }
    }

    function script:Enable-RestorHardwareGuard {
        foreach ($commandName in @(
            'Get-Disk', 'Get-Partition', 'Get-Volume', 'Get-CimInstance',
            'Add-PartitionAccessPath', 'Remove-PartitionAccessPath',
            'Clear-Disk', 'Initialize-Disk', 'Remove-Partition', 'Resize-Partition',
            'New-Partition', 'Format-Volume', 'diskpart', 'diskpart.exe',
            'bcdboot', 'bcdboot.exe', 'bootrec', 'bootrec.exe', 'bcdedit', 'bcdedit.exe',
            'robocopy', 'robocopy.exe'
        )) {
            if (Get-Command -Name $commandName -ErrorAction SilentlyContinue) {
                Mock $commandName { throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
            }
        }
        Mock New-Item -ParameterFilter {
            $joined = @($Path) -join ' '
            $joined -like '*PRE-RESTORE*' -or $joined -like '*RESTOR-PC-BACKUP*'
        } -MockWith { throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
    }

    function script:Set-RestorFakeDiskResult {
        param([object[]]$Disk)
        $items = New-Object System.Collections.ArrayList
        foreach ($item in @($Disk)) {
            if ($null -ne $item) { [void]$items.Add($item) }
        }
        $global:RestorFakeDiskResult = $items.ToArray()
        Mock Get-Disk {
            if ($global:RestorFakeDiskResult.Length -eq 0) { return }
            , $global:RestorFakeDiskResult
        }
    }

    function script:Assert-RestorNoWrite {
        Assert-MockCalled -CommandName Add-PartitionAccessPath -Times 0 -Scope It
        Assert-MockCalled -CommandName Remove-PartitionAccessPath -Times 0 -Scope It
        Assert-MockCalled -CommandName robocopy.exe -Times 0 -Scope It
        Assert-MockCalled -CommandName Get-Partition -Times 0 -Scope It
        Assert-MockCalled -CommandName Get-Volume -Times 0 -Scope It
    }

    function script:Invoke-DryRestore {
        param([hashtable]$Extra = @{})
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -RepoRoot $script:RepoRoot
        $parameter = @{
            BackupPath     = $root
            ExpectedModel  = 'RESTOR-PC TEST NVME'
            ExpectedSerial = 'TEST_SERIAL_0001'
        }
        foreach ($key in $Extra.Keys) { $parameter[$key] = $Extra[$key] }
        return Invoke-RestorChecked -Path $script:RestoreScript -Parameter $parameter
    }
    }

    BeforeEach {
        Enable-RestorHardwareGuard
        Set-RestorFakeDiskResult -Disk (New-RestorFakeDisk)
    }

    It 'reste en dry-run sans Apply et n ecrit rien' {
        $result = Invoke-DryRestore -Extra @{ RestorBoot = $true }
        $result.Code | Should -Be 0
        $result.Error | Should -Be ''
        ($result.Output -join "`n") | Should -Match 'Aucune ecriture effectuee|Aucune écriture effectuée'
        ($result.Output -join "`n") | Should -Match 'Dry-run RESTOR-BOOT'
        ($result.Output -join "`n") | Should -Not -Match 'Dry-run CODE-EFI'
        Assert-RestorNoWrite
    }

    It 'n ecrit pas quand Apply est seul' {
        $result = Invoke-DryRestore -Extra @{ RestorBoot = $true; Apply = $true }
        $result.Code | Should -Be 0
        ($result.Output -join "`n") | Should -Match 'Confirmation refusee|Confirmation refusée'
        ($result.Output -join "`n") | Should -Match 'Aucune ecriture effectuee|Aucune écriture effectuée'
        Assert-RestorNoWrite
    }

    It 'n ecrit pas quand la confirmation est seule' {
        $result = Invoke-DryRestore -Extra @{ RestorBoot = $true; ConfirmRestore = 'RESTOR-PC' }
        $result.Code | Should -Be 0
        ($result.Output -join "`n") | Should -Not -Match 'Confirmation refusee|Confirmation refusée'
        ($result.Output -join "`n") | Should -Match 'Aucune ecriture effectuee|Aucune écriture effectuée'
        Assert-RestorNoWrite
    }

    It 'refuse la confirmation inexacte <Phrase>' -TestCases @(
        @{ Phrase = 'RESTOR' }
        @{ Phrase = 'YES' }
        @{ Phrase = 'restor-pc' }
    ) {
        param($Phrase)
        $result = Invoke-DryRestore -Extra @{ RestorBoot = $true; Apply = $true; ConfirmRestore = $Phrase }
        $result.Code | Should -Be 0
        ($result.Output -join "`n") | Should -Match 'Confirmation refusee|Confirmation refusée'
        Assert-RestorNoWrite
    }

    It 'decrit seulement RESTOR-BOOT pour le commutateur RestorBoot' {
        $result = Invoke-DryRestore -Extra @{ RestorBoot = $true }
        @($result.Output | Where-Object { $_ -like '*Dry-run RESTOR-BOOT*' }).Count | Should -Be 1
        @($result.Output | Where-Object { $_ -like '*Dry-run CODE-EFI*' }).Count | Should -Be 0
    }

    It 'decrit les cinq cibles une seule fois avec AllEfi et RestorBoot' {
        $result = Invoke-DryRestore -Extra @{ AllEfi = $true; RestorBoot = $true }
        foreach ($name in @('RESTOR-BOOT', 'CODE-EFI', 'VESTY-EFI', 'RESCUE-EFI', 'LOCKPICK-EFI')) {
            @($result.Output | Where-Object { $_ -like ('*Dry-run ' + $name + '*') }).Count | Should -Be 1
        }
        Assert-RestorNoWrite
    }

    It 'refuse Apply sur un backup WARNING avant toute ecriture' {
        Mock Get-Disk { throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'warn-apply') -RepoRoot $script:RepoRoot
        Set-RestorTestBackupStatus -Root $root -Status 'WARNING'
        $result = Invoke-RestorChecked -Path $script:RestoreScript -Parameter @{
            BackupPath      = $root
            RestorBoot      = $true
            Apply           = $true
            ConfirmRestore  = 'RESTOR-PC'
            ExpectedModel   = 'RESTOR-PC TEST NVME'
            ExpectedSerial  = 'TEST_SERIAL_0001'
        }
        $result.Error | Should -Match "n'est pas VALID"
        $result.Error | Should -Not -Match 'REAL HARDWARE'
        Assert-MockCalled -CommandName Get-Disk -Times 0 -Scope It
        Assert-RestorNoWrite
    }

    It 'refuse Apply quand le manifeste est corrompu' {
        Mock Get-Disk { throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'bad-manifest') -RepoRoot $script:RepoRoot
        [IO.File]::AppendAllText((Join-Path $root 'Manifests\SHA256-MANIFEST.txt'), 'BROKEN', (Get-RestorUtf8))
        $result = Invoke-RestorChecked -Path $script:RestoreScript -Parameter @{
            BackupPath      = $root
            RestorBoot      = $true
            Apply           = $true
            ConfirmRestore  = 'RESTOR-PC'
            ExpectedModel   = 'RESTOR-PC TEST NVME'
            ExpectedSerial  = 'TEST_SERIAL_0001'
        }
        $result.Error | Should -Match 'ManifestSha256'
        $result.Error | Should -Not -Match 'REAL HARDWARE'
        Assert-MockCalled -CommandName Get-Disk -Times 0 -Scope It
        Assert-RestorNoWrite
    }

    It 'refuse un NVMe introuvable' {
        Set-RestorFakeDiskResult -Disk @()
        $result = Invoke-DryRestore -Extra @{ RestorBoot = $true }
        $result.Error | Should -Match 'introuvable ou ambigu'
        Assert-RestorNoWrite
    }

    It 'refuse deux NVMe identiques' {
        Set-RestorFakeDiskResult -Disk @(
            (New-RestorFakeDisk -Number 99),
            (New-RestorFakeDisk -Number 100)
        )
        $result = Invoke-DryRestore -Extra @{ RestorBoot = $true }
        $result.Error | Should -Match 'introuvable ou ambigu'
        Assert-RestorNoWrite
    }

    It 'refuse un disque MBR' {
        Set-RestorFakeDiskResult -Disk (New-RestorFakeDisk -Style 'MBR')
        $result = Invoke-DryRestore -Extra @{ RestorBoot = $true }
        $result.Error | Should -Match "n'est pas GPT"
        Assert-RestorNoWrite
    }

    It 'refuse un bus SATA' {
        Set-RestorFakeDiskResult -Disk (New-RestorFakeDisk -Bus 'SATA')
        $result = Invoke-DryRestore -Extra @{ RestorBoot = $true }
        $result.Error | Should -Match "n'est pas NVMe"
        Assert-RestorNoWrite
    }
}
