# Golden Backup et reprise après incident

Le Golden Backup copie le boot manager RESTOR-PC sans modifier le NVMe. Le numéro de disque n'est qu'une information du moment. L'identité exigée est le modèle `SAMSUNG MZVLB256HAHQ-000L2` et le numéro de série `0025_3881_91C0_0621`, normalisé avec `Trim()` puis `TrimEnd('.')`.

`PARTITION-LAYOUT.json` décrit les partitions. Il ne sert pas à les recréer.

## Sauvegarde

```powershell
.\scripts\Backup-RestorBootManager.ps1
```

Le dossier créé est `C:\RESTOR-PC-BACKUP\v1.1.0-GOLDEN-YYYYMMDD-HHMMSS\`. Un backup précédent n'est jamais écrasé.

Le script monte en lecture les volumes qui n'ont pas de lettre, avec R, S, T, W, Z ou L, puis retire seulement ces lettres. Les lettres déjà présentes restent.

La copie utilise `robocopy /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XJ`. Les codes 0 à 7 sont un succès. Un code supérieur ou égal à 8 est une erreur.

`bcdedit /store` sur un BCD encore monté peut changer sa date de dernière écriture, même lors d'une lecture. La sauvegarde copie d'abord le fichier, puis lance `bcdedit` uniquement sur cette copie. Ce n'est pas une corruption du contenu : lors de l'incident observé, la taille du BCD CODE-EFI est restée 28 672 octets et seul le timestamp a changé.

`RESTOR-TOOLS` n'est pas copié en entier. La sauvegarde prend `WinPE\RescueGrid`, le dossier projet `RescueGrid`, et les lanceurs trouvés à la racine. L'inventaire réel est écrit dans `RESTOR-TOOLS\INVENTORY.txt`.

`Status` dans `BACKUP-INFO.json` vaut `VALID` seulement si l'identité NVMe, les cinq ESP, les cinq entrées rEFInd, le hash WIN VESTY et un arbre Git propre sont confirmés. Sinon le statut est `WARNING` ou `FAILED`.

`BACKUP-INFO.json` est écrit après le manifeste et contient `ManifestSha256`, le SHA256 du fichier `Manifests\SHA256-MANIFEST.txt`. Il n'est pas lui-même une ligne du manifeste : ce hash l'authentifie.

## Vérification

```powershell
.\scripts\Test-RestorGoldenBackup.ps1 -BackupPath "C:\RESTOR-PC-BACKUP\v1.1.0-GOLDEN-..."
```

Le script recalcule chaque SHA256 du manifeste. La dernière ligne est `[OK] GOLDEN BACKUP VALID` ou `[ERROR] GOLDEN BACKUP INVALID`.

## Restauration

Sans les deux paramètres d'écriture, la commande reste une simulation :

```powershell
.\scripts\Restore-RestorBootManager.ps1 -BackupPath "C:\RESTOR-PC-BACKUP\v1.1.0-GOLDEN-..." -RestorBoot
```

Les cibles sont indépendantes : `-RestorBoot`, `-CodeEfi`, `-VestyEfi`, `-RescueEfi`, `-LockpickEfi`, `-AllEfi`. `-RestorBoot` ne touche pas les autres ESP.

L'écriture réelle exige les deux paramètres. `ConfirmRestore` est comparé avec `-ceq` : la valeur doit être exactement `RESTOR-PC`. `restor-pc` ne suffit pas. `-Apply` seul ne suffit pas.

```powershell
.\scripts\Restore-RestorBootManager.ps1 `
  -BackupPath "C:\RESTOR-PC-BACKUP\v1.1.0-GOLDEN-..." `
  -RestorBoot `
  -Apply `
  -ConfirmRestore "RESTOR-PC"
```

`-PreRestoreRoot` choisit le dossier parent du pré-backup. Le défaut est `C:\RESTOR-PC-BACKUP`. Un chemin vide, une racine de lecteur, `Windows` ou `System32` sont refusés. Le laboratoire VHD redirige ce paramètre sous `test\vhd\restore-lab`. En production, le défaut n'a pas changé.

Avant d'écrire, le script vérifie l'administrateur, le modèle, le numéro de série, le GPT, le hash du fichier `SHA256-MANIFEST.txt` contre `ManifestSha256`, le statut `VALID`, puis la taille et le type GPT de la partition existante. Il ne recalcule pas le hash de chaque fichier de `ESP\`. Ce contrôle fichier par fichier appartient à `Test-RestorGoldenBackup.ps1`, à lancer avant `-Apply`. Lors de l'écriture, `Restore-RestorBootManager.ps1` crée `C:\RESTOR-PC-BACKUP\PRE-RESTORE-YYYYMMDD-HHMMSS\` et abandonne si cette copie échoue. La copie Golden n'est lancée qu'après ce pré-backup.

Cette version ne fait pas `Clear-Disk`, `Initialize-Disk`, `Remove-Partition`, `Resize-Partition`, `New-Partition`, `Format-Volume`, `diskpart clean`, `bcdboot` ni `bootrec`.

## Compatibilité du Golden Backup v1.1.0

v1.2.0 reste compatible avec un Golden Backup valide créé sous v1.1.0. `$BackupVersion` reste `1.1.0`. Les dossiers `C:\RESTOR-PC-BACKUP\v1.1.0-GOLDEN-...` ne sont pas renommés et aucun nouveau Golden Backup réel n'est fabriqué pour cette release.

La restauration accepte ce backup tant que :

- `BACKUP-INFO.json` a le statut `VALID` ;
- `ManifestSha256` correspond au fichier `SHA256-MANIFEST.txt` ;
- la structure requise est présente.

La correspondance de chaque fichier avec son empreinte n'est pas refaite par `Restore-RestorBootManager.ps1`. Elle est le résultat de `Test-RestorGoldenBackup.ps1`.

v1.2.0 ne recrée toujours pas un GPT perdu.

## Tests

La suite offline, lancée par `scripts/Test-Repository.ps1` et `scripts/Test-Behavior.ps1`, vérifie le dry-run, la confirmation et les sauvegardes synthétiques sans disque physique.

L'écriture réelle de `Restore-RestorBootManager.ps1` est prouvée à part, sur un VHDX isolé, par `scripts/Test-VirtualRestore.ps1`. Ce test n'est pas exécuté par GitHub Actions. Voir `docs/VIRTUAL-RESTORE-LAB.md`.

## Partition EFI absente

Si une partition n'existe plus, la restauration des fichiers est refusée. Il faut reconstruire le partitionnement GPT à la main, avec le même modèle, le même numéro de série et les tailles documentées dans `Metadata\PARTITION-LAYOUT.json`, puis relancer une restauration de fichiers. Le script ne crée pas la partition.

## NVMe complet hors service

1. Installer un NVMe de remplacement.
2. Vérifier son modèle et son numéro de série avant toute initialisation. Le Golden Backup décrit l'ancien disque ; il ne doit pas être appliqué à un autre disque par erreur.
3. Recréer manuellement le GPT : MSR 16 Mio, puis RESTOR-BOOT 1 Gio, CODE-EFI 512 Mio, VESTY-EFI 512 Mio, RESTOR-TOOLS 64 Gio, RESCUE-EFI 512 Mio, LOCKPICK-EFI 1 Gio. Laisser le reste non alloué.
4. Formater les volumes avec les libellés d'origine. Le libellé FAT de Lockpick tient en 11 caractères : `LOCKPICK-EF`. Le nom GPT doit rester `LOCKPICK-EFI`.
5. Vérifier le nouveau Golden Backup avec `Test-RestorGoldenBackup.ps1`.
6. Restaurer les fichiers cible par cible, avec `-Apply` et `-ConfirmRestore RESTOR-PC`, seulement après le pré-backup.

Le repartitionnement n'est pas automatisé.
