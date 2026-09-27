Describe 'Test-RestorGoldenBackup' {
    BeforeAll {
        $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $script:Verifier = Join-Path $script:RepoRoot 'scripts\Test-RestorGoldenBackup.ps1'
        Import-Module (Join-Path $script:RepoRoot 'scripts\lib\RestorPc.Common.psm1') -Force
        . (Join-Path $PSScriptRoot '..\Helpers\TestFixture.ps1')
        function script:Get-RestorOutputText {
            param($Result)
            return ($Result.Output -join "`n")
        }
    }

    It 'accepte une fixture valide' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'valid') -RepoRoot $script:RepoRoot
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Be 0
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP VALID'
        Get-RestorOutputText $result | Should -Not -Match 'GOLDEN BACKUP INVALID'
    }

    It 'refuse un fichier obligatoire absent' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'missing') -RepoRoot $script:RepoRoot
        Remove-Item -LiteralPath (Join-Path $root 'ESP\RESTOR-BOOT\EFI\BOOT\BOOTX64.EFI') -Force
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match 'Fichier absent'
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }

    It 'refuse un fichier modifie apres le manifeste' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'changed') -RepoRoot $script:RepoRoot
        $target = Join-Path $root 'ESP\CODE-EFI\EFI\Microsoft\Boot\bootmgfw.efi'
        [IO.File]::WriteAllText($target, 'TEST EFI FILE CODE CHANGED', (Get-RestorUtf8))
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match 'Fichier modifi'
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }

    It 'refuse un manifeste dont le hash ne correspond plus a BACKUP-INFO.json' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'hash') -RepoRoot $script:RepoRoot
        $manifest = Join-Path $root 'Manifests\SHA256-MANIFEST.txt'
        [IO.File]::AppendAllText($manifest, "`r`n", (Get-RestorUtf8))
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match 'ManifestSha256 ne correspond pas'
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }

    It 'refuse un manifeste non trie meme si son hash est a jour' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'sort') -RepoRoot $script:RepoRoot
        $manifest = Join-Path $root 'Manifests\SHA256-MANIFEST.txt'
        $lines = [string[]](Get-Content -LiteralPath $manifest -Encoding UTF8)
        [array]::Reverse($lines)
        [IO.File]::WriteAllLines($manifest, $lines, (Get-RestorUtf8))
        Sync-RestorTestManifestHash -Root $root
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match "n'est pas tri"
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }

    It 'refuse une ligne de manifeste dupliquee' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'dup') -RepoRoot $script:RepoRoot
        $manifest = Join-Path $root 'Manifests\SHA256-MANIFEST.txt'
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in @(Get-Content -LiteralPath $manifest -Encoding UTF8)) { $lines.Add($line) }
        $lines.Add($lines[0])
        [IO.File]::WriteAllLines($manifest, $lines.ToArray(), (Get-RestorUtf8))
        Sync-RestorTestManifestHash -Root $root
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match 'Doublon manifeste'
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }

    It 'refuse un fichier present sur le disque mais absent du manifeste' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'extra') -RepoRoot $script:RepoRoot
        Write-RestorTextFile -Path (Join-Path $root 'ESP\RESTOR-BOOT\unexpected.bin') -Content 'UNEXPECTED'
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match 'Fichier hors manifeste'
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }

    It 'refuse un backup au statut WARNING' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'warning') -RepoRoot $script:RepoRoot
        Set-RestorTestBackupStatus -Root $root -Status 'WARNING'
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match 'Status du backup : WARNING'
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }

    It 'refuse un backup au statut FAILED' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'failed') -RepoRoot $script:RepoRoot
        Set-RestorTestBackupStatus -Root $root -Status 'FAILED'
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match 'Status du backup : FAILED'
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }

    It 'refuse un WIN VESTY dont le hash n est plus celui attendu' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'vesty') -RepoRoot $script:RepoRoot
        $vesty = Join-Path $root 'ESP\RESTOR-BOOT\EFI\BOOT\themes\restor-pc\assets\win_vesty.png'
        [IO.File]::WriteAllText($vesty, 'NOT THE VESTY ICON', (Get-RestorUtf8))
        Update-RestorTestManifest -Root $root -Status 'VALID'
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match 'WIN VESTY SHA256'
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }

    $entryCases = @(
        @{ EntryName = 'WIN CODE' }
        @{ EntryName = 'WIN VESTY' }
        @{ EntryName = 'MEMTEST86+' }
        @{ EntryName = 'RESCUEGRID' }
        @{ EntryName = 'LOCKPICK' }
    )
    It 'refuse une configuration sans l entree <EntryName>' -TestCases $entryCases {
        param($EntryName)
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'missing-entry') -RepoRoot $script:RepoRoot
        $config = Join-Path $root 'ESP\RESTOR-BOOT\EFI\BOOT\refind.conf'
        $text = [IO.File]::ReadAllText($config)
        $text = $text.Replace(('menuentry "' + $EntryName + '"'), ('menuentry "DISABLED ' + $EntryName + '"'))
        [IO.File]::WriteAllText($config, $text, (Get-RestorUtf8))
        Update-RestorTestManifest -Root $root -Status 'VALID'
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match ('Entree ' + [regex]::Escape($EntryName) + '|Entrée ' + [regex]::Escape($EntryName))
        Get-RestorOutputText $result | Should -Match '0 fois'
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }

    It 'refuse une entree rEFInd dupliquee' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'dup-entry') -RepoRoot $script:RepoRoot
        $config = Join-Path $root 'ESP\RESTOR-BOOT\EFI\BOOT\refind.conf'
        $text = [IO.File]::ReadAllText($config)
        $text += "`r`nmenuentry `"WIN CODE`" {`r`n}`r`n"
        [IO.File]::WriteAllText($config, $text, (Get-RestorUtf8))
        Update-RestorTestManifest -Root $root -Status 'VALID'
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match 'Entrée WIN CODE présente 2 fois'
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }

    It 'refuse un backup sans boot.wim RescueGrid' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'wim') -RepoRoot $script:RepoRoot
        Remove-Item -LiteralPath (Join-Path $root 'RESTOR-TOOLS\RescueGrid\WinPE\boot.wim') -Force
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match 'boot.wim RescueGrid absent'
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }

    It 'refuse un backup sans boot.sdi RescueGrid' {
        $root = New-RestorTestGoldenBackup -Root (Join-Path $TestDrive 'sdi') -RepoRoot $script:RepoRoot
        Remove-Item -LiteralPath (Join-Path $root 'RESTOR-TOOLS\RescueGrid\WinPE\boot.sdi') -Force
        $result = Invoke-RestorChecked -Path $script:Verifier -Parameter @{ BackupPath = $root }
        $result.Code | Should -Not -Be 0
        Get-RestorOutputText $result | Should -Match 'boot.sdi RescueGrid absent'
        Get-RestorOutputText $result | Should -Match 'GOLDEN BACKUP INVALID'
    }
}
