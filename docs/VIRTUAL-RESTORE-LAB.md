# Laboratoire de restauration VHDX

Ce laboratoire execute le script de production `scripts/Restore-RestorBootManager.ps1` avec `-Apply` et `-ConfirmRestore "RESTOR-PC"` contre un disque virtuel. Il ne remplace pas les tests offline de la phase 5. Ceux-ci restent le filet execute par GitHub Actions, sans droit administrateur et sans disque.

## Objectif

Prouver que le moteur de restauration ecrit vraiment des fichiers, dans cet ordre :

1. validation du manifeste ;
2. identification du disque ;
3. selection des partitions ;
4. copie PRE-RESTORE ;
5. copie du Golden Backup.

La cible est un VHDX dynamique d'environ 4 Gio, monte par Windows, avec cinq volumes FAT32 : RESTOR-BOOT, CODE-EFI, VESTY-EFI, RESCUE-EFI et LOCKPICK-EFI. Le libelle FAT de Lockpick est `LOCKPICK-EF`.

## Securite

`Assert-RestorVirtualLabDisk` associe le disque a `Get-DiskImage -ImagePath` du VHDX avant `Initialize-Disk`, `New-Partition`, `Format-Volume` ou `Add-PartitionAccessPath`. Le disque doit avoir `IsBoot=false` et `IsSystem=false`. Le modele `SAMSUNG MZVLB256HAHQ-000L2` est refuse. `Clear-Disk` et `diskpart clean` ne sont pas utilises.

Le restore de production n'a pas de parametre pour desactiver ses controles. Le test lui presente un disque synthetique GPT/NVMe (`RESTOR-PC TEST NVME` / `TEST_SERIAL_0001`) via un mock, tout en faisant pointer `robocopy` vers les lettres du VHDX. `Get-Disk` n'est donc jamais utilise pour choisir le NVMe physique.

`-PreRestoreRoot` a pour defaut `C:\RESTOR-PC-BACKUP`. Le laboratoire le redirige sous `test\vhd\restore-lab`. Une racine, un chemin vide, Windows ou System32 sont refuses.

`-KeepExisting` reutilise un VHDX dont les cinq volumes FAT32 sont deja ceux du laboratoire. Il ne cree pas, ne formate pas et n'initialise pas ce disque. Un layout incomplet est refuse. Sans ce commutateur, un VHDX deja present est remplace.

## Lancement

PowerShell 7, en administrateur. Hyper-V (`New-VHD`) ou `qemu-img.exe` doit deja etre present. Le script n'active aucune fonctionnalite Windows.

```powershell
pwsh -NoProfile -File .\scripts\Test-VirtualRestore.ps1
```

Pour inspecter le resultat apres coup :

```powershell
pwsh -NoProfile -File .\scripts\Test-VirtualRestore.ps1 -KeepLab
```

Le VHDX est demonte dans les deux cas. `-KeepLab` conserve le fichier, le Golden synthetique, le PRE-RESTORE et `RESTORE-REPORT.json`.

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
