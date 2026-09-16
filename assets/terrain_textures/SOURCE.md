# Textures du terrain

Source : [ambientCG](https://ambientcg.com), licence **CC0** — usage libre, y
compris commercial, sans attribution obligatoire.

| Couche | Fichier | Pack ambientCG |
|---|---|---|
| 0 | `grass` | [Ground037](https://ambientcg.com/view?id=Ground037) |
| 1 | `dirt` | [Ground048](https://ambientcg.com/view?id=Ground048) |
| 2 | `stone` | [Rock030](https://ambientcg.com/view?id=Rock030) |
| 3 | `stone_dark` | [Rock035](https://ambientcg.com/view?id=Rock035) |
| 4 | `sand` | [Ground057](https://ambientcg.com/view?id=Ground057) |
| 5 | `sand_pale` | [Ground054](https://ambientcg.com/view?id=Ground054) |
| 6 | `gravel` | [Gravel022](https://ambientcg.com/view?id=Gravel022) |
| 7 | `snow` | [Snow006](https://ambientcg.com/view?id=Snow006) |

L'index est celui de `TerrainGenerator.Layer` : c'est un contrat avec le
shader, pas un ordre d'affichage.

## Ce qui est versionné

Deux cartes par matière, en 1024², ré-encodées en JPEG (qualité 82 pour la
couleur, 88 pour la normale) — 6,5 Mo au total au lieu de 167 Mo pour les
archives d'origine :

- `*_color.jpg` — albédo, sans éclairage ni occlusion cuits ;
- `*_normal.jpg` — normales, **convention OpenGL** (`NormalGL` chez ambientCG).
  La convention DirectX inverserait le vert et creuserait les reliefs au lieu
  de les faire ressortir.

## Ce qui ne l'est pas

La **rugosité** : les cartes d'ambientCG sont assez uniformes par matière, et
un troisième tableau de textures doublerait le nombre de lectures dans le
shader. Sa moyenne a été mesurée sur chaque carte et figée en constante dans
`terrain_textures.gd`, avec la valeur relevée en commentaire.

L'**occlusion ambiante** et le **déplacement** ne sont pas repris : le terrain
a son propre éclairage, et une ombre cuite se retrouverait à contresens sur la
moitié des versants.
