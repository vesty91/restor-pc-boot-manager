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

Describe 'Resolve-RestorPreRestoreRoot' {
    It 'utilise C:\RESTOR-PC-BACKUP par defaut' {
        $restore = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\scripts\Restore-RestorBootManager.ps1'))
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($restore, [ref]$tokens, [ref]$parseErrors)
        $parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PreRestoreRoot' })
        $parameter.Count | Should -Be 1
        $parameter[0].DefaultValue.Value | Should -Be 'C:\RESTOR-PC-BACKUP'
        Resolve-RestorPreRestoreRoot | Should -Be 'C:\RESTOR-PC-BACKUP'
    }
    It 'accepte un chemin de laboratoire explicite' {
        $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $lab = Join-Path $repo 'test\vhd\restore-lab\pre-restore'
        (Resolve-RestorPreRestoreRoot -Path $lab).TrimEnd('\') | Should -Be ([IO.Path]::GetFullPath($lab).TrimEnd('\'))
    }
    It 'refuse une chaine vide' {
        { Resolve-RestorPreRestoreRoot -Path '' } | Should -Throw '*vide*'
    }
    It 'refuse la racine C:\' {
        { Resolve-RestorPreRestoreRoot -Path 'C:\' } | Should -Throw '*racine*'
    }
    It 'refuse Windows' {
        { Resolve-RestorPreRestoreRoot -Path $env:SystemRoot } | Should -Throw '*Windows*'
    }
    It 'refuse System32' {
        { Resolve-RestorPreRestoreRoot -Path (Join-Path $env:SystemRoot 'System32') } | Should -Throw '*System32*'
    }
}
