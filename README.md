# Restor-PC Boot Manager

[![RESTOR-PC CI](https://github.com/vesty91/restor-pc-boot-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/vesty91/restor-pc-boot-manager/actions/workflows/ci.yml)

Latest stable release: v1.1.0

Boot manager UEFI graphique basé sur rEFInd, installé sur un NVMe dédié et conçu pour démarrer directement deux installations Windows indépendantes, avec des outils de diagnostic.

## État actuel validé

```text
Firmware UEFI
   |
   v
NVMe RESTOR-PC
   |
   +-- RESTOR-BOOT   EFI 1 Gio      -> rEFInd + thème
   +-- CODE-EFI      EFI 512 Mio    -> BCD dédié WIN CODE
   +-- VESTY-EFI     EFI 512 Mio    -> BCD dédié WIN VESTY
   +-- RESTOR-TOOLS  NTFS 64 Gio    -> outils / ISO / WinPE
   +-- RESCUE-EFI    EFI 512 Mio    -> boot RescueGrid
   +-- LOCKPICK-EFI  EFI 1 Gio      -> média Lockpick complet
   +-- espace libre                 -> Linux plus tard
```

## Boot menu

Le menu rEFInd affiche : **WIN CODE**, **WIN VESTY**, **MEMTEST86+**, **RESCUEGRID** et **LOCKPICK**.

WIN CODE et WIN VESTY possèdent chacun leur propre partition EFI et leur propre BCD avec `timeout 0`. Le menu bleu Windows intermédiaire n'est donc plus nécessaire.

## Thème

Le thème Restor-PC utilise un fond personnalisé, des icônes 176×176 dédiées et une sélection néon rouge/violet.

```text
theme/restor-pc/assets/win_code.png
theme/restor-pc/assets/win_vesty.png
theme/restor-pc/assets/memtest86plus.png
theme/restor-pc/assets/rescuegrid.png
theme/restor-pc/assets/lockpick.png
```

## Configuration rEFInd

La configuration finale est dans `config/refind.conf`. Elle utilise `scanfor manual` pour éviter les doublons et cible explicitement `CODE-EFI`, `VESTY-EFI` et `\EFI\TOOLS\MEMTEST\mt86plus.efi`.

## Scripts

```text
scripts/
  Get-RestorBootInventory.ps1
  Install-RestorBootManager.ps1
  Update-RestorBootMenu.ps1
  Test-RestorBootManager.ps1
  Backup-RestorBootManager.ps1
  Test-RestorGoldenBackup.ps1
  Restore-RestorBootManager.ps1
  Install-RescueGridWinPE.ps1
  Install-Lockpick.ps1
  check-qemu.ps1
  build-test-disk.ps1
  test-boot.ps1
  Test-Repository.ps1
```

## QEMU testing

`Ctrl+Shift+B` lance `RESTOR-PC: Test Bootloader`. TCG est le mode stable. `-Accel whpx` et `-Accel auto` restent optionnels. Les images restent sous `test\` et le script refuse `PhysicalDrive`.

```powershell
.\scripts\check-qemu.ps1
.\scripts\build-test-disk.ps1
.\scripts\test-boot.ps1
```

Le binaire rEFInd n'est pas versionné. Placez la publication officielle 0.14.2 comme décrit dans `bootloader/README.md`.

### Validation

```powershell
.\scripts\Test-RestorBootManager.ps1 -DiskNumber 3
```

### Mise à jour du menu installé

```powershell
.\scripts\Update-RestorBootMenu.ps1 -DiskNumber 3
```

### Backup & Disaster Recovery

```powershell
.\scripts\Backup-RestorBootManager.ps1
.\scripts\Test-RestorGoldenBackup.ps1 -BackupPath "C:\RESTOR-PC-BACKUP\v1.1.0-GOLDEN-..."
.\scripts\Restore-RestorBootManager.ps1 -BackupPath "C:\RESTOR-PC-BACKUP\v1.1.0-GOLDEN-..." -RestorBoot
```

La dernière commande est un dry-run. Le détail est dans `docs/BACKUP-RESTORE.md`.

## CI / Validation

Validation locale :

```powershell
pwsh -NoProfile -File .\scripts\Test-Repository.ps1
```

GitHub Actions : **RESTOR-PC CI** (`.github/workflows/ci.yml`).

La CI ne touche jamais au matériel, ne monte pas de disque physique, ne lance pas QEMU et ne lance pas `Restore -Apply`.

## Releases

- [v1.1.0](docs/releases/v1.1.0.md)
- [Backup et restauration](docs/BACKUP-RESTORE.md)
- [Lockpick](Lockpick/README.md) : `Lockpick.iso` n'est pas distribué par ce dépôt.

## Sécurité

> [!CAUTION]
> Les scripts d'installation initiale peuvent modifier ou effacer un disque. Vérifiez toujours modèle, taille, numéro de série et numéro de disque avant toute opération destructive.

Le NVMe RESTOR-PC peut apparaître `IsSystem=True` une fois qu'il est réellement utilisé pour amorcer rEFInd. Les scripts de maintenance ne doivent donc pas considérer ce seul indicateur comme une anomalie.

## MemTest86+

Le binaire MemTest86+ n'est pas inclus dans le dépôt. Utilisez le binaire officiel x86_64 et installez-le sous `EFI\TOOLS\MEMTEST\mt86plus.efi`.

## Licence

Les scripts et le thème de ce dépôt sont distribués sous licence MIT. rEFInd et MemTest86+ conservent leurs licences respectives.
