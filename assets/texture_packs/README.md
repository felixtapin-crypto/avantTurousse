# Packs de textures du terrain

Déposer ici un dossier par pack. Il apparaîtra automatiquement dans l'écran de
génération du monde — aucun code à modifier.

Un dossier doit contenir **huit images**, nommées d'après la matière :

```
grass  dirt  stone  stone_dark  sand  sand_pale  gravel  snow
```

En `.png`, `.jpg` ou `.webp`. Ce sont les **noms** qui décident de quelle couche
est quoi, pas l'ordre alphabétique : le tableau de textures est indexé par
`TerrainGenerator.Layer`, et se tromper d'ordre repeint le monde sans lever
d'erreur.

Un dossier auquel il manque une image est ignoré et signalé, plutôt que chargé à
moitié. Toutes les images d'un même pack doivent avoir **exactement les mêmes
dimensions** : le `Texture2DArray` l'impose.

Contraintes de fabrication (raccord, orientation, échelle de 6,7 m par
répétition) : voir le nuancier des textures à fournir.
