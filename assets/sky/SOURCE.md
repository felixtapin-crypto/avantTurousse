# Ciel stylisé

`stylized_sky.gdshader` et `shooting_star_sampler.png` viennent de
[godot-4-stylized-sky](https://github.com/gdquest-demos/godot-4-stylized-sky)
de **GDQuest**, sous licence **MIT** (voir `LICENSE-stylized-sky.txt`). Le
shader est repris tel quel, sans modification.

C'est un `shader_type sky` : il ne dépend d'aucune géométrie et lit la
direction du soleil dans `LIGHT0_DIRECTION`, donc faire tourner la
`DirectionalLight3D` suffit à faire tourner le ciel.

Les textures dont il a besoin (formes de nuages, nuages hauts, courbe de
densité, disque solaire) sont **générées en code** par `sky_cycle.gd` plutôt
que versionnées : ce sont des bruits et des dégradés, et les recréer coûte
moins cher que de les stocker. Seule l'étoile filante est un vrai fichier.

Le cycle jour/nuit interpole les paramètres du shader entre deux jeux de
valeurs repris des matériaux d'exemple `day_sky.tres` et `night_sky.tres` du
projet d'origine.
