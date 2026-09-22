# Architecture

## Cible initiale

```text
Firmware UEFI
   |
   v
NVMe Restor-PC
  ESP FAT32 (1 Gio)
  EFI/BOOT/BOOTX64.EFI        <- rEFInd, chemin UEFI de secours
  EFI/BOOT/refind.conf
  EFI/BOOT/themes/restor-pc/
   |
   +--> Windows Boot Manager du Windows principal
   +--> Windows Boot Manager du Windows secondaire
   +--> chargeur Linux ajouté ultérieurement
```

Les systèmes d'exploitation et leurs propres partitions EFI restent sur leurs disques actuels. Si le NVMe Restor-PC est retiré, le firmware peut encore démarrer directement les chargeurs d'origine.

## Pourquoi le chemin de secours UEFI

Le fichier `EFI/BOOT/BOOTX64.EFI` est le chemin de secours standard pour une machine UEFI x64. Cette disposition rend le disque amorçable sans dépendre d'une entrée NVRAM propre à un seul PC.

## Détection des systèmes

rEFInd utilise `scanfor internal,external,manual`. Il recherche les chargeurs EFI accessibles sur tous les disques. Les doublons et son propre binaire sont exclus via `dont_scan_files`.

Avec deux ESP Windows distinctes, deux chargeurs Microsoft devraient apparaître. Si les deux Windows partagent un seul BCD/une seule ESP, rEFInd affiche un seul Windows Boot Manager, puis le menu Microsoft propose les deux Windows.

## Ajout futur de Linux

Linux doit conserver son chargeur sur l'ESP de son propre disque. rEFInd le détectera automatiquement. Aucun repartitionnement du NVMe Restor-PC n'est nécessaire.

## Secure Boot

La première version vise un test avec Secure Boot désactivé. Une activation propre nécessite une chaîne signée (par exemple Shim + enrôlement MOK) et ne doit pas être improvisée dans le script d'installation initial.
