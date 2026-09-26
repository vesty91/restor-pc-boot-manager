# Chargeur rEFInd local

Le dépôt ne redistribue pas `refind_x64.efi`. rEFInd est publié sous licence GPL-3, distincte de la licence MIT de ce projet.

1. Téléchargez l'archive officielle rEFInd 0.14.2 depuis le site de son auteur.
2. Extrayez le dossier `refind`.
3. Copiez-le vers :

```text
bootloader\refind\
  refind_x64.efi
  drivers_x64\
  tools_x64\
  icons\
```

Le banc QEMU copie ce binaire dans l'image virtuelle `test\restor-boot.img` sous `EFI\BOOT\BOOTX64.EFI`. Il ne lit pas et ne modifie pas le rEFInd installé sur RESTOR-BOOT.

Le hash attendu de `refind_x64.efi` 0.14.2 x64 est :

```text
EAC079520D3D263B652DCC5330182CCAF42A1D47B5540DBFC545F3EB145A7E74
```
