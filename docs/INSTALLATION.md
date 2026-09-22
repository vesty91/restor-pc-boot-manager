# Installation contrôlée

## 1. Sauvegardes préalables

- Sauvegarder les données importantes des deux Windows.
- Conserver une clé d'installation Windows/WinRE.
- Noter les clés de récupération BitLocker.
- Exporter l'état BCD :

```cmd
bcdedit /enum all > "%USERPROFILE%\Desktop\bcd-before-restor-pc.txt"
```

## 2. Identifier le NVMe

PowerShell administrateur :

```powershell
.\scripts\Get-RestorBootInventory.ps1 -ExportPath .\inventory.json
```

Comparer au minimum :

- numéro de disque ;
- modèle ;
- taille ;
- numéro de série ;
- indicateurs `IsBoot` et `IsSystem`.

Le disque cible ne doit contenir aucune donnée à conserver.

## 3. Télécharger rEFInd

Télécharger l'archive binaire `.zip` depuis la page officielle :

<https://www.rodsbooks.com/refind/getting.html>

Le dépôt n'intègre pas rEFInd afin de séparer clairement les licences et de vous laisser vérifier la source du binaire.

## 4. Simuler

```powershell
.\scripts\Install-RestorBootManager.ps1 `
  -DiskNumber 3 `
  -RefindArchive C:\Temp\refind-bin-0.14.2.zip `
  -WhatIf
```

## 5. Installer

```powershell
.\scripts\Install-RestorBootManager.ps1 `
  -DiskNumber 3 `
  -RefindArchive C:\Temp\refind-bin-0.14.2.zip
```

Le script demande de saisir une phrase incluant le numéro de disque et son numéro de série. Cette confirmation n'est pas contournée.

## 6. Tester avant de changer l'ordre permanent

```powershell
.\scripts\Test-RestorBootManager.ps1 -DiskNumber 3
```

Redémarrer via le menu ponctuel du firmware et sélectionner le NVMe. Ne changez l'ordre de démarrage permanent qu'après un démarrage concluant de chaque Windows.

## Résultat attendu

- fond Restor-PC 1920×1080 ;
- gros sélecteur avec icônes ;
- démarrage automatique après 8 secondes ;
- détection des chargeurs EFI Windows ;
- retour direct au firmware possible en retirant le NVMe ou via son menu de démarrage.
