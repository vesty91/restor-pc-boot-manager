# Lockpick — restauration sur RESTOR-PC Boot Manager

## Important : `Lockpick.iso` n'est pas inclus dans ce dépôt

Le fichier **`Lockpick.iso` n'est volontairement pas versionné ni distribué avec le projet `restor-pc-boot-manager`**.

Le dépôt contient uniquement l'intégration nécessaire pour démarrer Lockpick depuis le NVMe RESTOR-PC :

- la configuration rEFInd ;
- l'icône `lockpick.png` ;
- le script `scripts/Install-Lockpick.ps1` ;
- les contrôles dans `scripts/Test-RestorBootManager.ps1` ;
- la documentation de l'architecture.

Le média `Lockpick.iso` doit être fourni séparément par l'utilisateur à partir de sa propre copie légitime.

> Ne pas ajouter `Lockpick.iso` au dépôt GitHub public.

---

## Architecture utilisée

Lockpick est installé sur une partition EFI dédiée :

```text
RESTOR-BOOT      -> rEFInd
CODE-EFI         -> WIN CODE
VESTY-EFI        -> WIN VESTY
RESTOR-TOOLS     -> RescueGrid / outils / ISO
RESCUE-EFI       -> RescueGrid
LOCKPICK-EFI     -> média Lockpick complet
```

Le démarrage suit cette chaîne :

```text
Firmware UEFI
  -> RESTOR-BOOT
  -> rEFInd
  -> LOCKPICK
  -> LOCKPICK-EFI
  -> \EFI\BOOT\BOOTX64.EFI
  -> WinPE Lockpick
  -> \Programs\Lockpick
```

Le contenu complet de l'ISO est conservé, car Lockpick utilise aussi des fichiers situés hors de `boot.wim`, notamment dans :

```text
\Programs\Lockpick\
```

---

# Restaurer Lockpick

## 1. Récupérer `Lockpick.iso`

Récupérer votre copie de `Lockpick.iso` puis la placer ici :

```text
C:\Users\Jeux\Restor-PC-Workspace\Lockpick.iso
```

Le workspace doit par exemple contenir :

```text
C:\Users\Jeux\Restor-PC-Workspace\
├── Lockpick.iso
├── restor-pc-boot-manager\
└── restor-pc-rescuegrid\
```

---

## 2. Vérifier le SHA-256 de l'ISO

Dans PowerShell :

```powershell
Get-FileHash "C:\Users\Jeux\Restor-PC-Workspace\Lockpick.iso" -Algorithm SHA256
```

La version validée lors de l'intégration initiale avait pour SHA-256 :

```text
9D1AFC1D80B1F9FCB1CE530C292FB429E3E4E6E791CE5205019A2A233D1FD9DC
```

Si votre ISO a un hash différent, **ne contournez pas simplement le contrôle**. Vérifiez d'abord qu'il s'agit bien d'une autre version légitime de Lockpick, puis fournissez explicitement son nouveau SHA-256 au script.

---

## 3. Ouvrir PowerShell en administrateur

Puis se placer dans le dépôt :

```powershell
Set-Location "C:\Users\Jeux\Restor-PC-Workspace\restor-pc-boot-manager"
```

---

## 4. Lancer la restauration

Avec l'ISO validé initialement :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\scripts\Install-Lockpick.ps1" `
  -ISOPath "C:\Users\Jeux\Restor-PC-Workspace\Lockpick.iso"
```

Pour une autre version de l'ISO dont vous avez vérifié le SHA-256 :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\scripts\Install-Lockpick.ps1" `
  -ISOPath "C:\Users\Jeux\Restor-PC-Workspace\Lockpick.iso" `
  -ExpectedSha256 "VOTRE_SHA256_ICI"
```

---

## Ce que fait `Install-Lockpick.ps1`

Le script :

1. vérifie les droits administrateur ;
2. identifie le NVMe RESTOR-PC avec son modèle et son numéro de série configurés ;
3. vérifie la présence des partitions RESTOR-PC attendues ;
4. vérifie le SHA-256 de `Lockpick.iso` ;
5. crée une sauvegarde `pre-lockpick` ;
6. monte l'ISO ;
7. crée `LOCKPICK-EFI` si cette partition n'existe pas encore ;
8. réutilise `LOCKPICK-EFI` si elle existe déjà et est conforme ;
9. copie le contenu complet de l'ISO ;
10. compare les SHA-256 des fichiers essentiels ;
11. installe l'icône `lockpick.png` ;
12. ajoute ou met à jour l'entrée `LOCKPICK` dans rEFInd ;
13. vérifie que les autres environnements de boot n'ont pas été modifiés ;
14. lance `Test-RestorBootManager.ps1` ;
15. retire les montages temporaires et démonte l'ISO.

Le script ne doit pas modifier les BCD de :

```text
CODE-EFI
VESTY-EFI
RESCUE-EFI
```

---

# Cas de restauration

## `LOCKPICK-EFI` existe mais Lockpick ne démarre plus

Replacez le bon `Lockpick.iso` dans le workspace et relancez :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\scripts\Install-Lockpick.ps1" `
  -ISOPath "C:\Users\Jeux\Restor-PC-Workspace\Lockpick.iso"
```

Le script compare les fichiers principaux avec l'ISO et recopie le média lorsque nécessaire.

---

## `LOCKPICK-EFI` a été supprimée

Le script peut recréer la partition depuis l'espace non alloué **uniquement si la structure RESTOR-PC attendue est reconnue** et que les contrôles de sécurité passent.

Ne créez pas manuellement une partition au hasard et ne modifiez pas les autres partitions pour libérer de l'espace.

---

## L'entrée `LOCKPICK` a disparu de rEFInd

Relancer `Install-Lockpick.ps1` permet également de remettre l'entrée :

```text
menuentry "LOCKPICK" {
    icon \EFI\BOOT\themes\restor-pc\assets\lockpick.png
    volume "LOCKPICK-EFI"
    loader \EFI\BOOT\BOOTX64.EFI
}
```

---

# Vérification après restauration

Depuis PowerShell administrateur :

```powershell
Set-Location "C:\Users\Jeux\Restor-PC-Workspace\restor-pc-boot-manager"

.\scripts\Test-RestorBootManager.ps1 -DiskNumber 3
```

> Le numéro de disque peut changer. Avant d'utiliser `-DiskNumber`, vérifiez toujours le disque avec `Get-Disk`.

Le test doit notamment valider :

```text
WIN CODE
WIN VESTY
MEMTEST86+
RESCUEGRID
LOCKPICK
```

ainsi que les fichiers Lockpick essentiels :

```text
EFI\BOOT\BOOTX64.EFI
EFI\Microsoft\Boot\BCD
boot\BCD
boot\boot.sdi
sources\boot.wim
Programs\Lockpick\Lockpick.exe
```

Le dernier contrôle reste un **test de démarrage physique** : redémarrer le PC, sélectionner `LOCKPICK` dans rEFInd et vérifier que l'environnement démarre correctement.

---

# Sauvegardes

Avant chaque réinstallation, le script crée une sauvegarde dans :

```text
C:\RESTOR-PC-BACKUP\<timestamp>-pre-lockpick
```

Conservez également une copie privée de `Lockpick.iso` sur un support fiable (NAS, disque de sauvegarde ou clé atelier), séparément du dépôt GitHub.

---

# Git / dépôt public

Le dépôt GitHub doit contenir le **code d'intégration**, mais pas le média tiers lui-même.

Il est recommandé d'avoir au minimum cette règle dans `.gitignore` :

```gitignore
Lockpick.iso
```

Ainsi, le projet reste reproductible sans redistribuer le média Lockpick.
