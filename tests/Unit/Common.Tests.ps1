$script:RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
Import-Module (Join-Path $script:RepoRoot 'scripts\lib\RestorPc.Common.psm1') -Force
. (Join-Path $PSScriptRoot '..\Helpers\TestFixture.ps1')

Describe 'ConvertTo-NormalizedSerial' {
    It 'conserve un serial deja normalise' {
        ConvertTo-NormalizedSerial 'TEST_SERIAL_0001' | Should -Be 'TEST_SERIAL_0001'
    }
    It 'retire les espaces autour du serial' {
        ConvertTo-NormalizedSerial ' TEST_SERIAL_0001 ' | Should -Be 'TEST_SERIAL_0001'
    }
    It 'retire le point final ajoute par certaines sources WMI' {
        ConvertTo-NormalizedSerial 'TEST_SERIAL_0001.' | Should -Be 'TEST_SERIAL_0001'
    }
    It 'met le serial en majuscules et retire le point final' {
        ConvertTo-NormalizedSerial 'test_serial_0001.' | Should -Be 'TEST_SERIAL_0001'
    }
    It 'traite null comme une chaine vide' {
        ConvertTo-NormalizedSerial $null | Should -Be ''
    }
    It 'traite une chaine vide' {
        ConvertTo-NormalizedSerial '' | Should -Be ''
    }
    It 'traite une chaine d espaces' {
        ConvertTo-NormalizedSerial '   ' | Should -Be ''
    }
}

Describe 'Resolve-RestorDiskSelection' {
    BeforeAll {
        function script:New-FakeDisk {
            param($Model, $Serial, $Style = 'GPT', $Bus = 'NVMe', $Number = 99)
            [pscustomobject]@{
                FriendlyName   = $Model
                SerialNumber   = $Serial
                PartitionStyle = $Style
                BusType        = $Bus
                Number         = $Number
            }
        }
    }

    It 'accepte le seul disque GPT NVMe correspondant' {
        $selection = Resolve-RestorDiskSelection -Disks @(
            (New-FakeDisk -Model 'RESTOR-PC TEST NVME' -Serial 'TEST_SERIAL_0001')
        ) -Model 'RESTOR-PC TEST NVME' -Serial 'TEST_SERIAL_0001'
        $selection.Code | Should -Be 'Ok'
        $selection.Disk.Number | Should -Be 99
    }

    It 'normalise le serial du disque simule avant la comparaison' {
        $selection = Resolve-RestorDiskSelection -Disks @(
            (New-FakeDisk -Model ' RESTOR-PC TEST NVME ' -Serial ' test_serial_0001. ')
        ) -Model 'RESTOR-PC TEST NVME' -Serial 'TEST_SERIAL_0001'
        $selection.Code | Should -Be 'Ok'
    }

    It 'refuse une liste vide' {
        (Resolve-RestorDiskSelection -Disks @() -Model 'RESTOR-PC TEST NVME' -Serial 'TEST_SERIAL_0001').Code | Should -Be 'None'
    }

    It 'refuse un disque qui ne correspond pas' {
        $selection = Resolve-RestorDiskSelection -Disks @(
            (New-FakeDisk -Model 'OTHER DISK' -Serial 'OTHER')
        ) -Model 'RESTOR-PC TEST NVME' -Serial 'TEST_SERIAL_0001'
        $selection.Code | Should -Be 'None'
    }

    It 'refuse deux disques identiques' {
        $selection = Resolve-RestorDiskSelection -Disks @(
            (New-FakeDisk -Model 'RESTOR-PC TEST NVME' -Serial 'TEST_SERIAL_0001' -Number 1),
            (New-FakeDisk -Model 'RESTOR-PC TEST NVME' -Serial 'TEST_SERIAL_0001' -Number 2)
        ) -Model 'RESTOR-PC TEST NVME' -Serial 'TEST_SERIAL_0001'
        $selection.Code | Should -Be 'Ambiguous'
    }

    It 'refuse un disque MBR' {
        $selection = Resolve-RestorDiskSelection -Disks @(
            (New-FakeDisk -Model 'RESTOR-PC TEST NVME' -Serial 'TEST_SERIAL_0001' -Style 'MBR')
        ) -Model 'RESTOR-PC TEST NVME' -Serial 'TEST_SERIAL_0001'
        $selection.Code | Should -Be 'NotGpt'
    }

    It 'refuse un bus SATA' {
        $selection = Resolve-RestorDiskSelection -Disks @(
            (New-FakeDisk -Model 'RESTOR-PC TEST NVME' -Serial 'TEST_SERIAL_0001' -Bus 'SATA')
        ) -Model 'RESTOR-PC TEST NVME' -Serial 'TEST_SERIAL_0001'
        $selection.Code | Should -Be 'NotNvme'
    }
}

Describe 'Test-RobocopySuccessCode' {
    $successCases = foreach ($code in 0..7) { @{ Code = $code } }
    It 'accepte le code robocopy <Code>' -TestCases $successCases {
        param($Code)
        Test-RobocopySuccessCode -ExitCode $Code | Should -BeTrue
    }
    It 'refuse le code robocopy 8' {
        Test-RobocopySuccessCode -ExitCode 8 | Should -BeFalse
    }
    It 'refuse le code robocopy 16' {
        Test-RobocopySuccessCode -ExitCode 16 | Should -BeFalse
    }
}

Describe 'Resolve-RestorTemporaryLetter' {
    It 'choisit R quand aucune lettre n est prise' {
        Resolve-RestorTemporaryLetter -UsedLetter @() | Should -Be 'R'
    }
    It 'choisit T quand R et S sont pris' {
        Resolve-RestorTemporaryLetter -UsedLetter @('R', 'S') | Should -Be 'T'
    }
    It 'echoue clairement quand R S T W Z L sont tous pris' {
        { Resolve-RestorTemporaryLetter -UsedLetter @('R', 'S', 'T', 'W', 'Z', 'L') } | Should -Throw '*Aucune lettre temporaire*'
    }
}

Describe 'Get-RestorManifestLine' {
    It 'produit deux fois les memes lignes dans le meme ordre' {
        $root = Join-Path $TestDrive 'manifest'
        New-Item -ItemType Directory -Path (Join-Path $root 'dir') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'dir\b.txt') -Value 'beta' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $root 'dir\a.txt') -Value 'alpha' -Encoding ascii
        $first = @(Get-RestorManifestLine -Root $root)
        $second = @(Get-RestorManifestLine -Root $root)
        ($first -join "`n") | Should -Be ($second -join "`n")
        $first[0].Substring(66) | Should -Be 'dir\a.txt'
        $first[1].Substring(66) | Should -Be 'dir\b.txt'
        (Get-Item -LiteralPath (Join-Path $root 'dir\a.txt')).LastWriteTime = (Get-Date).AddDays(-4)
        $third = @(Get-RestorManifestLine -Root $root)
        ($third -join "`n") | Should -Be ($first -join "`n")
    }
}
