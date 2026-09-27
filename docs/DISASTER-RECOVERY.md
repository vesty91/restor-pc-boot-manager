# Disaster Recovery — RESTOR-PC Boot Manager

Ce guide sépare trois situations. Les outils ne se substituent pas les uns aux autres.

## Distinction logicielle / format Golden

- Version logicielle du dépôt : **v1.3.0**
- Format interne du Golden Backup : peut rester **1.1.0** (`$BackupVersion` dans `Backup-RestorBootManager.ps1`)

## CAS A — Le boot fonctionne

Les partitions RESTOR-PC existent. Le menu rEFInd démarre.

1. Vérifier le Golden Backup : `Test-RestorGoldenBackup.ps1`
2. Dry-run : `Restore-RestorBootManager.ps1 -BackupPath ... -AllEfi`
3. Apply uniquement avec `-Apply -ConfirmRestore "RESTOR-PC"`

Le restore exige un layout existant. Il ne recrée pas le GPT.

## CAS B — Partitions présentes, fichiers corrompus

Même outil que le CAS A. Le PRE-RESTORE conserve une copie avant écriture. La vérification post-restore SHA256 peut marquer `FAILED` sans rollback automatique : utiliser le dossier `PRE-RESTORE-*` pour récupération manuelle.

## CAS C — NVMe remplacé / disque vierge

Utiliser **uniquement** :

```powershell
.\scripts\New-RestorRecoveryDisk.ps1 `
  -DiskNumber <N> `
  -BackupPath <Golden> `
  -ExpectedModel <exact> `
  -ExpectedSerial <exact> `
  -Apply `
  -ConfirmRebuild "REBUILD-RESTOR-PC"
```

### Avertissement

`New-RestorRecoveryDisk.ps1` est **destructif** sur un disque vierge (RAW ou GPT sans partition données). Il **refuse** :

- disque système (`IsSystem`)
- disque de démarrage (`IsBoot`)
- disque déjà partitionné (une partition données suffit)
- identité modèle/série incorrecte
- confirmation autre que `REBUILD-RESTOR-PC` (comparaison `-ceq`)

Il **n'utilise pas** `Clear-Disk` ni `diskpart clean`. Il ne nettoie pas un disque déjà peuplé.

L'intégrité complète du Golden Backup est vérifiée **avant** tout `Initialize-Disk`.

## Recovery Media

Staging autonome (sans Golden embarqué) :

```powershell
.\scripts\Build-RestorRecoveryMedia.ps1
```

Puis `artifacts\recovery-media\staging\Start-RestorRecovery.ps1`.

## Limites

- La double integrity gate réduit TOCTOU ; le filesystem n'est pas atomique.
- SHA256 = intégrité, pas authentification si un attaquant contrôle manifeste + `BACKUP-INFO`.
- Post-restore détecte une mauvaise copie ; pas de rollback automatique.
- Le rebuild physique sur le NVMe actuel n'a **pas** été exécuté dans les labs.
- Les tests VHDX ne remplacent pas tous les comportements firmware.
