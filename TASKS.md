# Suivi de travail et coordination

Le suivi des tâches (à faire / en cours / terminé) se fait maintenant sur le
**Project GitHub** :

**https://github.com/users/felixtapin-crypto/projects/2**

Toutes les tâches qui étaient listées ici ont été migrées en issues sur ce
board (une par tâche, avec un lien vers la section de `DESIGN.md`
correspondante quand pertinent).

## Protocole de coordination

L'objectif reste le même qu'avant : que personne ne découvre en pullant que
l'autre a retravaillé le même système en parallèle.

1. **Avant de commencer un morceau non-trivial** (un système, pas une
   correction de bug d'une ligne), passe l'issue correspondante en "In
   Progress" sur le Project et assigne-toi-la. Si aucune issue n'existe pour
   ce que tu attaques, crées-en une d'abord.
2. **Avant de toucher à un système déjà pris par quelqu'un d'autre**, ou à
   quelque chose qui touche l'architecture commune (format de sauvegarde,
   structure des voxels, code réseau), préviens-le (message, appel, peu
   importe) avant de coder, pas après.
3. Quand c'est fini (ou abandonné), ferme l'issue (ou repasse-la en "Todo"
   si abandonné), idéalement en la liant à la commit/PR correspondante.
4. Committe et pull souvent (idéalement à chaque session), surtout pour
   `DESIGN.md` — c'est le fichier qu'on modifie tous les deux, donc les
   divergences dessus doivent être résolues vite avant de diverger sur le
   code.

Fichiers particulièrement sensibles aux conflits (à ne pas éditer à deux en
même temps sans se prévenir) : les scènes `.tscn` (fusion textuelle mais
casse-tête à relire), `project.godot`, et tout futur fichier de format de
sauvegarde.

## Convention de messages de commit

Les messages de commit suivent
[Conventional Commits](https://www.conventionalcommits.org/fr/v1.0.0/) :

```
<type>(<portée facultative>): <description>
```

| Type | Quand l'utiliser |
|------|------------------|
| `feat` | nouvelle fonctionnalité de jeu |
| `fix` | correction de bug |
| `perf` | optimisation, comportement inchangé |
| `refactor` | réorganisation du code, comportement inchangé |
| `docs` | `DESIGN.md`, `TASKS.md`, `README.md` |
| `chore` | outillage, `.gitignore`, configuration du projet |
| `test` | ajout ou correction de tests |

Portées qui collent au découpage actuel du dépôt : `voxel`, `world`,
`player`, `network`, `ui`, `assets`, `design`.

```
feat(voxel): add chunked mesher emitting only exposed faces
fix(network): send the world seed to the client before loading the world
perf(world): remesh only the chunk touched by a dig
docs(design): settle the voxel art style
```

Deux précisions pour éviter les faux débats :

- **Les descriptions restent en anglais**, comme tout l'historique existant.
  Seul le préfixe de type est nouveau — la documentation du projet, elle,
  reste en français.
- **L'historique antérieur n'est pas réécrit.** Les commits d'avant cette
  règle sont des messages descriptifs sans préfixe, et c'est très bien ainsi.

Un changement cassant se note `feat(voxel)!:`, ou avec un bloc
`BREAKING CHANGE:` dans le corps du message. C'est surtout utile ici pour le
format de sauvegarde et le protocole réseau, puisque ça oblige l'autre à
régénérer sa sauvegarde ou à se mettre à jour avant de pouvoir rejouer
ensemble.

**Le titre de la Pull Request suit la même convention** : c'est lui qui
devient le message de commit si la PR est mergée en squash.

## Historique (avant la migration vers le Project)

Gardé pour mémoire — les entrées ci-dessous ne seront plus mises à jour ;
l'avancement futur se lit sur le Project (issues fermées) et dans les
messages de commit.

- 2026-09-16 — Squelette réseau initial (menu héberger/rejoindre, ENet,
  spawn de joueurs synchronisé) — à conserver, mais le contrôleur joueur et
  le monde seront réécrits pour le voxel/3e personne (voir `DESIGN.md`,
  section "Ce qui change par rapport au prototype existant").
- 2026-09-16 — Rédaction de `DESIGN.md` (concept, boucle de jeu, système de
  génération des énigmes, feuille de route).
- 2026-09-16 — Première génération procédurale de la plateforme
  (`scenes/world/platform.gd`) : heightmap 300×300 m, contour irrégulier,
  chute mortelle en dehors du bord. Remplace le sol plat du prototype
  initial. Reste en heightmap (pas encore une vraie grille de voxels) —
  à revoir à l'étape "Interaction".
- 2026-09-16 — Correction du bug "apparaît sous la plateforme" au spawn +
  cinématique d'arrivée : le joueur atterrit désormais à bord d'un engin
  volant steampunk (placeholder en primitives) qui descend et se pose de
  façon scriptée, plutôt que de compter sur la gravité pour "l'attraper" —
  ce qui causait le bug. Detail de lore a priori sympa a reprendre dans
  `DESIGN.md` si l'idee plait : c'est ainsi que les joueurs arrivent sur la
  plateforme. Cote reseau : chaque joueur voit sa propre cinematique ;
  les autres joueurs voient seulement sa position se deplacer (pas encore
  l'engin volant) — a ameliorer plus tard si on veut que tout le monde
  voit l'atterrissage de l'autre.
- 2026-09-16 — Vraie cause du "on passe au travers" trouvee et corrigee :
  le maillage de collision genere (trimesh) ne collisionnait que d'un
  seul cote (`backface_collision`), et c'etait le mauvais. Force a `true`
  dans `platform.gd`. Ajout au passage de parois de falaise sur le
  pourtour de l'ile (donne du volume, plus juste un feuillet plat).
- 2026-09-16 — Meme cause plus loin : le sens des triangles du sol
  donnait aussi la mauvaise face visible depuis le dessus (on voyait le
  dessous du terrain). Sens inverse dans `Platform._add_quad`, et
  `cull_mode = CULL_DISABLED` sur le materiau pour ne plus avoir a se
  soucier du sens exact des 4 orientations de parois de falaise.
- 2026-09-16 — Camera passee en 3e personne (CameraPivot + Camera3D
  decale derriere/au-dessus, voir `scenes/player/player.gd`). Pas encore
  de SpringArm3D pour eviter le clipping dans le decor, note en tache.
- 2026-09-16 — Tailscale installe et fonctionnel sur cette machine (reste
  a se connecter avec `tailscale up` et a faire pareil chez l'autre
  joueur). Chat vocal : Discord en attendant, vrai chat integre en tache.
- 2026-09-16 — Premiere version de "creuser/construire" : clic gauche
  creuse (baisse la colonne visee de 1m, +1 bloc), clic droit construit
  (+1m, -1 bloc). Base sur `Platform.column_edits` (sculpte la hauteur
  d'une colonne, pas encore une vraie grille 3D — voir taches ci-dessus).
  Synchronise en reseau via `Platform.request_edit` (RPC any_peer,
  call_local). L'engin volant de la cinematique d'arrivee reste
  desormais sur la plateforme comme epave apres l'atterrissage
  (`World.spawn_wreck`, aussi en RPC), au lieu de disparaitre.
- 2026-09-16 — Viseur au centre de l'ecran (blanc -> jaune des qu'une
  cible valide est a portee), pour qu'un clic dans le vide ne se confonde
  plus avec un bug. Portee d'interaction 6m -> 8m.
- 2026-09-16 — Effondrement simplifie de la terre (`Platform._settle`) :
  creuser/construire ne laisse plus de tour/puits a pic, l'exces glisse
  vers les colonnes voisines (bidirectionnel, porte a quelques colonnes
  autour du point touche).
- 2026-09-16 — Cycle jour/nuit (soleil + ciel qui changent de couleur,
  ~15 min/cycle), nuages qui derivent, et pluie partagee (meme meteo chez
  les deux joueurs sans echange reseau, basee sur l'heure reelle). Tout ça
  est calcule independamment par chaque pair pour l'instant — voir la
  tache "faire autorite cote hote" ci-dessus si ça doit un jour toucher
  des jauges de survie partagees.
- 2026-09-16 — Vegetation (~60 arbres proceduraux) + premier vrai gabarit
  d'enigme jouable : l'horloge est cachee au pied d'un arbre choisi de
  facon deterministe (meme foret, meme arbre chez les deux joueurs, sans
  reseau), ramassable par clic, debloque l'affichage de l'heure pour toute
  l'equipe des qu'un joueur la trouve. Voir `vegetation.gd`, `collectible.gd`.
- 2026-09-16 — Migration du suivi de tâches de ce fichier vers un GitHub
  Project (voir le lien en haut). Les 17 tâches de la section "À faire"
  sont devenues des issues sur le board.
