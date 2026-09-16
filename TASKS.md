# Suivi de travail et coordination

Objectif de ce fichier : que personne ne découvre en pullant que l'autre a
retravaillé le même système en parallèle. Le principe est simple :

1. **Avant de commencer un morceau non-trivial** (un système, pas une
   correction de bug d'une ligne), ajoute une ligne dans "En cours" avec ton
   nom, la date, et ce que tu attaques.
2. **Avant de toucher à un système déjà pris par l'autre**, ou à quelque
   chose qui touche l'architecture commune (format de sauvegarde, structure
   des voxels, code réseau), préviens-le (message, appel, peu importe) avant
   de coder, pas après.
3. Quand c'est fini (ou abandonné), déplace la ligne dans "Terminé
   récemment" avec un lien vers la commit/PR si possible, et nettoie de temps
   en temps les entrées trop vieilles.
4. Committe et pull souvent (idéalement à chaque session), surtout pour ce
   fichier et pour `DESIGN.md` — ce sont les deux fichiers qu'on modifie tous
   les deux, donc les divergences dessus doivent être résolues vite avant de
   diverger sur le code.

Fichiers particulièrement sensibles aux conflits (à ne pas éditer à deux en
même temps sans se prévenir) : les scènes `.tscn` (fusion textuelle mais
casse-tête à relire), `project.godot`, et tout futur fichier de format de
sauvegarde.

## En cours

_(vide pour l'instant — ajoutez une ligne quand vous démarrez quelque chose)_

| Qui | Depuis le | Sur quoi |
|-----|-----------|----------|
|     |           |          |

## À faire / idées non assignées

Repris de la feuille de route dans `DESIGN.md` — à affiner/découper en
tâches plus petites au fur et à mesure :

- [ ] Biomes sur la plateforme générée (forêt, rocher, point d'eau...)
- [ ] Caméra : ajouter un SpringArm3D pour éviter que la caméra 3e
  personne traverse les murs/le terrain aux angles extrêmes
- [ ] Performance : si creuser/construire devient perceptiblement lent en
  jeu (on reconstruit tout le maillage de la plateforme a chaque coup),
  decouper `Platform` en chunks pour ne reconstruire que la zone touchee
- [ ] Vraie grille de voxels 3D (grottes naturelles, structures avec un
  toit separe du sol) — le systeme actuel ne fait que monter/descendre la
  hauteur d'une colonne, pas de veritable volume
- [ ] Jour/nuit et meteo : passer sur une horloge/etat faisant autorite
  cote hote (avec sync reseau) le jour ou ça doit influer sur des jauges
  de survie partagees, OU des qu'on affiche l'heure explicitement a
  l'ecran (voir le gabarit "L'horloge" dans DESIGN.md) — pour l'instant
  chaque pair calcule independamment (voir `day_night_cycle.gd` et
  `World.is_raining`), ce qui est correct seulement tant que c'est
  purement cosmetique/pas affiche comme une donnee fiable au joueur
- [ ] Meteo : faire reagir les nuages (plus denses/sombres quand il pleut)
- [ ] Jauges de survie (faim/soif) + cycle jour/nuit + température
- [ ] Artisanat de base (outils) + briquet + feu + tronc à brûler
- [ ] Construction d'abri (pose de blocs)
- [ ] Système de gabarits d'énigmes + chaîne d'indices (version fixe d'abord)
- [ ] Génération de la chaîne de quête + repères nommés
- [ ] Œuf : éclosion, élevage, condition de victoire
- [ ] Chat vocal intégré (capture micro, envoi réseau, lecture chez l'autre
  joueur) — pas urgent, on utilise Discord en attendant pour les tests.
  Prévoir : format de compression (Opus si dispo), canal réseau dédié
  (probablement non-fiable/unreliable vu le volume de données), et un
  indicateur visuel de qui parle.
- [ ] Sauvegarde / chargement
- [ ] Répondre aux "Questions ouvertes" de `DESIGN.md`

## Terminé récemment

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
