# Avant Tourousse — Document de conception

Ce document décrit le jeu qu'on construit. Il est vivant : si tu (le lecteur, le
co-développeur) n'es pas d'accord avec un choix ou que tu vois un problème,
modifie-le, mais **préviens l'autre avant de changer un pilier majeur** (voir
`TASKS.md` pour la coordination). Un désaccord non discuté qui atterrit
silencieusement dans un commit est la source n°1 de conflits d'équipe à deux.

## Pitch

Deux joueurs sont coincés sur une immense plateforme flottante (ou île isolée
— le lore exact reste ouvert). Le seul moyen de partir est de trouver un œuf
de dragon, le protéger jusqu'à l'éclosion, élever le dragonneau, et s'envoler
avec lui. Chaque partie se déroule sur une plateforme générée différemment :
taille, biomes, emplacement de l'œuf et chaîne d'énigmes changent à chaque
fois, donc une partie ne se "resoluce" pas par cœur.

## Piliers du jeu

1. **Chaque partie est différente.** Seed aléatoire → géométrie de la
   plateforme, position de l'œuf, artefacts et énigmes changent. Rejouer doit
   rester intéressant.
2. **Le monde entier est interactif.** Voxels : on creuse, on pose des blocs,
   on abat des arbres, on brûle des troncs. Pas de décor purement cosmétique.
3. **La survie est un fil de fond, pas le seul objectif.** Faim/soif/froid
   créent de la pression et rythment la partie, mais le but reste la quête de
   l'œuf.
4. **La progression est un fil à tirer.** Trouver un artefact donne l'indice
   du suivant. Le joueur ne doit (presque) jamais être bloqué sans piste.
5. **Une partie dure 1 à plusieurs heures et se sauvegarde.** Ce n'est pas un
   run de 10 minutes : on doit pouvoir arrêter et reprendre.

## Caméra et contrôles

- Vue **3e personne**, caméra à l'épaule/dans le dos du personnage (comme
  Zelda BOTW, Valheim, Minecraft en mode 3e personne).
- Déplacement classique (avancer/reculer/strafe + saut), la caméra suit avec
  un peu d'inertie.
- Interaction avec le monde par un système de "regard + touche d'action" :
  viser un voxel/objet, une touche pour l'action contextuelle (creuser,
  couper, ramasser, poser, allumer...).
- Remplace complètement le contrôleur FPS du prototype initial (voir section
  "Ce qui change par rapport au prototype existant" plus bas).

## Le monde : la plateforme

- Terrain **voxel**, génération procédurale à partir d'une seed stockée dans
  la sauvegarde (permet de recharger exactement le même monde).
- Plusieurs zones/biomes sur une même plateforme, par exemple : forêt (bois,
  troncs à brûler), zone rocheuse (pierre, minerai, grottes à creuser), point
  d'eau douce (boire, pêcher plus tard ?), clairière/sommet (vue dégagée,
  souvent un bon spot pour un indice "on voit loin d'ici").
- Les grottes/zones creusables doivent exister *avant* que le joueur creuse
  (poches naturelles) autant que des trous que le joueur crée lui-même — les
  deux doivent être des voxels retirables au même titre.
- Taille : suffisamment grande pour justifier 1h+ d'exploration, mais bornée
  (pas de génération infinie type Minecraft — c'est une île/plateforme finie).

## Boucle de survie

- **Faim / soif** : jauges qui descendent avec le temps et l'effort (courir,
  creuser). Se reconstituent en mangeant (baies, viande cuite, fruits) et
  buvant (point d'eau, ou eau bouillie/plus sûre).
- **Cycle jour/nuit** : la nuit est plus dangereuse (froid accru, visibilité
  réduite, éventuellement faune hostile à discuter). Durée d'un cycle à
  calibrer en playtest (proposition de départ : ~15-20 min réelles par cycle
  complet).
- **Température / intempéries** : le froid la nuit ou sous la pluie draine
  une jauge de "confort/chaleur" ; s'abriter (cabane, feu) la restaure.
- **Sommeil** : dormir dans un abri fait passer la nuit plus vite et/ou
  restaure une jauge de fatigue (à définir si on modélise la fatigue comme
  jauge séparée ou pas — proposition : ne pas complexifier au MVP, dormir
  sert juste à passer la nuit en sécurité).
- Mourir de faim/froid ne doit pas être punitif au point de casser une
  partie de plusieurs heures : à trancher ensemble (perte d'objets ? retour à
  un checkpoint ? simple malus temporaire ?).

## Artisanat et outils

- Ressources de base : bois (couper des arbres), pierre (creuser/miner),
  fibre (herbes), nourriture brute.
- Outils : hache (bois → plus vite), pioche (pierre/minerai), pelle
  (creuser la terre), et le **briquet/pierre à feu** — un objet de type
  "survie" à *trouver* (pas fabriqué au début), indispensable pour allumer un
  feu.
- Le feu sert à : cuisiner, se réchauffer, **brûler un tronc creux pour en
  récupérer le contenu** (mécanique explicitement demandée — un tronc donné
  n'est pas juste du bois, certains contiennent une ressource ou un indice
  une fois brûlés).
- Construction : poser des voxels/blocs pour bâtir une cabane (abri contre
  intempéries + point de sommeil sûr). La cabane peut aussi servir à
  résoudre certaines énigmes de hauteur (échafaudage pour atteindre un nid en
  hauteur, par exemple).

## La quête : artefacts, indices, œuf

C'est le cœur du "rejouable différemment à chaque partie". Principe : une
**chaîne d'indices générée** plutôt qu'une énigme unique câblée en dur.

### Le système de gabarits d'énigmes

On définit une bibliothèque de "gabarits" d'énigme/artefact, chacun
paramétrable (position, objet requis, texte d'indice). À chaque partie :

1. On choisit aléatoirement N gabarits parmi la bibliothèque (sans
   répétition), N ~ 4 à 6 pour une partie d'1h+.
2. On les place aléatoirement sur les zones compatibles de la plateforme
   générée (un gabarit "creuser dans le sable" ne peut pas tomber en pleine
   forêt, par exemple — chaque gabarit déclare ses biomes valides).
3. On les enchaîne : trouver l'artefact du gabarit *i* révèle l'indice
   menant au gabarit *i+1*. Le dernier artefact de la chaîne indique
   l'emplacement de l'œuf.
4. Les textes d'indice utilisent les noms des lieux/repères *générés* pour
   cette partie (voir "repères nommés" ci-dessous), donc le texte reste
   cohérent même si le monde change.

### Gabarits proposés (liste de départ, à enrichir)

- **Le coffre enterré** : un indice gravé sur un rocher visible désigne un
  repère ("au pied du plus grand pin", "à l'ombre de la falaise rouge") ; il
  faut creuser à cet endroit.
- **Le tronc calciné** : il faut repérer un tronc particulier (marqué
  visuellement) et le brûler avec le briquet pour en extraire l'artefact.
- **La grotte scellée** : accès bloqué par des voxels qu'il faut creuser en
  suivant un schéma indiqué ailleurs (ex. des symboles gravés dans un ordre à
  reproduire en marchant sur des dalles, ou juste une paroi à repérer via un
  indice de type "la roche qui sonne creux").
- **Le nid en hauteur** : artefact posé sur une corniche/un sommet
  inaccessible sans construire un échafaudage de blocs.
- **La cache immergée** : artefact sous l'eau ou derrière un mur qu'il faut
  faire baisser (drainer un bassin, creuser un canal d'écoulement).
- **Le message à décrypter** : une carte fragmentaire ou un texte à
  reconstituer à partir de 2-3 fragments trouvés séparément (pousse à
  explorer plusieurs zones avant de pouvoir agir).

Chaque nouveau gabarit qu'on ajoute doit préciser : biomes valides, objet(s)
requis pour le résoudre, et le format du texte d'indice qu'il génère pour la
suite de la chaîne.

### Repères nommés

Pour que les indices textuels aient un sens sur un monde généré, la
génération doit aussi produire une petite liste de "repères" identifiables
(le plus grand arbre de la forêt, la falaise la plus haute, le point d'eau
principal, etc.) avec un nom/description, réutilisables par n'importe quel
gabarit d'indice. C'est ce qui permet d'écrire des indices qui restent
cohérents sans être écrits à la main pour chaque partie.

### L'œuf, l'éclosion, l'élevage

- L'œuf est caché selon un des gabarits ci-dessus (ou un gabarit dédié) à la
  fin de la chaîne.
- Une fois trouvé, l'œuf a besoin de conditions pour éclore (chaleur
  constante — près d'un feu/dans un abri — et/ou un temps d'incubation en
  jours). À définir précisément ensemble.
- Après éclosion, le dragonneau doit être nourri régulièrement et protégé
  (de la nuit/du froid/d'un danger à définir) jusqu'à ce qu'il soit assez
  grand pour permettre de quitter la plateforme (condition de victoire).
- Il grandit visiblement par étapes (au moins 2-3 stades visuels) pour que le
  joueur voie sa progression.

## Sauvegarde

Doit persister au minimum :

- la seed du monde et l'état des voxels modifiés (diff par rapport au monde
  généré, pas le monde entier si évitable),
- l'inventaire et les jauges de survie de chaque joueur,
- la progression de la quête (quels artefacts trouvés, quel indice actif),
- l'état de l'œuf/dragon (pas trouvé / en incubation / éclos + stade de
  croissance),
- le jour/l'heure en cours du cycle jour/nuit.

Format exact (JSON, fichier de ressource Godot, autre) à trancher pendant
l'implémentation — le point important ici est la liste des données à couvrir
pour qu'aucune sauvegarde ne "perde" une partie de plusieurs heures.

## Ce qui change par rapport au prototype existant

Le premier prototype technique (menu héberger/rejoindre + capsule FPS sur un
sol plat) reste utile pour la partie réseau (connexion ENet, synchronisation
de position), mais presque tout le reste doit être repensé :

- caméra FPS → caméra 3e personne à l'épaule,
- sol plat unique → terrain voxel généré proceduralement,
- pas d'interaction avec le monde → système complet de voxels
  cassables/plaçables,
- pas d'inventaire/survie → jauges + inventaire + artisanat.

Autrement dit : la base réseau (`autoload/network.gd`) reste probablement
valable, mais `scenes/player` et `scenes/world` vont être largement réécrits.
À discuter ensemble avant de commencer pour éviter que chacun parte sur une
architecture voxel différente (voir `TASKS.md`).

## Portée et étapes proposées

Le scope complet est ambitieux pour deux personnes ; l'idée est d'avancer par
étapes qui restent chacune "jouables", plutôt que de tout construire d'un
bloc :

0. **Prototype voxel de base** : marcher/sauter sur un terrain voxel fixe
   (non généré), caméra 3e personne. Pas de survie, pas de quête.
1. **Interaction** : casser/poser des voxels, inventaire minimal.
2. **Génération procédurale de la plateforme** (seed → terrain + biomes).
3. **Survie** : faim/soif, cycle jour/nuit, température.
4. **Artisanat & feu** : outils, briquet, brûler un tronc.
5. **Construction** : poser des blocs pour bâtir un abri.
6. **Chaîne de quête** : un ou deux gabarits d'énigme, sur une plateforme
   encore fixe, pour valider le système d'indices avant de le généraliser.
7. **Génération de la chaîne de quête + repères nommés** (le vrai "chaque
   partie est différente").
8. **Œuf, éclosion, élevage, condition de victoire.**
9. **Sauvegarde/chargement.**
10. Polish, équilibrage, playtests à deux.

Rien n'empêche de paralléliser certaines étapes entre les deux
développeurs une fois l'architecture de base (étapes 0-2) posée — c'est
justement l'objet de `TASKS.md`.

## Questions ouvertes à trancher ensemble

- Style visuel des voxels (taille de bloc, style graphique — cube "Minecraft"
  franc ou plus stylisé/lissé) ?
- En multijoueur, le monde et l'état de la quête sont-ils **partagés** (les
  deux joueurs voient le même œuf/même chaîne d'indices) ou bien
  chacun a-t-il sa propre instance synchronisée seulement pour les
  positions ? (Partagé semble plus fidèle au pitch "coincés ensemble", mais
  complexifie la synchronisation réseau des voxels.)
- Y a-t-il une faune (hostile ou non) sur la plateforme, ou le seul danger
  est environnemental (faim/froid/chutes) ?
- Sur quelle plateforme veut-on distribuer le jeu au final (juste vous deux
  en LAN/VPN, ou export public) ? Impacte les priorités de polish.
