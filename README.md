# Restor-PC Boot Manager

[![RESTOR-PC CI](https://github.com/vesty91/restor-pc-boot-manager/actions/workflows/ci.yml/badge.svg)](https://github.com/vesty91/restor-pc-boot-manager/actions/workflows/ci.yml)

Latest stable release: v1.2.0

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
  Test-Behavior.ps1
  Test-VirtualRestore.ps1
  Test-VirtualLabSafety.ps1
  New-RestorVirtualLab.ps1
  Get-RestorVirtualLab.ps1
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

La dernière commande est un dry-run. Elle ne hash pas les centaines de fichiers du backup. `-PreRestoreRoot` existe, mais son défaut reste `C:\RESTOR-PC-BACKUP`. Le format interne du Golden Backup reste celui de v1.1.0.

Avec `-Apply` et `-ConfirmRestore "RESTOR-PC"`, `Restore-RestorBootManager.ps1` exécute lui-même le contrôle d'intégrité complet : avant `Get-Disk`, puis une seconde fois après le PRE-RESTORE et avant la copie Golden. `Test-RestorGoldenBackup.ps1` reste une vérification indépendante. Ce contrôle valide l'intégrité du manifeste. Il n'authentifie pas l'auteur du backup et ne rend pas la copie `robocopy` atomique. Ne pas lancer `-Apply` sur le NVMe pour valider le dépôt. Le détail est dans `docs/BACKUP-RESTORE.md`.

> [!CAUTION]
> La commande suivante écrit réellement sur la partition cible. Elle n'est pas une étape de validation de la release.

```powershell
.\scripts\Restore-RestorBootManager.ps1 `
  -BackupPath "C:\RESTOR-PC-BACKUP\v1.1.0-GOLDEN-..." `
  -RestorBoot `
  -Apply `
  -ConfirmRestore "RESTOR-PC"
```

## CI / Validation

La validation a trois niveaux. Les niveaux 2 et 3 n'utilisent jamais le NVMe physique.

1. **Static** : syntaxe, PSScriptAnalyzer et contrôles de sûreté du dépôt.
2. **Pester offline** : fixtures synthétiques et mocks, sans disque.
3. **VHD integration** : `Restore -Apply` sur un VHDX isolé, en administrateur, hors CI.

```powershell
pwsh -NoProfile -File .\scripts\Test-Repository.ps1
pwsh -NoProfile -File .\scripts\Test-Behavior.ps1
```

PowerShell administrateur, laboratoire VHDX :

```powershell
pwsh -NoProfile -File .\scripts\Test-VirtualRestore.ps1
pwsh -NoProfile -File .\scripts\Test-VirtualRestore.ps1 -KeepLab
```

`-KeepLab` démonte le VHDX et conserve les fichiers du laboratoire. Sans ce commutateur, le dossier `test\vhd\restore-lab` est supprimé seulement si le chemin résolu est exactement celui du lab et si les tests ont réussi.

GitHub Actions : **RESTOR-PC CI** (`.github/workflows/ci.yml`). Le check requis sur `main` est `Repository validation`.

La CI ne touche jamais au matériel, ne monte pas de disque physique, ne lance pas QEMU, ne lance pas les tests marqués `VHD` et ne lance pas `Restore -Apply`.

`Write-Host` reste le canal des lignes `[OK]`, `[WARN]` et `[ERROR]`. Les noms de fonctions internes au pluriel ne sont pas renommés. Les scripts PowerShell Unicode sont en UTF-8 avec BOM, pour Windows PowerShell et PowerShell 7. Les portes bloquantes sont dans `config/PSScriptAnalyzerSettings.psd1` : catch vide, variable automatique écrasée, paramètre inutilisé.

## Automated tests

Pester 5.9.1, fixtures offline, mocks matériel.

The test suite never accesses physical disks.

Le laboratoire VHDX est décrit dans `docs/VIRTUAL-RESTORE-LAB.md`. Le détail des tests offline est dans `tests/README.md`.

## Releases

- [v1.2.0](docs/releases/v1.2.0.md)
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
