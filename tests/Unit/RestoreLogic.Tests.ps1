$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
Import-Module (Join-Path $script:RepoRoot 'scripts\lib\RestorPc.Common.psm1') -Force

Describe 'Get-RestorRestoreTarget' {
    It 'ne selectionne que RESTOR-BOOT' {
        @(Get-RestorRestoreTarget -RestorBoot) | Should -Be 'RESTOR-BOOT'
    }
    It 'ne selectionne que CODE-EFI' {
        @(Get-RestorRestoreTarget -CodeEfi) | Should -Be 'CODE-EFI'
    }
    It 'ne selectionne que VESTY-EFI' {
        @(Get-RestorRestoreTarget -VestyEfi) | Should -Be 'VESTY-EFI'
    }
    It 'ne selectionne que RESCUE-EFI' {
        @(Get-RestorRestoreTarget -RescueEfi) | Should -Be 'RESCUE-EFI'
    }
    It 'ne selectionne que LOCKPICK-EFI' {
        @(Get-RestorRestoreTarget -LockpickEfi) | Should -Be 'LOCKPICK-EFI'
    }
    It 'selectionne exactement cinq cibles avec AllEfi' {
        $targets = @(Get-RestorRestoreTarget -AllEfi)
        $targets.Count | Should -Be 5
        $targets | Should -Be @('RESTOR-BOOT', 'CODE-EFI', 'VESTY-EFI', 'RESCUE-EFI', 'LOCKPICK-EFI')
    }
    It 'ne duplique pas RESTOR-BOOT quand AllEfi est combine a RestorBoot' {
        $targets = @(Get-RestorRestoreTarget -AllEfi -RestorBoot)
        $targets.Count | Should -Be 5
        @($targets | Where-Object { $_ -eq 'RESTOR-BOOT' }).Count | Should -Be 1
    }
    It 'retourne aucune cible sans commutateur' {
        @(Get-RestorRestoreTarget).Count | Should -Be 0
    }
}
