# Laboratoire de restauration VHDX

Ce laboratoire execute le script de production `scripts/Restore-RestorBootManager.ps1` avec `-Apply` et `-ConfirmRestore "RESTOR-PC"` contre un disque virtuel. Il ne remplace pas les tests offline de la phase 5. Ceux-ci restent le filet execute par GitHub Actions, sans droit administrateur et sans disque.

## Objectif

Prouver que le moteur de restauration ecrit vraiment des fichiers, dans cet ordre :

1. validation du manifeste ;
2. identification du disque ;
3. selection des partitions ;
4. copie PRE-RESTORE ;
5. copie du Golden Backup.

La cible est un VHDX dynamique d'environ 4 Gio, monte par Windows, avec cinq volumes FAT32. Les tailles demandees sont environ 900 Mio pour RESTOR-BOOT et LOCKPICK, et environ 500 Mio pour CODE-EFI, VESTY-EFI et RESCUE-EFI. Les libelles FAT sont RESTOR-BOOT, CODE-EFI, VESTY-EFI, RESCUE-EFI et `LOCKPICK-EF`. Le nom GPT de Lockpick reste `LOCKPICK-EFI`. Le numero de disque Windows n'est pas une constante : il depend de la machine au moment du montage.

## Securite

`Assert-RestorVirtualLabDisk` associe le disque a `Get-DiskImage -ImagePath | Get-Disk` avant `Initialize-Disk`, `New-Partition`, `Format-Volume`, `Add-PartitionAccessPath` ou `Set-Disk`. Le disque doit exister, etre attache, avoir le meme `DiskNumber`, `IsBoot=false` et `IsSystem=false`. Le modele `SAMSUNG MZVLB256HAHQ-000L2` est refuse avec `PHYSICAL RESTOR-PC NVME BLOCKED`. `Clear-Disk` et `diskpart clean` ne sont pas utilises. Le laboratoire doit rester sous `test\vhd`. La suppression finale n'est autorisee que pour le chemin resolu `<repo>\test\vhd\restore-lab`.

Le restore de production n'a pas de parametre pour desactiver ses controles. Le test lui presente un disque synthetique GPT/NVMe (`RESTOR-PC TEST NVME` / `TEST_SERIAL_0001`) via un mock, tout en faisant pointer `robocopy` vers les lettres du VHDX. `Get-Disk` n'est donc jamais utilise pour choisir le NVMe physique.

`-PreRestoreRoot` a pour defaut `C:\RESTOR-PC-BACKUP`. Le laboratoire le redirige sous `test\vhd\restore-lab`. Une racine, un chemin vide, Windows ou System32 sont refuses.

`-KeepExisting` a trois issues. Si le VHDX est absent, ou s'il est monte mais RAW / sans partition, le layout est cree. Si les cinq volumes FAT32 EFI existent deja, avec les libelles et des tailles dans la tolerance Windows, le script les inventorie et les reutilise : pas de `Initialize-Disk`, pas de `New-Partition`, pas de `Format-Volume`. Une lettre manquante peut etre ajoutee avec `Add-PartitionAccessPath` seulement apres `Assert-RestorVirtualLabDisk`, sans reformatage. Un layout incomplet ou invalide arrete le script. Le message est `Existing VHDX layout is invalid; recreate the lab without -KeepExisting.` Il n'y a pas de reparation automatique. Sans ce commutateur, un VHDX deja present est demonte puis remplace.

## Lancement

PowerShell 7, en administrateur. Le backend prefere est `New-VHD` s'il est deja installe. Sinon le script utilise `qemu-img.exe create -f vhdx`, sans disque physique. Aucune fonctionnalite Windows n'est activee automatiquement. La validation locale de la phase 6 a utilise `New-VHD`.

```powershell
pwsh -NoProfile -File .\scripts\Test-VirtualRestore.ps1
```

Pour inspecter le resultat apres coup :

```powershell
pwsh -NoProfile -File .\scripts\Test-VirtualRestore.ps1 -KeepLab
```

`Dismount-DiskImage` est appele dans le `finally`, y compris apres un echec, puis le script verifie que l'image n'est plus attachee. `-KeepLab` conserve le fichier, le Golden synthetique, le PRE-RESTORE et `RESTORE-REPORT.json`. En cas d'echec, le laboratoire est aussi conserve, deja demonte.

## Fichiers generes

Ils restent dans `test/vhd/restore-lab/` et ne sont pas versions :

- `restor-restore-lab.vhdx`
- `golden\`
- `pre-restore\`
- `RESTORE-REPORT.json`
- `logs\`

## Comportement conserve

`robocopy` est lance avec `/E`, pas avec `/MIR`. Un fichier qui n'est pas dans le Golden Backup reste sur la partition. La restauration copie et remplace. Elle n'efface pas les fichiers hors sauvegarde.

## Limites

GitHub Actions n'execute pas ce test : le runner n'est pas administrateur et le support VHD n'est pas garanti. `scripts/Test-VirtualLabSafety.ps1` verifie seulement le code. Les tests offline restent le check `Repository validation`.
