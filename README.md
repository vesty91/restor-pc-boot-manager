# Restor-PC Boot Manager

Boot manager UEFI graphique basé sur [rEFInd](https://www.rodsbooks.com/refind/) et installé sur un disque NVMe dédié.

Le projet cible d'abord deux installations Windows existantes. Linux pourra être ajouté plus tard sans reconstruire le support : rEFInd analyse les autres partitions EFI au démarrage.

## Principes de sécurité

- Le NVMe dédié contient uniquement le chargeur et son thème.
- Les partitions Windows existantes ne sont ni formatées ni modifiées.
- Le script refuse un disque marqué `Boot` ou `System` par Windows.
- Toute initialisation exige une confirmation contenant le numéro du disque et son numéro de série.
- Le reste du NVMe demeure non alloué par défaut.
- La première exécution recommandée est l'inventaire en lecture seule.

> [!CAUTION]
> `Install-RestorBootManager.ps1` initialise le disque explicitement sélectionné et efface tout ce qu'il contient. Vérifiez le modèle, la taille et le numéro de série avant confirmation.

## Pré-requis

- PC x64 démarré en mode UEFI ;
- Windows 10/11 ;
- PowerShell 5.1 ou 7 exécuté en administrateur ;
- NVMe dédié ;
- archive binaire officielle rEFInd `.zip` téléchargée depuis la [page officielle](https://www.rodsbooks.com/refind/getting.html) ;
- Secure Boot désactivé pour le premier test. Sa prise en charge sera traitée séparément avec Shim/MOK.

## Démarrage rapide

### 1. Inventaire sans modification

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\Get-RestorBootInventory.ps1 -ExportPath .\inventory.json
```

Repérez le NVMe dédié avec son `DiskNumber`, son modèle, sa taille et son numéro de série.

### 2. Simulation de l'installation

```powershell
.\scripts\Install-RestorBootManager.ps1 `
  -DiskNumber 3 `
  -RefindArchive "$env:USERPROFILE\Downloads\refind-bin-0.14.2.zip" `
  -WhatIf
```

### 3. Installation réelle

Retirez `-WhatIf` uniquement après validation du bon disque :

```powershell
.\scripts\Install-RestorBootManager.ps1 `
  -DiskNumber 3 `
  -RefindArchive "$env:USERPROFILE\Downloads\refind-bin-0.14.2.zip"
```

Le script crée une ESP FAT32 de 1 Gio, copie rEFInd et le thème dans le chemin de secours UEFI `EFI\BOOT\BOOTX64.EFI`, puis laisse le reste du NVMe non alloué.

### 4. Validation

```powershell
.\scripts\Test-RestorBootManager.ps1 -DiskNumber 3
```

Redémarrez ensuite via le menu de démarrage ponctuel de la carte mère (`F11`, `F12`, `Esc` selon le constructeur) et choisissez le NVMe Restor-PC.

## Arborescence

```text
scripts/
  Get-RestorBootInventory.ps1    Diagnostic en lecture seule
  Install-RestorBootManager.ps1  Initialisation et installation contrôlées
  Test-RestorBootManager.ps1     Validation des fichiers EFI
theme/restor-pc/
  theme.conf                     Configuration graphique rEFInd
  assets/                        Sources SVG et fichiers PNG générés
docs/
  ARCHITECTURE.md
  INSTALLATION.md
  RECOVERY.md
```

## État du projet

Version initiale : boot manager externe autonome pour deux Windows, thème noir métallique rouge/violet, ajout futur de Linux prévu.

## Licence

Les scripts et le thème de ce dépôt sont distribués sous licence MIT. rEFInd n'est pas inclus et conserve sa propre licence.
