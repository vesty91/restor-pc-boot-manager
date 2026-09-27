BeforeAll {
    $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    Import-Module (Join-Path $script:RepoRoot 'scripts\lib\RestorPc.Common.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'scripts\lib\RestorPc.Backup.psm1') -Force
    . (Join-Path $PSScriptRoot '..\Helpers\TestFixture.ps1')

    function script:Add-RestorManifestText {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string[]]$ExtraLine
        )
        $manifest = Join-Path $Root 'Manifests\SHA256-MANIFEST.txt'
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($line in @(Get-Content -LiteralPath $manifest -Encoding UTF8)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { $lines.Add($line) }
        }
        foreach ($line in @($ExtraLine)) { $lines.Add($line) }
        [IO.File]::WriteAllLines($manifest, $lines.ToArray(), (Get-RestorUtf8))
        Sync-RestorTestManifestHash -Root $Root
    }
}

Describe 'Test-RestorBackupIntegrity' {
    It 'accepte une fixture valide avec un resultat structure' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'valid-integrity') -RepoRoot $script:RepoRoot
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeTrue
        $result.Status | Should -Be 'VALID'
        $result.ManifestHashValid | Should -BeTrue
        $result.FilesExpected | Should -BeGreaterThan 0
        $result.FilesVerified | Should -Be $result.FilesExpected
        $result.MissingFiles.Count | Should -Be 0
        $result.HashMismatches.Count | Should -Be 0
        $result.UnexpectedFiles.Count | Should -Be 0
        $result.UnsafePaths.Count | Should -Be 0
        $result.InvalidManifestLines.Count | Should -Be 0
        $result.DuplicateEntries.Count | Should -Be 0
        $result.Failures.Count | Should -Be 0
        $result.VestyHashValid | Should -BeTrue
        $result.RefindConfigValid | Should -BeTrue
        $result.RescueGridValid | Should -BeTrue
    }

    It 'signale un payload modifie sans abandonner les autres fichiers' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'changed-integrity') -RepoRoot $script:RepoRoot
        $target = Join-Path $root 'ESP\CODE-EFI\EFI\Microsoft\Boot\bootmgfw.efi'
        [IO.File]::WriteAllText($target, 'TEST EFI FILE CODE CHANGED', (Get-RestorUtf8))
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.HashMismatches).Count | Should -Be 1
        $result.FilesExpected | Should -BeGreaterThan 1
        $result.FilesVerified | Should -Be $result.FilesExpected
        @($result.MissingFiles).Count | Should -Be 0
    }

    It 'collecte un fichier absent, un fichier modifie et un fichier inattendu' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'many-integrity') -RepoRoot $script:RepoRoot
        Remove-Item -LiteralPath (Join-Path $root 'BCD\VESTY-EFI\BCD') -Force
        [IO.File]::WriteAllText((Join-Path $root 'ESP\VESTY-EFI\EFI\Microsoft\Boot\bootmgfw.efi'), 'CHANGED', (Get-RestorUtf8))
        Write-RestorTextFile -Path (Join-Path $root 'ESP\RESTOR-BOOT\UNEXPECTED.BIN') -Content 'EXTRA'
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.MissingFiles).Count | Should -BeGreaterOrEqual 1
        @($result.HashMismatches).Count | Should -BeGreaterOrEqual 1
        @($result.UnexpectedFiles).Count | Should -BeGreaterOrEqual 1
        $result.FilesVerified | Should -BeGreaterThan 0
        $result.FilesVerified | Should -BeLessThan $result.FilesExpected
    }

    It 'refuse une ligne courte sans Substring hors limites' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'broken-line') -RepoRoot $script:RepoRoot
        Add-RestorManifestText -Root $root -ExtraLine @('BROKEN')
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.InvalidManifestLines) | Should -Contain 'BROKEN'
    }

    It 'refuse un chemin relatif qui sort du backup avant tout hash externe' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'traversal') -RepoRoot $script:RepoRoot
        $outside = [IO.Path]::GetFullPath((Join-Path $root '..\outside.bin'))
        Mock Get-FileHash -ParameterFilter { $LiteralPath -eq $outside } -MockWith { throw 'HASHED OUTSIDE FILE' }
        $hash = 'A' * 64
        Add-RestorManifestText -Root $root -ExtraLine @("$hash  ..\outside.bin")
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.UnsafePaths).Count | Should -BeGreaterThan 0
        Test-Path -LiteralPath $outside | Should -BeFalse
        Assert-MockCalled -CommandName Get-FileHash -ParameterFilter { $LiteralPath -eq $outside } -Times 0 -Scope It
    }

    It 'refuse un chemin absolu sans ouvrir la cible' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'absolute') -RepoRoot $script:RepoRoot
        $absolute = 'C:\RESTOR-PC-DOES-NOT-EXIST\file.bin'
        Mock Get-FileHash -ParameterFilter { $LiteralPath -eq $absolute } -MockWith { throw 'HASHED ABSOLUTE FILE' }
        $hash = 'B' * 64
        Add-RestorManifestText -Root $root -ExtraLine @("$hash  $absolute")
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.UnsafePaths).Count | Should -BeGreaterThan 0
        Assert-MockCalled -CommandName Get-FileHash -ParameterFilter { $LiteralPath -eq $absolute } -Times 0 -Scope It
    }

    It 'refuse un flux alternatif et un chemin qui commence par une barre' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'ads') -RepoRoot $script:RepoRoot
        $hash = 'C' * 64
        Add-RestorManifestText -Root $root -ExtraLine @(
            ("{0}  ESP\CODE-EFI\a.bin:stream" -f $hash),
            ("{0}  \outside.bin" -f $hash)
        )
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.UnsafePaths).Count | Should -BeGreaterOrEqual 2
    }

    It 'refuse deux chemins qui ne different que par la casse' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'case-dup') -RepoRoot $script:RepoRoot
        $file = Join-Path $root 'ESP\CODE-EFI\a.bin'
        Write-RestorTextFile -Path $file -Content 'A'
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        Add-RestorManifestText -Root $root -ExtraLine @(
            ("{0}  ESP\CODE-EFI\a.bin" -f $hash),
            ("{0}  esp\code-efi\A.bin" -f $hash)
        )
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.DuplicateEntries).Count | Should -BeGreaterOrEqual 1
    }

    It 'refuse un repertoire qui usurpe un chemin critique leaf' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'dir-as-leaf') -RepoRoot $script:RepoRoot
        $target = Join-Path $root 'ESP\CODE-EFI\EFI\Microsoft\Boot\bootmgfw.efi'
        Remove-Item -LiteralPath $target -Force
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.StructureFailures) | Should -Contain 'ESP\CODE-EFI\EFI\Microsoft\Boot\bootmgfw.efi'
    }

    It 'refuse un Golden Backup sans chargeur MemTest86+' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'no-memtest') -RepoRoot $script:RepoRoot
        $target = Join-Path $root 'ESP\RESTOR-BOOT\EFI\TOOLS\MEMTEST\mt86plus.efi'
        Remove-Item -LiteralPath $target -Force
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.StructureFailures) | Should -Contain 'ESP\RESTOR-BOOT\EFI\TOOLS\MEMTEST\mt86plus.efi'
    }

    It 'refuse un Golden Backup sans chaine Lockpick complete' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'no-lockpick-wim') -RepoRoot $script:RepoRoot
        $target = Join-Path $root 'ESP\LOCKPICK-EFI\sources\boot.wim'
        Remove-Item -LiteralPath $target -Force
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.StructureFailures) | Should -Contain 'ESP\LOCKPICK-EFI\sources\boot.wim'
    }

    It 'refuse un Golden Backup sans Lockpick.exe' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'no-lockpick-exe') -RepoRoot $script:RepoRoot
        $target = Join-Path $root 'ESP\LOCKPICK-EFI\Programs\Lockpick\Lockpick.exe'
        Remove-Item -LiteralPath $target -Force
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.StructureFailures) | Should -Contain 'ESP\LOCKPICK-EFI\Programs\Lockpick\Lockpick.exe'
    }

    It 'refuse un Golden Backup sans Lockpick boot BCD' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'no-lockpick-boot-bcd') -RepoRoot $script:RepoRoot
        $target = Join-Path $root 'ESP\LOCKPICK-EFI\boot\BCD'
        Remove-Item -LiteralPath $target -Force
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.StructureFailures) | Should -Contain 'ESP\LOCKPICK-EFI\boot\BCD'
    }

    It 'refuse un Golden Backup sans scripts RescueGrid' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'no-rescuegrid-script') -RepoRoot $script:RepoRoot
        $target = Join-Path $root 'RESTOR-TOOLS\RescueGrid\Project\agent\windows\Start-RescueGrid.ps1'
        Remove-Item -LiteralPath $target -Force
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        @($result.StructureFailures) | Should -Contain 'RESTOR-TOOLS\RescueGrid\Project\agent\windows\Start-RescueGrid.ps1'
    }

    It 'refuse un refind.conf dont le loader est corrompu' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'bad-refind-loader') -RepoRoot $script:RepoRoot
        $config = Join-Path $root 'ESP\RESTOR-BOOT\EFI\BOOT\refind.conf'
        $text = [IO.File]::ReadAllText($config)
        $text = $text.Replace('\EFI\Microsoft\Boot\bootmgfw.efi', '\EFI\Microsoft\Boot\WRONG.efi')
        [IO.File]::WriteAllText($config, $text)
        Update-RestorTestManifest -Root $root -Status 'VALID'
        $result = Test-RestorBackupIntegrity -BackupPath $root
        $result.Valid | Should -BeFalse
        $result.RefindConfigValid | Should -BeFalse
        ($result.Failures -join "`n") | Should -Match 'loader'
    }
}
