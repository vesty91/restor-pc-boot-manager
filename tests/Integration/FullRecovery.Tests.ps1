BeforeAll {
    $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:RecoveryScript = Join-Path $script:RepoRoot 'scripts\New-RestorRecoveryDisk.ps1'
    $script:LabRoot = Join-Path $script:RepoRoot 'test\vhd\full-recovery-lab'
    $script:ReportPath = Join-Path $script:LabRoot 'RECOVERY-RESULT.json'
    Import-Module (Join-Path $script:RepoRoot 'scripts\lib\RestorPc.Common.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'scripts\lib\RestorPc.Backup.psm1') -Force
    . (Join-Path $PSScriptRoot '..\Helpers\TestFixture.ps1')
}

Describe 'New-RestorRecoveryDisk offline guards' {
    BeforeEach {
        $global:InitCalls = 0
        $global:NewPartitionCalls = 0
        $global:FormatCalls = 0
        Mock Test-RestorAdministrator { }
        Mock Initialize-Disk { $global:InitCalls++ }
        Mock New-Partition {
            $global:NewPartitionCalls++
            throw 'UNEXPECTED New-Partition'
        }
        Mock Format-Volume {
            $global:FormatCalls++
            throw 'UNEXPECTED Format-Volume'
        }
    }

    It 'reste en dry-run sans Apply' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'dry-no-apply') -RepoRoot $script:RepoRoot
        Mock Get-Disk {
            [pscustomobject]@{
                FriendlyName   = 'RESTOR-PC TEST NVME'
                SerialNumber   = 'TEST_SERIAL_0001'
                PartitionStyle = 'RAW'
                Number         = 42
                IsBoot         = $false
                IsSystem       = $false
                Size           = [int64]80GB
                LargestFreeExtent = [int64]80GB
            }
        }
        Mock Get-Partition { @() }
        $result = Invoke-RestorChecked -Path $script:RecoveryScript -Parameter @{
            DiskNumber      = 42
            BackupPath      = $root
            ExpectedModel   = 'RESTOR-PC TEST NVME'
            ExpectedSerial  = 'TEST_SERIAL_0001'
            ConfirmRebuild  = 'REBUILD-RESTOR-PC'
        }
        $result.Code | Should -Be 0
        $global:InitCalls | Should -Be 0
        $global:NewPartitionCalls | Should -Be 0
        ($result.Output -join "`n") | Should -Match 'simulation|Dry-run'
    }

    It 'refuse un EmptyGpt dont l espace libre est insuffisant' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'tiny-free') -RepoRoot $script:RepoRoot
        Mock Get-Disk {
            [pscustomobject]@{
                FriendlyName      = 'RESTOR-PC TEST NVME'
                SerialNumber      = 'TEST_SERIAL_0001'
                PartitionStyle    = 'GPT'
                Number            = 42
                IsBoot            = $false
                IsSystem          = $false
                Size              = [int64]80GB
                LargestFreeExtent = [int64]10GB
            }
        }
        Mock Get-Partition {
            @(
                [pscustomobject]@{
                    PartitionNumber = 1
                    Type            = 'Reserved'
                    Size            = [int64]16MB
                    GptType         = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
                    DriveLetter     = ''
                }
            )
        }
        $result = Invoke-RestorChecked -Path $script:RecoveryScript -Parameter @{
            DiskNumber      = 42
            BackupPath      = $root
            ExpectedModel   = 'RESTOR-PC TEST NVME'
            ExpectedSerial  = 'TEST_SERIAL_0001'
            Apply           = $true
            ConfirmRebuild  = 'REBUILD-RESTOR-PC'
        }
        $result.Code | Should -Be 1
        $result.Error | Should -Match 'Espace libre insuffisant'
        $global:InitCalls | Should -Be 0
    }

    It 'refuse une confirmation incorrecte sans modifier le disque' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'bad-confirm') -RepoRoot $script:RepoRoot
        Mock Get-Disk {
            [pscustomobject]@{
                FriendlyName   = 'RESTOR-PC TEST NVME'
                SerialNumber   = 'TEST_SERIAL_0001'
                PartitionStyle = 'RAW'
                Number         = 42
                IsBoot         = $false
                IsSystem       = $false
                Size           = [int64]80GB
                LargestFreeExtent = [int64]80GB
            }
        }
        Mock Get-Partition { @() }
        $result = Invoke-RestorChecked -Path $script:RecoveryScript -Parameter @{
            DiskNumber      = 42
            BackupPath      = $root
            ExpectedModel   = 'RESTOR-PC TEST NVME'
            ExpectedSerial  = 'TEST_SERIAL_0001'
            Apply           = $true
            ConfirmRebuild  = 'rebuild-restor-pc'
        }
        $result.Code | Should -Be 0
        $global:InitCalls | Should -Be 0
        ($result.Output -join "`n") | Should -Match 'Confirmation refusee|REBUILD-RESTOR-PC'
    }

    It 'refuse un disque deja partitionne' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'partitioned') -RepoRoot $script:RepoRoot
        Mock Get-Disk {
            [pscustomobject]@{
                FriendlyName   = 'RESTOR-PC TEST NVME'
                SerialNumber   = 'TEST_SERIAL_0001'
                PartitionStyle = 'GPT'
                Number         = 42
                IsBoot         = $false
                IsSystem       = $false
            }
        }
        Mock Get-Partition {
            [pscustomobject]@{ Type = 'Basic'; PartitionNumber = 1; Size = 1GB; GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' }
        }
        $result = Invoke-RestorChecked -Path $script:RecoveryScript -Parameter @{
            DiskNumber      = 42
            BackupPath      = $root
            ExpectedModel   = 'RESTOR-PC TEST NVME'
            ExpectedSerial  = 'TEST_SERIAL_0001'
            Apply           = $true
            ConfirmRebuild  = 'REBUILD-RESTOR-PC'
        }
        $result.Code | Should -Be 1
        $result.Error | Should -Match 'deja partitionne'
        $global:InitCalls | Should -Be 0
    }

    It 'refuse un backup corrompu avant Initialize-Disk' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'corrupt') -RepoRoot $script:RepoRoot
        Set-Content -LiteralPath (Join-Path $root 'ESP\CODE-EFI\EFI\Microsoft\Boot\bootmgfw.efi') -Value 'CORRUPT' -Encoding ascii
        Mock Get-Disk { throw 'Get-Disk ne doit pas etre appele si le backup est invalide' }
        $result = Invoke-RestorChecked -Path $script:RecoveryScript -Parameter @{
            DiskNumber      = 42
            BackupPath      = $root
            ExpectedModel   = 'RESTOR-PC TEST NVME'
            ExpectedSerial  = 'TEST_SERIAL_0001'
            Apply           = $true
            ConfirmRebuild  = 'REBUILD-RESTOR-PC'
        }
        $result.Code | Should -Be 1
        $result.Error | Should -Match 'Golden Backup invalid|integrity'
        $global:InitCalls | Should -Be 0
    }

    It 'refuse IsBoot true' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'boot') -RepoRoot $script:RepoRoot
        Mock Get-Disk {
            [pscustomobject]@{
                FriendlyName   = 'RESTOR-PC TEST NVME'
                SerialNumber   = 'TEST_SERIAL_0001'
                PartitionStyle = 'RAW'
                Number         = 42
                IsBoot         = $true
                IsSystem       = $false
            }
        }
        Mock Get-Partition { @() }
        $result = Invoke-RestorChecked -Path $script:RecoveryScript -Parameter @{
            DiskNumber      = 42
            BackupPath      = $root
            ExpectedModel   = 'RESTOR-PC TEST NVME'
            ExpectedSerial  = 'TEST_SERIAL_0001'
            Apply           = $true
            ConfirmRebuild  = 'REBUILD-RESTOR-PC'
        }
        $result.Code | Should -Be 1
        $result.Error | Should -Match 'demarrage'
        $global:InitCalls | Should -Be 0
    }

    It 'refuse IsSystem true' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'system') -RepoRoot $script:RepoRoot
        Mock Get-Disk {
            [pscustomobject]@{
                FriendlyName   = 'RESTOR-PC TEST NVME'
                SerialNumber   = 'TEST_SERIAL_0001'
                PartitionStyle = 'RAW'
                Number         = 42
                IsBoot         = $false
                IsSystem       = $true
            }
        }
        Mock Get-Partition { @() }
        $result = Invoke-RestorChecked -Path $script:RecoveryScript -Parameter @{
            DiskNumber      = 42
            BackupPath      = $root
            ExpectedModel   = 'RESTOR-PC TEST NVME'
            ExpectedSerial  = 'TEST_SERIAL_0001'
            Apply           = $true
            ConfirmRebuild  = 'REBUILD-RESTOR-PC'
        }
        $result.Code | Should -Be 1
        $result.Error | Should -Match 'systeme'
        $global:InitCalls | Should -Be 0
    }

    It 'refuse un mauvais modele ou serie' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'identity') -RepoRoot $script:RepoRoot
        Mock Get-Disk {
            [pscustomobject]@{
                FriendlyName   = 'OTHER DISK'
                SerialNumber   = 'WRONG'
                PartitionStyle = 'RAW'
                Number         = 42
                IsBoot         = $false
                IsSystem       = $false
            }
        }
        Mock Get-Partition { @() }
        $result = Invoke-RestorChecked -Path $script:RecoveryScript -Parameter @{
            DiskNumber      = 42
            BackupPath      = $root
            ExpectedModel   = 'RESTOR-PC TEST NVME'
            ExpectedSerial  = 'TEST_SERIAL_0001'
            Apply           = $true
            ConfirmRebuild  = 'REBUILD-RESTOR-PC'
        }
        $result.Code | Should -Be 1
        $result.Error | Should -Match 'Modele inattendu|Numero de serie'
        $global:InitCalls | Should -Be 0
    }
}

Describe 'New-RestorRecoveryDisk offline apply on blank RAW mock' {
    It 'execute Initialize-Disk puis New-Partition apres confirmation valide' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'apply-raw') -RepoRoot $script:RepoRoot
        $report = Join-Path $TestDrive 'RECOVERY-RESULT.json'
        $global:InitCalls = 0
        $global:NewPartitionCalls = 0
        $global:FormatCalls = 0
        Mock Start-Sleep { }
        Mock Test-RestorAdministrator { }
        Mock Get-Disk {
            [pscustomobject]@{
                FriendlyName      = 'RESTOR-PC TEST NVME'
                SerialNumber      = 'TEST_SERIAL_0001'
                PartitionStyle    = 'RAW'
                Number            = 42
                IsBoot            = $false
                IsSystem          = $false
                Size              = [int64]80GB
                LargestFreeExtent = [int64]10GB
            }
        }
        Mock Get-Partition {
            if ($global:InitCalls -gt 0) {
                return @(
                    [pscustomobject]@{
                        PartitionNumber = 1
                        Type            = 'Reserved'
                        Size            = [int64]16MB
                        GptType         = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
                        DriveLetter     = ''
                    }
                )
            }
            return @()
        }
        Mock Initialize-Disk { $global:InitCalls++ }
        Mock New-Partition {
            $global:NewPartitionCalls++
            throw 'STOP-AFTER-PARTITION-START'
        }
        Mock Format-Volume { $global:FormatCalls++ }

        $result = Invoke-RestorChecked -Path $script:RecoveryScript -Parameter @{
            DiskNumber      = 42
            BackupPath      = $root
            ExpectedModel   = 'RESTOR-PC TEST NVME'
            ExpectedSerial  = 'TEST_SERIAL_0001'
            Apply           = $true
            ConfirmRebuild  = 'REBUILD-RESTOR-PC'
            ResultPath      = $report
        }
        $global:InitCalls | Should -Be 1
        $global:NewPartitionCalls | Should -Be 1
        $result.Error | Should -Match 'STOP-AFTER-PARTITION-START'
        Test-Path -LiteralPath $report | Should -BeTrue
        $payload = Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
        $payload.Status | Should -Be 'FAILED'
        $payload.Error | Should -Match 'STOP-AFTER-PARTITION-START'
    }
}

Describe 'Full recovery VHD lab assertions' -Tag VHD {
    It 'prouve le layout reconstruit et le rapport VALID' {
        Test-Path -LiteralPath $script:ReportPath | Should -BeTrue
        $report = Get-Content -LiteralPath $script:ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.Status | Should -Be 'VALID'
        $report.FilesVerified | Should -BeGreaterThan 0
        @($report.HashMismatches).Count | Should -Be 0
        $vhdPath = Join-Path $script:LabRoot 'restor-full-recovery.vhdx'
        Test-Path -LiteralPath $vhdPath | Should -BeTrue
        $disk = Get-DiskImage -ImagePath $vhdPath | Get-Disk
        [bool]$disk.IsBoot | Should -BeFalse
        [bool]$disk.IsSystem | Should -BeFalse
        [string]$disk.FriendlyName | Should -Not -Be 'SAMSUNG MZVLB256HAHQ-000L2'
        $parts = @(Get-Partition -DiskNumber $disk.Number)
        $parts.Count | Should -BeGreaterOrEqual 7
        $byLabel = @{}
        foreach ($partition in $parts) {
            $letter = [string]$partition.DriveLetter
            if ($letter -match '^[A-Za-z]$') {
                $label = ([string](Get-Volume -DriveLetter $letter).FileSystemLabel).Trim()
                $byLabel[$label] = $letter
            }
        }
        foreach ($label in @('RESTOR-BOOT', 'CODE-EFI', 'VESTY-EFI', 'RESCUE-EFI', 'LOCKPICK-EF', 'RESTOR-TOOLS')) {
            $byLabel.ContainsKey($label) | Should -BeTrue
        }
        $snapshot = Get-RestorManifestSnapshot -BackupPath (Join-Path $script:LabRoot 'golden')
        foreach ($pair in @{
            'RESTOR-BOOT' = 'RESTOR-BOOT'
            'CODE-EFI'    = 'CODE-EFI'
            'VESTY-EFI'   = 'VESTY-EFI'
            'RESCUE-EFI'  = 'RESCUE-EFI'
            'LOCKPICK-EFI'= 'LOCKPICK-EF'
        }.GetEnumerator()) {
            $check = Test-RestorRestoredTarget -TargetName $pair.Key -DestinationRoot ($byLabel[$pair.Value] + ':\') -ManifestSnapshot $snapshot
            $check.Valid | Should -BeTrue
        }
        [int64]$disk.LargestFreeExtent | Should -BeGreaterThan 0
        Test-Path -LiteralPath (Join-Path ($byLabel['RESTOR-TOOLS'] + ':\') 'WinPE\RescueGrid\boot.wim') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path ($byLabel['RESTOR-TOOLS'] + ':\') 'WinPE\RescueGrid\boot.sdi') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path ($byLabel['RESTOR-TOOLS'] + ':\') 'RescueGrid\WinPE\boot.wim') | Should -BeFalse
    }
}
