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
| 6 | `gravel` | [Ground108](https://ambientcg.com/view?id=Ground108) |
| 7 | `snow` | [Snow006](https://ambientcg.com/view?id=Snow006) |

L'index est celui de `TerrainGenerator.Layer` : c'est un contrat avec le
shader, pas un ordre d'affichage.

## Comment les chercher

La recherche d'ambientCG porte sur les **tags**, pas sur le sens. Les mots du
vocabulaire du relief n'y renvoient rien du tout : `scree`, `talus`, `shale`,
`pebbles`, `rocky ground` donnent zéro résultat. Les tags productifs sont
`rubble`, `debris`, `riverbed`, `scattered`, `uneven`.

C'est ce qui explique le premier choix de `gravel`, **Gravel022** : un tapis
dense et régulier de gravillons, c'est-à-dire du béton désactivé de trottoir.
Il ne partageait aucune teinte avec la terre ou la pierre qui l'entourent, et
c'est ce manque de recouvrement — plus que le mélange lui-même — qui faisait
ressortir la moindre limite de biome.

**Ground108** le remplace : minéral, à fragments de tailles variées, dans le
même brun-gris que `dirt`. La couche sert à trois choses à la fois (fond de
mer profonde, lit de rivière, éboulis), d'où le choix d'une matière tagguée
`riverbed` **et** `rubble`.

L'import se fait avec `scripts/import_texture.gd`, qui applique les qualités
d'encodage ci-dessous et recalcule la rugosité moyenne.

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
