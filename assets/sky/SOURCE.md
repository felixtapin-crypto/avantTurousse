# Ciel

`atmosphere.gdshader` et `moon.png` viennent du projet **terrain-3d** de
Guillaume (`C:\Users\gdelr\Documents\Godot\terrain-3d`), respectivement
`shaders/atmosphere.gdshader` et `assets/moon/moon.png`. Le shader y est
désigné comme « Sky++ » ; **sa licence amont reste à confirmer** avant toute
diffusion du jeu.

Il remplace le ciel stylisé de GDQuest, qui était bien plus pauvre : pas de
lunes, pas de planètes, et des nuages plats.

## Ce que fait le shader

C'est un `shader_type sky`, donc il ne dépend d'aucune géométrie :

- **Atmosphère** — diffusion de Rayleigh, de Mie et absorption par l'ozone,
  intégrées le long du rayon sur une atmosphère sphérique (rayon planétaire
  6 371 km, épaisseur 100 km). C'est de là que viennent le bleu du zénith et le
  rougeoiement du couchant : rien n'est interpolé entre deux couleurs réglées à
  la main.
- **Cumulus** — ray-marching dans deux textures de bruit 3D (forme et détail),
  avec une passe d'éclairage séparée.
- **Cirrus** — une couche haute, étirée et distordue par deux autres bruits.
- **Astres** — jusqu'à trois disques texturés, plus le soleil.

## Les lumières sont l'interface

Le shader lit les `DirectionalLight3D` de la scène sous les noms
`LIGHT0..LIGHT3` :

| Lumière | Rôle | `sky_mode` |
|---|---|---|
| LIGHT0 | Soleil | celui de la scène |
| LIGHT1 | Lune | `LIGHT_AND_SKY` — elle éclaire un peu |
| LIGHT2 | Planète | `SKY_ONLY` |
| LIGHT3 | Géante | `SKY_ONLY` |

`sky_cycle.gd` crée les trois derniers **dans cet ordre**, qui est le seul
moyen pour le shader de les distinguer. `light_angular_distance` donne leur
taille apparente ; `SKY_ONLY` fait que l'énergie d'une planète ne sert qu'à
rendre son disque visible, sans quoi on aurait trois soleils.

Les trois astres partagent `moon.png` : c'est `moon_uv_x_offset` qui décale la
lecture et leur donne trois visages différents.

## Ce qui est généré plutôt que versionné

Les bruits (formes de nuages, détail, cirrus et leur distorsion) sont
construits en code par `sky_cycle.gd`, avec les valeurs relevées dans
`materials/sky_material.tres` du projet d'origine.

**Le fond d'étoiles manque.** C'est `assets/cubemaps/stars.hdr`, 48 Mo, trop
lourd pour ce dépôt. L'uniforme `stars_hdr` est déclaré `hint_default_black` :
sans lui le ciel de nuit est simplement dépourvu d'étoiles, et les lunes et
planètes restent là. Pour le récupérer, copier le fichier et son `.import`,
puis renseigner `stars_hdr` dans `_build_sky_material`.
