# Changelog

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
