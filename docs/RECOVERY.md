# Récupération et retour arrière

## Le menu Restor-PC ne démarre pas

1. Retirer temporairement le NVMe Restor-PC ou sélectionner `Windows Boot Manager` dans le menu UEFI.
2. Vérifier que Windows démarre normalement.
3. Réactiver le NVMe et contrôler son ESP avec `Test-RestorBootManager.ps1`.

## Écran noir ou thème illisible

Renommer temporairement `EFI\BOOT\refind.conf` depuis Windows PE, puis recopier le `refind.conf-sample` de l'archive rEFInd sous le nom `refind.conf`. Les OS ne sont pas affectés.

## Windows absent du menu

Vérifier les ESP existantes :

```powershell
.\scripts\Get-RestorBootInventory.ps1
```

Chaque Windows autonome doit normalement posséder un fichier :

```text
EFI\Microsoft\Boot\bootmgfw.efi
```

Si les deux installations partagent le même chargeur Microsoft, une seule icône rEFInd est normale : le choix final reste assuré par le BCD Windows.

## Supprimer le boot manager

Le moyen le plus sûr est de remettre `Windows Boot Manager` en premier dans l'ordre UEFI, puis de débrancher le NVMe. Aucune suppression sur les disques Windows n'est nécessaire.

> [!WARNING]
> Ne formatez jamais une partition EFI Windows pour retirer rEFInd. Dans cette architecture, rEFInd réside uniquement sur le NVMe dédié.
