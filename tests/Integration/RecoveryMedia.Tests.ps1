BeforeAll {
    $script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $script:Builder = Join-Path $script:RepoRoot 'scripts\Build-RestorRecoveryMedia.ps1'
}

Describe 'Build-RestorRecoveryMedia staging' {
    It 'cree le staging sans Golden Backup ni ISO tiers' {
        $out = Join-Path $script:RepoRoot 'artifacts\pester-recovery-media'
        & $script:Builder -OutputRoot $out | Out-Null
        $staging = Join-Path $out 'staging'
        Test-Path -LiteralPath (Join-Path $staging 'scripts\Restore-RestorBootManager.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $staging 'scripts\New-RestorRecoveryDisk.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $staging 'scripts\Test-RestorGoldenBackup.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $staging 'scripts\lib\RestorPc.Backup.psm1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $staging 'scripts\lib\RestorPc.Common.psm1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $staging 'Start-RestorRecovery.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $staging 'RESTOR-PC-BACKUP') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $staging 'Lockpick.iso') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $staging -Recurse -Filter '*.iso' -ErrorAction SilentlyContinue).Count | Should -Be 0
        $sums = Join-Path $out 'SHA256SUMS.txt'
        Test-Path -LiteralPath $sums | Should -BeTrue
        $lines = @(Get-Content -LiteralPath $sums)
        $lines.Count | Should -BeGreaterThan 0
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -notmatch '^[0-9A-Fa-f]{64}  .+$') { throw ("Ligne checksum invalide : " + $line) }
            $hash = $line.Substring(0, 64)
            $rel = $line.Substring(66)
            $full = Join-Path $out $rel
            (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash | Should -Be $hash
        }
        if (Test-Path -LiteralPath $out) {
            Remove-Item -LiteralPath $out -Recurse -Force
        }
    }

    It 'refuse un OutputRoot hors du depot' {
        { & $script:Builder -OutputRoot 'C:\Windows\Temp\restor-media-out' } | Should -Throw
    }

    It 'refuse un chemin frere du depot (prefix collision)' {
        $sibling = $script:RepoRoot.TrimEnd('\') + '-backup'
        { & $script:Builder -OutputRoot $sibling } | Should -Throw
    }
}
