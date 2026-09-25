# Restor-PC Boot Manager

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
   +-- espace libre                 -> Linux plus tard
```

Le menu rEFInd affiche actuellement : **WIN CODE**, **WIN VESTY** et **MEMTEST86+**.

WIN CODE et WIN VESTY possèdent chacun leur propre partition EFI et leur propre BCD avec `timeout 0`. Le menu bleu Windows intermédiaire n'est donc plus nécessaire.

## Thème

Le thème Restor-PC utilise un fond personnalisé, des icônes 176×176 dédiées et une sélection néon rouge/violet.

```text
theme/restor-pc/assets/win_code.png
theme/restor-pc/assets/win_vesty.png
theme/restor-pc/assets/memtest86plus.png
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
```

### Validation

```powershell
.\scripts\Test-RestorBootManager.ps1 -DiskNumber 3
```

### Mise à jour du menu installé

```powershell
.\scripts\Update-RestorBootMenu.ps1 -DiskNumber 3
```

### Sauvegarde

```powershell
.\scripts\Backup-RestorBootManager.ps1 -DiskNumber 3 -DestinationRoot C:\RESTOR-PC-BACKUP
```

## Sécurité

> [!CAUTION]
> Les scripts d'installation initiale peuvent modifier ou effacer un disque. Vérifiez toujours modèle, taille, numéro de série et numéro de disque avant toute opération destructive.

Le NVMe RESTOR-PC peut apparaître `IsSystem=True` une fois qu'il est réellement utilisé pour amorcer rEFInd. Les scripts de maintenance ne doivent donc pas considérer ce seul indicateur comme une anomalie.

## MemTest86+

Le binaire MemTest86+ n'est pas inclus dans le dépôt. Utilisez le binaire officiel x86_64 et installez-le sous `EFI\TOOLS\MEMTEST\mt86plus.efi`.

## Licence

Les scripts et le thème de ce dépôt sont distribués sous licence MIT. rEFInd et MemTest86+ conservent leurs licences respectives.
