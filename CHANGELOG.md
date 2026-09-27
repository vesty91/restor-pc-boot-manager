# Changelog

## [Unreleased]

### Changed

- `Restore -Apply` vérifie chaque payload du Golden Backup avant tout accès disque, puis revérifie l'intégrité et l'empreinte du manifeste immédiatement avant la copie.

### Safety

- Un payload corrompu, absent, inattendu ou un chemin de manifeste dangereux bloque `-Apply`.
- Il n'existe pas de paramètre pour ignorer ce contrôle.
- Les deux vérifications réduisent la fenêtre entre la lecture du backup et la copie. Elles ne constituent pas une authentification cryptographique, ni une garantie pendant l'exécution de `robocopy`.

## [1.2.0] - 2026-09-27

Release de durcissement et de validation. Le menu rEFInd et l'architecture de boot validés en v1.1.0 ne changent pas. Le format interne du Golden Backup reste `1.1.0` : `$BackupVersion` dans `Backup-RestorBootManager.ps1` n'est pas modifié, et aucun nouveau Golden Backup réel n'est produit.

### Added

- Workflow GitHub Actions **RESTOR-PC CI** (`.github/workflows/ci.yml`), job requis `Repository validation`.
- Scripts de validation du dépôt : `scripts/Test-Repository.ps1`, `scripts/Test-Behavior.ps1`, `scripts/Test-PowerShellSyntax.ps1`, `scripts/Test-RestoreSafety.ps1`.
- Réglages PSScriptAnalyzer dans `config/PSScriptAnalyzerSettings.psd1`.
- Pester 5.9.1 et PSScriptAnalyzer 1.25.0, versions figées dans `config/ToolVersions.psd1`.
- Tests Golden Backup synthétiques et tests Restore en dry-run.
- Laboratoire VHDX isolé : `scripts/New-RestorVirtualLab.ps1`, `scripts/Get-RestorVirtualLab.ps1`, `scripts/Test-VirtualRestore.ps1`, `scripts/Test-VirtualLabSafety.ps1`.
- Documentation `docs/VIRTUAL-RESTORE-LAB.md`.

### Changed

- La confirmation Restore est strictement sensible à la casse : seule la valeur `RESTOR-PC` autorise l'écriture avec `-Apply`.
- `-PreRestoreRoot` est configurable. Le défaut production reste `C:\RESTOR-PC-BACKUP`.
- `actions/checkout` est passé à `v7`.
- Les versions des outils de test sont épinglées et installées avec `-RequiredVersion`.
- `main` est protégée par le check requis `Repository validation`.

### Fixed

- Analyse PowerShell cassée par des apostrophes typographiques dans des chaînes.
- Warnings bloquants PSScriptAnalyzer (catch vide, variable automatique écrasée, paramètre inutilisé).
- `-KeepExisting` réutilise un VHDX déjà valide au lieu de recréer ses partitions.

### Testing

- Phase 5 : 67 tests au départ de la suite offline.
- Phase 6 finale : 78 tests découverts.
- CI offline : 73 tests exécutés, 73 réussis, 0 en échec. Les 5 tests marqués `VHD` ne tournent pas sur GitHub Actions.
- Laboratoire VHD local : 5/5 réussis.
- Couverture observée sur cette release : 62.7 %. Ce chiffre décrit l'exécution mesurée. Il n'est pas un seuil futur.

### Safety

- Dry-run par défaut.
- `-Apply` seul est insuffisant.
- La confirmation exacte `RESTOR-PC` est obligatoire pour écrire.
- `Test-RestorGoldenBackup.ps1` refuse un fichier qui ne correspond plus au manifeste.
- `Restore-RestorBootManager.ps1` valide `ManifestSha256` contre le fichier manifeste et refuse, avec `-Apply`, un statut autre que `VALID`. Il ne rehash pas chaque fichier avant la copie.
- Le VHDX du laboratoire est associé explicitement, via `Get-DiskImage -ImagePath | Get-Disk` et `Assert-RestorVirtualLabDisk`, avant toute opération destructive du lab.
- Un disque `IsBoot` ou `IsSystem` est refusé dans le lab.
- Le modèle physique `SAMSUNG MZVLB256HAHQ-000L2` est bloqué dans le lab.
- Aucun test VHD n'est hébergé dans GitHub Actions.
- Aucune reconstruction GPT de production n'est automatique.

## [1.1.0] - 2026-09-27

### Added

- Banc QEMU isolé : `scripts/check-qemu.ps1`, `scripts/build-test-disk.ps1`, `scripts/test-boot.ps1`.
- Tâche Cursor / VS Code `RESTOR-PC: Test Bootloader` sur `Ctrl+Shift+B`.
- Cinq images virtuelles sous `test\` : `restor-boot.img`, `code-efi.img`, `vesty-efi.img`, `rescue-efi.img`, `lockpick-efi.img`. Elles restent ignorées par Git.
- Golden Backup : `scripts/Backup-RestorBootManager.ps1`, `scripts/Test-RestorGoldenBackup.ps1`, `scripts/Restore-RestorBootManager.ps1`.

### Changed

- Le test QEMU démarre en TCG sur `q35` avec `ich9-ahci` et OVMF. WHPX reste disponible avec `-Accel whpx` ou `-Accel auto`.
- Le thème RESTOR-PC et les cinq icônes du menu sont validés graphiquement dans QEMU.

### Fixed

- `win_vesty.png` est réparé en PNG 176×176 lisible par rEFInd. SHA256 `CC67BBF03D668EE61DE3A4F620C3855DF4D2430F2D2BCB473658CF1CE53331F6`. L'ancienne image était corrompue et s'affichait comme un carré jaune/noir.
- `Install-Lockpick.ps1` conserve l'icône `lockpick.png` versionnée et ne la remplace plus par `autorun.ico`.

### Safety

- Le banc QEMU refuse les références à un disque physique, notamment `PhysicalDrive`.
- `Restore-RestorBootManager.ps1` reste en dry-run sans `-Apply` et `-ConfirmRestore "RESTOR-PC"`.
- Aucune reconstruction GPT automatique. Le script de restauration n'appelle pas `Clear-Disk`, `Initialize-Disk`, `Remove-Partition`, `Resize-Partition`, `New-Partition`, `Format-Volume` ni `diskpart clean`.
- `bcdedit /store` n'est plus exécuté sur un BCD vivant pendant la sauvegarde. Le fichier est copié, puis `bcdedit` lit uniquement la copie. Un appel direct peut changer le timestamp sans que la taille du BCD ait été constatée comme modifiée.

### Backup / Recovery

- Un Golden Backup local a été créé et vérifié : 807 fichiers, 1 652 615 023 octets, manifeste `32C40191C6DD1EB9AB2333E5657389F0FEEDBED35DFDD05867D51F08D378E043`. Il n'est pas versionné.
- `Lockpick.iso` n'est pas distribué. Le libellé FAT est `LOCKPICK-EF`, le nom GPT est `LOCKPICK-EFI`, et rEFInd utilise `volume "LOCKPICK-EFI"`.
- `Install-Lockpick.ps1` conserve l'exclusion Defender du volume Lockpick, vérifie qu'elle est présente, et ne désactive pas Defender globalement.

## [1.0.0] - 2026-09-26

Version stable précédente : menu rEFInd WIN CODE, WIN VESTY, MEMTEST86+, RESCUEGRID et LOCKPICK, avec conservation de l'icône Lockpick personnalisée.
