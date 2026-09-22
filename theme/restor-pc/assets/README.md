# Assets

Les fichiers SVG sont les sources modifiables. Les PNG correspondants sont ceux chargés par rEFInd.

- `background.png` : 1920×1080
- `os_windows.png` : 256×256
- `os_linux.png` : 256×256, prévu pour l'ajout futur de Linux
- `selection_big.png` : sélecteur principal
- `selection_small.png` : sélecteur des outils

Pour régénérer les PNG avec ImageMagick :

```bash
convert background.svg background.png
convert os_windows.svg os_windows.png
convert os_linux.svg os_linux.png
convert selection_big.svg selection_big.png
convert selection_small.svg selection_small.png
```
