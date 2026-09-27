# Tests offline

La suite ne touche aucun disque physique, aucune partition EFI et aucun BCD vivant.

## Principes

- Les fixtures sont creees dans `$TestDrive`.
- `C:\RESTOR-PC-BACKUP` n'est pas utilise.
- Les BCD, `boot.wim` et chargeurs EFI de fixture sont des fichiers texte synthetiques.
- `refind.conf` et `win_vesty.png` sont copies depuis le depot au moment du test.
- Restore est execute avec des mocks Pester. `Get-Disk`, `Get-Partition`, `Get-Volume` et les commandes d'ecriture jettent `REAL HARDWARE ACCESS BLOCKED BY TEST` si le code sort du bac a sable.
- `RESTOR_PC_INLINE_TEST=1` est pose uniquement par l'harnais. Sans cette variable, les scripts appellent toujours `exit`.

## Lancement

Tests comportementaux :

```powershell
pwsh -NoProfile -File .\scripts\Test-Behavior.ps1
```

Validation complete, y compris le check requis `Repository validation` :

```powershell
pwsh -NoProfile -File .\scripts\Test-Repository.ps1
```

Pester est pine dans `config/ToolVersions.psd1`.
