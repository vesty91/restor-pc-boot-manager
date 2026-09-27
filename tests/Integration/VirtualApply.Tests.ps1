BeforeAll {
    $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:LabRoot = Join-Path $script:RepoRoot 'test\vhd\restore-lab'
    $script:InventoryPath = Join-Path $script:LabRoot 'lab-inventory.json'
    $script:RestoreScript = Join-Path $script:RepoRoot 'scripts\Restore-RestorBootManager.ps1'
    Import-Module (Join-Path $script:RepoRoot 'scripts\lib\RestorPc.Common.psm1') -Force
    . (Join-Path $PSScriptRoot '..\Helpers\TestFixture.ps1')
}

Describe 'PRE-RESTORE failure on the virtual lab' -Tag VHD {
    BeforeEach {
        $script:Inventory = Get-Content -LiteralPath $script:InventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:Partitions = @(
            foreach ($item in @($script:Inventory.Partitions)) {
                [pscustomobject]@{
                    DiskNumber      = 999
                    PartitionNumber = [int]$item.PartitionNumber
                    DriveLetter     = [string]$item.DriveLetter
                    Size            = [int64]$item.Size
                    GptType         = [string]$item.GptType
                    Type            = 'Basic'
                }
            }
        )
        $script:Volumes = @(
            foreach ($item in @($script:Inventory.Partitions)) {
                [pscustomobject]@{
                    DriveLetter     = [string]$item.DriveLetter
                    FileSystem      = 'FAT32'
                    FileSystemLabel = [string]$item.Label
                }
            }
        )
        $global:LabPartitions = $script:Partitions
        $global:LabVolumes = $script:Volumes
        Mock Get-Disk {
            [pscustomobject]@{
                FriendlyName   = 'RESTOR-PC TEST NVME'
                SerialNumber   = 'TEST_SERIAL_0001'
                PartitionStyle = 'GPT'
                BusType        = 'NVMe'
                Number         = 999
            }
        }
        Mock Get-Partition {
            foreach ($item in @($global:LabPartitions)) { Write-Output $item }
        }
        Mock Get-Volume {
            param($DriveLetter)
            return @($global:LabVolumes | Where-Object { [string]$_.DriveLetter -eq [string]$DriveLetter }) | Select-Object -First 1
        }
        Mock Add-PartitionAccessPath { throw 'UNEXPECTED PARTITION MOUNT DURING VHD APPLY TEST' }
        Mock Remove-PartitionAccessPath { throw 'UNEXPECTED PARTITION MOUNT DURING VHD APPLY TEST' }
    }

    It 'arrete la restauration quand le PRE-RESTORE robocopy retourne 8' {
        $golden = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'golden-fail') -RepoRoot $script:RepoRoot
        $marker = Join-Path ($script:Inventory.Partitions[0].DriveLetter + ':\') 'PHASE6-MARKER.txt'
        Set-Content -LiteralPath $marker -Value 'KEEP' -Encoding ascii
        $global:RobocopyCalls = 0
        Mock robocopy.exe {
            $global:RobocopyCalls++
            $global:LASTEXITCODE = 8
        }
        $failed = $false
        try {
            & $script:RestoreScript -BackupPath $golden -AllEfi -Apply -ConfirmRestore 'RESTOR-PC' -ExpectedModel 'RESTOR-PC TEST NVME' -ExpectedSerial 'TEST_SERIAL_0001' -PreRestoreRoot (Join-Path $TestDrive 'pre-fail')
        } catch {
            $failed = $true
            $_.Exception.Message | Should -Match 'Pre-backup echoue|Pré-backup échoué'
        }
        $failed | Should -BeTrue
        $global:RobocopyCalls | Should -Be 1
        Get-Content -LiteralPath $marker -Raw | Should -Match 'KEEP'
        Test-Path -LiteralPath (Join-Path ($script:Inventory.Partitions[0].DriveLetter + ':\') 'EFI\Microsoft\Boot\bootmgfw.efi') | Should -BeFalse
    }

    It 'signale le PRE-RESTORE quand la copie Golden retourne 8' {
        $golden = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'golden-late') -RepoRoot $script:RepoRoot
        $global:RobocopyCalls = 0
        Mock robocopy.exe {
            $global:RobocopyCalls++
            if ($global:RobocopyCalls -le 5) { $global:LASTEXITCODE = 0; return }
            $global:LASTEXITCODE = 8
        }
        $caught = ''
        try {
            & $script:RestoreScript -BackupPath $golden -AllEfi -Apply -ConfirmRestore 'RESTOR-PC' -ExpectedModel 'RESTOR-PC TEST NVME' -ExpectedSerial 'TEST_SERIAL_0001' -PreRestoreRoot (Join-Path $TestDrive 'pre-late')
        } catch {
            $caught = $_.Exception.Message
        }
        $caught | Should -Match 'PRE-RESTORE-'
        $global:RobocopyCalls | Should -Be 6
    }
}

Describe 'Production restore apply against the VHDX' -Tag VHD {
    It 'restaure les cinq volumes et conserve les fichiers non lies' {
        $inventory = Get-Content -LiteralPath $script:InventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $image = Get-DiskImage -ImagePath $inventory.VhdPath
        $image.Attached | Should -BeTrue
        $live = Get-DiskImage -ImagePath $inventory.VhdPath | Get-Disk
        [int]$live.Number | Should -Be ([int]$inventory.DiskNumber)
        [bool]$live.IsBoot | Should -BeFalse
        [bool]$live.IsSystem | Should -BeFalse
        [string]$live.FriendlyName | Should -Not -Be 'SAMSUNG MZVLB256HAHQ-000L2'
        @($inventory.Partitions).Count | Should -Be 5

        $golden = New-RestorTestGoldenBackup -Root (Join-Path $script:LabRoot 'golden') -RepoRoot $script:RepoRoot
        foreach ($item in @($inventory.Partitions)) {
            $root = $item.DriveLetter + ':\'
            Set-Content -LiteralPath (Join-Path $root 'BEFORE-RESTORE.txt') -Value ($item.Name + ' BEFORE') -Encoding ascii
            Set-Content -LiteralPath (Join-Path $root 'EXTRA-FILE-THAT-SHOULD-SURVIVE.txt') -Value 'KEEP ME' -Encoding ascii
        }
        $code = @($inventory.Partitions | Where-Object { $_.Name -eq 'CODE-EFI' } | Select-Object -First 1)
        $oldEfi = Join-Path ($code.DriveLetter + ':\') 'EFI\Microsoft\Boot\bootmgfw.efi'
        New-Item -ItemType Directory -Path (Split-Path -Parent $oldEfi) -Force | Out-Null
        Set-Content -LiteralPath $oldEfi -Value 'OLD CODE EFI' -Encoding ascii

        $partitions = @(
            foreach ($item in @($inventory.Partitions)) {
                [pscustomobject]@{
                    DiskNumber      = 999
                    PartitionNumber = [int]$item.PartitionNumber
                    DriveLetter     = [string]$item.DriveLetter
                    Size            = [int64]$item.Size
                    GptType         = [string]$item.GptType
                    Type            = 'Basic'
                }
            }
        )
        $volumes = @(
            foreach ($item in @($inventory.Partitions)) {
                [pscustomobject]@{
                    DriveLetter     = [string]$item.DriveLetter
                    FileSystem      = 'FAT32'
                    FileSystemLabel = [string]$item.Label
                }
            }
        )
        $global:LabPartitions = $partitions
        $global:LabVolumes = $volumes
        Mock Get-Disk {
            [pscustomobject]@{
                FriendlyName   = 'RESTOR-PC TEST NVME'
                SerialNumber   = 'TEST_SERIAL_0001'
                PartitionStyle = 'GPT'
                BusType        = 'NVMe'
                Number         = 999
            }
        }
        Mock Get-Partition {
            foreach ($item in @($global:LabPartitions)) { Write-Output $item }
        }
        Mock Get-Volume {
            param($DriveLetter)
            return @($global:LabVolumes | Where-Object { [string]$_.DriveLetter -eq [string]$DriveLetter }) | Select-Object -First 1
        }
        Mock Add-PartitionAccessPath { throw 'UNEXPECTED PARTITION MOUNT DURING VHD APPLY TEST' }
        Mock Remove-PartitionAccessPath { throw 'UNEXPECTED PARTITION MOUNT DURING VHD APPLY TEST' }

        $preParent = Join-Path $script:LabRoot 'pre-restore'
        $started = Get-Date
        & $script:RestoreScript -BackupPath $golden -AllEfi -Apply -ConfirmRestore 'RESTOR-PC' -ExpectedModel 'RESTOR-PC TEST NVME' -ExpectedSerial 'TEST_SERIAL_0001' -PreRestoreRoot $preParent

        $checked = 0
        $mismatches = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($inventory.Partitions)) {
            $sourceRoot = Join-Path $golden ('ESP\' + $item.Name)
            $destinationRoot = $item.DriveLetter + ':\'
            $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force)
            foreach ($file in $files) {
                $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
                $copied = Join-Path $destinationRoot $relative
                if (-not (Test-Path -LiteralPath $copied)) { $mismatches.Add('ABSENT ' + $relative); continue }
                $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                $copiedHash = (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash
                $checked++
                if ($sourceHash -ne $copiedHash) { $mismatches.Add($relative) }
            }
            Get-Content -LiteralPath (Join-Path $destinationRoot 'EXTRA-FILE-THAT-SHOULD-SURVIVE.txt') -Raw | Should -Match 'KEEP ME'
            Get-Content -LiteralPath (Join-Path $destinationRoot 'BEFORE-RESTORE.txt') -Raw | Should -Match 'BEFORE'
        }
        Get-Content -LiteralPath $oldEfi -Raw | Should -Match '^TEST EFI FILE CODE'
        $preDirs = @(Get-ChildItem -LiteralPath $preParent -Directory -Filter 'PRE-RESTORE-*')
        $preDirs.Count | Should -BeGreaterOrEqual 1
        $preLatest = $preDirs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Get-Content -LiteralPath (Join-Path $preLatest.FullName 'CODE-EFI\EFI\Microsoft\Boot\bootmgfw.efi') -Raw | Should -Match '^OLD CODE EFI'
        $mismatches.Count | Should -Be 0

        $report = [ordered]@{
            StartedAt            = $started.ToString('o')
            FinishedAt           = (Get-Date).ToString('o')
            VhdPath              = [string]$inventory.VhdPath
            VirtualDiskNumber    = [int]$inventory.DiskNumber
            Targets              = @($inventory.Partitions | ForEach-Object { $_.Name })
            PreRestorePath       = $preLatest.FullName
            FilesChecked         = $checked
            HashMismatches       = @($mismatches)
            ExtraFilesPreserved  = 5
            Status               = 'VALID'
        }
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $script:LabRoot 'RESTORE-REPORT.json'), ($report | ConvertTo-Json -Depth 4), $utf8)
    }
}
