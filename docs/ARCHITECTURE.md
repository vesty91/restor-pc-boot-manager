# Architecture

## Architecture actuelle

```text
Firmware UEFI
   |
   v
NVMe RESTOR-PC
   |
   +-- Partition 1 : MSR             16 Mio
   +-- Partition 2 : RESTOR-BOOT      1 Gio  FAT32 / ESP
   |      EFI/BOOT/BOOTX64.EFI        <- rEFInd
   |      EFI/BOOT/refind.conf
   |      EFI/BOOT/themes/restor-pc/
   |      EFI/TOOLS/MEMTEST/mt86plus.efi
   |
   +-- Partition 3 : CODE-EFI       512 Mio  FAT32 / ESP
   |      EFI/Microsoft/Boot/bootmgfw.efi
   |      BCD -> WIN CODE uniquement
   |
   +-- Partition 4 : VESTY-EFI      512 Mio  FAT32 / ESP
   |      EFI/Microsoft/Boot/bootmgfw.efi
   |      BCD -> WIN VESTY uniquement
   |
   +-- Partition 5 : RESTOR-TOOLS    64 Gio  NTFS
   |      WinPE\RescueGrid\boot.wim
   |      RescueGrid\
   |
   +-- Partition 6 : RESCUE-EFI     512 Mio  FAT32 / ESP
   |      EFI/Microsoft/Boot/bootmgfw.efi
   |      BCD -> RESTOR-PC RESCUEGRID
   |
   +-- Partition 7 : LOCKPICK-EFI     1 Gio  FAT32 / ESP
   |      EFI/BOOT/BOOTX64.EFI        <- chargeur original Lockpick
   |      sources/boot.wim
   |      Programs/Lockpick/
   |
   +-- espace non alloué                    réservé pour Linux
```

## Pourquoi trois partitions EFI

rEFInd ne présente pas séparément deux entrées Windows résidant dans un unique BCD Microsoft. La solution retenue fournit un BCD dédié à WIN CODE sur `CODE-EFI` et un BCD dédié à WIN VESTY sur `VESTY-EFI`.

Chaque BCD contient un seul OS avec un timeout nul. rEFInd affiche donc deux boutons Windows indépendants sans menu Microsoft intermédiaire.

## Détection rEFInd

La configuration utilise `scanfor manual`. Toutes les entrées importantes sont déclarées explicitement afin d'éviter les doublons Windows, WinRE et EFI automatiques.

## RESTOR-TOOLS

`RESTOR-TOOLS` est une partition NTFS dédiée aux ISO, WinPE et outils de dépannage. Elle ne contient pas les chargeurs EFI critiques de rEFInd.

## MemTest86+

Le chargeur x86_64 est placé sur RESTOR-BOOT sous `\EFI\TOOLS\MEMTEST\mt86plus.efi` et lancé directement par rEFInd.

## RescueGrid

`RESCUE-EFI` contient uniquement le gestionnaire de démarrage Windows de RescueGrid. Le `boot.wim` reste sur `RESTOR-TOOLS`.

## Lockpick

`LOCKPICK-EFI` reçoit la copie intégrale de `Lockpick.iso`. rEFInd chaîne directement `\EFI\BOOT\BOOTX64.EFI` sur le volume `LOCKPICK-EFI`. Le BCD et le WIM d'origine ne sont pas reconstruits.

## Linux futur

L'espace restant est volontairement laissé non alloué pour une installation Linux ultérieure.
