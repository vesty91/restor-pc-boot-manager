BeforeAll {
    $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:RestoreScript = Join-Path $script:RepoRoot 'scripts\Restore-RestorBootManager.ps1'
    Import-Module (Join-Path $script:RepoRoot 'scripts\lib\RestorPc.Common.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'scripts\lib\RestorPc.Backup.psm1') -Force
    . (Join-Path $PSScriptRoot '..\Helpers\TestFixture.ps1')

    function script:New-RestorIntegrityDisk {
        [pscustomobject]@{
            FriendlyName   = 'RESTOR-PC TEST NVME'
            SerialNumber   = 'TEST_SERIAL_0001'
            PartitionStyle = 'GPT'
            BusType        = 'NVMe'
            Number         = 99
        }
    }

    function script:Enable-RestorIntegrityBlock {
        $global:IntegrityDiskCalls = 0
        $global:IntegrityPartitionCalls = 0
        $global:IntegrityVolumeCalls = 0
        $global:IntegrityMountCalls = 0
        $global:IntegrityCopyCalls = 0
        $global:IntegrityAdminCalls = 0
        Mock Get-Disk { $global:IntegrityDiskCalls++; throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
        Mock Get-Partition { $global:IntegrityPartitionCalls++; throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
        Mock Get-Volume { $global:IntegrityVolumeCalls++; throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
        Mock Add-PartitionAccessPath { $global:IntegrityMountCalls++; throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
        Mock robocopy.exe { $global:IntegrityCopyCalls++; throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
        Mock Test-RestorAdministrator { $global:IntegrityAdminCalls++; throw 'ADMIN CHECK RAN' }
    }

    function script:Enable-RestorIntegrityApply {
        Mock Test-RestorAdministrator { }
        Mock Get-Disk { New-RestorIntegrityDisk }
        Mock Get-Partition {
            [pscustomobject]@{
                DiskNumber      = 99
                PartitionNumber = 2
                DriveLetter     = $global:IntegrityLetter
                Size            = 500MB
                GptType         = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
                Type            = 'Basic'
            }
        }
        Mock Get-Volume {
            [pscustomobject]@{
                DriveLetter     = $global:IntegrityLetter
                FileSystem      = 'FAT32'
                FileSystemLabel = 'CODE-EFI'
            }
        }
        Mock Add-PartitionAccessPath { throw 'UNEXPECTED PARTITION MOUNT' }
        Mock Remove-PartitionAccessPath { throw 'UNEXPECTED PARTITION REMOVE' }
    }

    function script:Mount-RestorFakeDestination {
        foreach ($name in @('Y', 'X', 'V', 'U', 'P', 'N')) {
            $namedDrive = Get-PSDrive -Name $name -ErrorAction SilentlyContinue
            if ($namedDrive) { continue }
            if (Test-Path -LiteralPath ($name + ':\')) { continue }
            $folder = Join-Path $TestDrive ('dest-' + $name)
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            New-PSDrive -Name $name -PSProvider FileSystem -Root $folder -Scope Global | Out-Null
            $global:IntegrityLetter = $name
            return $folder
        }
        throw 'Aucune lettre libre pour la destination de test.'
    }

    function script:Copy-RestorGoldenPayload {
        param([string]$Source, [string]$Destination)
        if (-not (Test-Path -LiteralPath $Destination)) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
    }

    function script:Invoke-IntegrityApply {
        param(
            [Parameter(Mandatory)][string]$Root,
            [switch]$CodeEfi
        )
        return Invoke-RestorChecked -Path $script:RestoreScript -Parameter @{
            BackupPath      = $Root
            CodeEfi         = [bool]$CodeEfi
            Apply           = $true
            ConfirmRestore  = 'RESTOR-PC'
            ExpectedModel   = 'RESTOR-PC TEST NVME'
            ExpectedSerial  = 'TEST_SERIAL_0001'
            PreRestoreRoot  = (Join-Path $TestDrive 'pre-root')
        }
    }
}

Describe 'Restore apply integrity gate' {
    It 'refuse un payload corrompu avant Get-Disk' {
        Enable-RestorIntegrityBlock
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'apply-corrupt') -RepoRoot $script:RepoRoot
        [IO.File]::WriteAllText((Join-Path $root 'ESP\CODE-EFI\EFI\Microsoft\Boot\bootmgfw.efi'), 'CORRUPTED', (Get-RestorUtf8))
        $result = Invoke-IntegrityApply -Root $root -CodeEfi
        $result.Error | Should -Match 'integrity verification failed'
        $result.Error | Should -Match 'Fichier modifi'
        $result.Error | Should -Not -Match 'REAL HARDWARE'
        $global:IntegrityDiskCalls | Should -Be 0
        $global:IntegrityPartitionCalls | Should -Be 0
        $global:IntegrityVolumeCalls | Should -Be 0
        $global:IntegrityMountCalls | Should -Be 0
        $global:IntegrityCopyCalls | Should -Be 0
        $global:IntegrityAdminCalls | Should -Be 0
    }

    It 'refuse un fichier manifeste absent avant Get-Disk' {
        Enable-RestorIntegrityBlock
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'apply-missing') -RepoRoot $script:RepoRoot
        Remove-Item -LiteralPath (Join-Path $root 'ESP\CODE-EFI\EFI\Microsoft\Boot\bootmgfw.efi') -Force
        $result = Invoke-IntegrityApply -Root $root -CodeEfi
        $result.Error | Should -Match 'Fichier absent'
        $global:IntegrityDiskCalls | Should -Be 0
        $global:IntegrityCopyCalls | Should -Be 0
        $global:IntegrityAdminCalls | Should -Be 0
    }

    It 'refuse un fichier hors manifeste avant Get-Disk' {
        Enable-RestorIntegrityBlock
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'apply-extra') -RepoRoot $script:RepoRoot
        Write-RestorTextFile -Path (Join-Path $root 'ESP\RESTOR-BOOT\UNEXPECTED.BIN') -Content 'EXTRA'
        $result = Invoke-IntegrityApply -Root $root -CodeEfi
        $result.Error | Should -Match 'Fichier hors manifeste'
        $global:IntegrityDiskCalls | Should -Be 0
        $global:IntegrityCopyCalls | Should -Be 0
    }

    It 'laisse passer un backup valide jusqu a la copie simulee' {
        $folder = Mount-RestorFakeDestination
        Enable-RestorIntegrityApply
        $global:PreCopies = 0
        $global:GoldenCopies = 0
        Mock robocopy.exe {
            $source = [string]$args[0]
            $destination = [string]$args[1]
            if ($destination -like '*PRE-RESTORE*') {
                $global:PreCopies++
                $global:LASTEXITCODE = 0
                return
            }
            $global:GoldenCopies++
            Copy-RestorGoldenPayload -Source $source -Destination $destination
            $global:LASTEXITCODE = 0
        }
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'apply-valid') -RepoRoot $script:RepoRoot
        $result = Invoke-IntegrityApply -Root $root -CodeEfi
        $result.Code | Should -Be 0
        $result.Error | Should -Be ''
        ($result.Output -join "`n") | Should -Match 'Golden Backup integrity verified:'
        ($result.Output -join "`n") | Should -Match 'Golden Backup integrity unchanged'
        ($result.Output -join "`n") | Should -Match 'Post-restore verification valid:'
        $global:PreCopies | Should -Be 1
        $global:GoldenCopies | Should -Be 1
        $reportFile = Get-ChildItem -Path (Join-Path $TestDrive 'pre-root') -Recurse -Filter 'RESTORE-RESULT.json' | Select-Object -First 1
        $report = Get-Content -LiteralPath $reportFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.Status | Should -Be 'VALID'
        Remove-PSDrive -Name $global:IntegrityLetter -Force
        $folder | Should -Not -BeNullOrEmpty
    }

    It 'arrete la copie Golden si le backup change apres PRE-RESTORE' {
        Enable-RestorIntegrityApply
        $global:PreCopies = 0
        $global:GoldenCopies = 0
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'apply-second') -RepoRoot $script:RepoRoot
        $global:IntegrityRoot = $root
        Mock robocopy.exe {
            $destination = [string]$args[1]
            if ($destination -like '*PRE-RESTORE*') {
                $global:PreCopies++
                $payload = Join-Path $global:IntegrityRoot 'ESP\CODE-EFI\EFI\Microsoft\Boot\bootmgfw.efi'
                [IO.File]::WriteAllText($payload, 'MUTATED BETWEEN GATES', (New-Object System.Text.UTF8Encoding $false))
                $global:LASTEXITCODE = 0
                return
            }
            $global:GoldenCopies++
            $global:LASTEXITCODE = 0
        }
        $result = Invoke-IntegrityApply -Root $root -CodeEfi
        $result.Error | Should -Match 'Golden Backup integrity changed before restore copy'
        $global:PreCopies | Should -Be 1
        $global:GoldenCopies | Should -Be 0
    }

    It 'refuse un backup remplace par un autre ensemble encore coherent' {
        Enable-RestorIntegrityApply
        $global:PreCopies = 0
        $global:GoldenCopies = 0
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'apply-swapped') -RepoRoot $script:RepoRoot
        $global:IntegrityRoot = $root
        Mock robocopy.exe {
            $destination = [string]$args[1]
            if ($destination -like '*PRE-RESTORE*') {
                $global:PreCopies++
                $payload = Join-Path $global:IntegrityRoot 'ESP\CODE-EFI\EFI\Microsoft\Boot\bootmgfw.efi'
                [IO.File]::WriteAllText($payload, 'DIFFERENT CONSISTENT BACKUP', (New-Object System.Text.UTF8Encoding $false))
                Update-RestorTestManifest -Root $global:IntegrityRoot -Status 'VALID'
                $global:LASTEXITCODE = 0
                return
            }
            $global:GoldenCopies++
            $global:LASTEXITCODE = 0
        }
        $result = Invoke-IntegrityApply -Root $root -CodeEfi
        $result.Error | Should -Match 'Golden Backup integrity changed before restore copy'
        $global:PreCopies | Should -Be 1
        $global:GoldenCopies | Should -Be 0
    }

    It 'ne lance pas le controle complet pendant un dry-run' {
        Mock Get-Disk { New-RestorIntegrityDisk }
        Mock Get-Partition { throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
        Mock Get-Volume { throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
        Mock Add-PartitionAccessPath { throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
        Mock robocopy.exe { throw 'REAL HARDWARE ACCESS BLOCKED BY TEST' }
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'dry-integrity') -RepoRoot $script:RepoRoot
        $result = Invoke-RestorChecked -Path $script:RestoreScript -Parameter @{
            BackupPath     = $root
            CodeEfi        = $true
            ExpectedModel  = 'RESTOR-PC TEST NVME'
            ExpectedSerial = 'TEST_SERIAL_0001'
        }
        $result.Code | Should -Be 0
        ($result.Output -join "`n") | Should -Match 'Aucune écriture effectuée|Aucune ecriture effectuee'
        ($result.Output -join "`n") | Should -Not -Match 'Full Golden Backup integrity verification'
        ($result.Output -join "`n") | Should -Not -Match 'Rechecking Golden Backup'
    }
}

Describe 'Post-restore destination verification' {
    BeforeEach {
        $global:DestinationFolder = Mount-RestorFakeDestination
        Enable-RestorIntegrityApply
    }

    AfterEach {
        if ($global:IntegrityLetter) {
            Remove-PSDrive -Name $global:IntegrityLetter -Force -ErrorAction SilentlyContinue
        }
    }

    It 'accepte une destination conforme et ecrit un rapport VALID' {
        Mock robocopy.exe {
            $source = [string]$args[0]
            $destination = [string]$args[1]
            if ($destination -notlike '*PRE-RESTORE*') {
                Copy-RestorGoldenPayload -Source $source -Destination $destination
            }
            $global:LASTEXITCODE = 0
        }
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'post-valid') -RepoRoot $script:RepoRoot
        $result = Invoke-IntegrityApply -Root $root -CodeEfi
        $result.Code | Should -Be 0
        $reportFile = @(Get-ChildItem -Path (Join-Path $TestDrive 'pre-root') -Recurse -Filter 'RESTORE-RESULT.json') | Select-Object -Last 1
        $report = Get-Content -LiteralPath $reportFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.Status | Should -Be 'VALID'
        $report.FilesExpected | Should -BeGreaterThan 0
        $report.FilesVerified | Should -Be $report.FilesExpected
        @($report.MissingFiles).Count | Should -Be 0
        @($report.HashMismatches).Count | Should -Be 0
        $report.BackupManifestSha256 | Should -Not -BeNullOrEmpty
    }

    It 'echoue si robocopy reussit mais qu un fichier destination manque' {
        Mock robocopy.exe {
            $source = [string]$args[0]
            $destination = [string]$args[1]
            if ($destination -notlike '*PRE-RESTORE*') {
                Copy-RestorGoldenPayload -Source $source -Destination $destination
                Remove-Item -LiteralPath (Join-Path $destination 'EFI\Microsoft\Boot\bootmgfw.efi') -Force
            }
            $global:LASTEXITCODE = 0
        }
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'post-missing') -RepoRoot $script:RepoRoot
        $result = Invoke-IntegrityApply -Root $root -CodeEfi
        $result.Error | Should -Match 'Post-restore verification failed'
        $result.Error | Should -Match 'PRE-RESTORE-'
        $reportFile = @(Get-ChildItem -Path (Join-Path $TestDrive 'pre-root') -Recurse -Filter 'RESTORE-RESULT.json') | Select-Object -Last 1
        $report = Get-Content -LiteralPath $reportFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.Status | Should -Be 'FAILED'
        $report.PreRestorePath | Should -Match 'PRE-RESTORE-'
    }

    It 'echoue si le hash destination ne correspond pas au manifeste' {
        Mock robocopy.exe {
            $source = [string]$args[0]
            $destination = [string]$args[1]
            if ($destination -notlike '*PRE-RESTORE*') {
                Copy-RestorGoldenPayload -Source $source -Destination $destination
                Set-Content -LiteralPath (Join-Path $destination 'EFI\Microsoft\Boot\bootmgfw.efi') -Value 'TAMPERED DESTINATION' -Encoding ascii
            }
            $global:LASTEXITCODE = 0
        }
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'post-hash') -RepoRoot $script:RepoRoot
        $result = Invoke-IntegrityApply -Root $root -CodeEfi
        $result.Error | Should -Match 'Post-restore verification failed'
        $result.Error | Should -Match 'PRE-RESTORE-'
        $reportFile = @(Get-ChildItem -Path (Join-Path $TestDrive 'pre-root') -Recurse -Filter 'RESTORE-RESULT.json') | Select-Object -Last 1
        $report = Get-Content -LiteralPath $reportFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.Status | Should -Be 'FAILED'
        @($report.HashMismatches).Count | Should -BeGreaterThan 0
    }

    It 'conserve un fichier supplementaire sans invalider la restauration' {
        Mock robocopy.exe {
            $source = [string]$args[0]
            $destination = [string]$args[1]
            if ($destination -notlike '*PRE-RESTORE*') {
                Copy-RestorGoldenPayload -Source $source -Destination $destination
                Set-Content -LiteralPath (Join-Path $global:DestinationFolder 'EXTRA-KEEP.txt') -Value 'KEEP ME' -Encoding ascii
            }
            $global:LASTEXITCODE = 0
        }
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'post-extra') -RepoRoot $script:RepoRoot
        $result = Invoke-IntegrityApply -Root $root -CodeEfi
        $result.Code | Should -Be 0 -Because $result.Error
        $extra = Join-Path $global:DestinationFolder 'EXTRA-KEEP.txt'
        Get-Content -LiteralPath $extra -Raw | Should -Match 'KEEP ME'
        $reportFile = @(Get-ChildItem -Path (Join-Path $TestDrive 'pre-root') -Recurse -Filter 'RESTORE-RESULT.json') | Select-Object -Last 1
        $report = Get-Content -LiteralPath $reportFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $report.Status | Should -Be 'VALID'
        $report.ExtraFilesPreserved | Should -BeGreaterThan 0
    }
}
