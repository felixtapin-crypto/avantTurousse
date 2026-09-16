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
taille, biomes, emplacement de l'œuf, chaîne d'énigmes et régime alimentaire
du dragon changent à chaque fois, donc une partie ne se "resoluce" pas par
cœur. La quête (œuf, indices, dragon) est **partagée** entre les deux
joueurs : ils voient et font progresser la même histoire, pas deux instances
séparées.

Le dragon ne peut porter qu'**un seul joueur** avant de pouvoir en porter
deux. Ça crée un moment de tension volontaire en fin de partie : dès que le
départ à un seul devient possible, les joueurs doivent décider s'ils
tentent leur chance tout de suite ou s'ils tiennent encore le temps que le
dragon grandisse assez pour les emporter tous les deux (voir "Vol et
dressage").

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
6. **Le dilemme final : partir tôt à un, ou attendre pour partir à deux.**
   Le jeu ménage volontairement une fenêtre où un départ solo est possible
   avant le départ à deux. C'est un moment fort à ne pas gâcher par un
   mauvais calibrage (voir "Vol et dressage").

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
  **Décision technique** : 1 km × 1 km (proposé au départ) est trop grand
  pour un premier prototype sans système de chunks (streaming du terrain par
  morceaux) — ça représenterait un million de colonnes à générer/mailler
  d'un coup. Le prototype actuel (`scenes/world/platform.gd`) démarre à
  **300 m × 300 m** (`Platform.size`, une constante exportée, facile à
  changer). On pourra viser plus grand une fois un vrai système de chunks en
  place ; d'ici là, 300 m reste largement de quoi remplir 1h+ avec plusieurs
  biomes.
- Le prototype actuel génère une **heightmap** (une hauteur par colonne, pas
  encore une vraie grille de voxels creusable/empilable dans toutes les
  directions). C'est volontairement une étape intermédiaire : la structure
  de données va changer à l'étape "Interaction" (creuser/poser des blocs)
  de la feuille de route, une fois qu'on doit vraiment stocker un voxel par
  bloc plutôt qu'une seule hauteur par colonne.

## Flore et faune

Sert un double usage : nourrir les joueurs, et nourrir le dragon (voir plus
bas). Pour que ça marche avec la génération procédurale et le régime
alimentaire aléatoire du dragon, chaque ressource comestible est décrite par
des **tags** plutôt que par une liste figée d'espèces :

- Tags de nature : `fruit`, `champignon`, `racine`, `poisson`, `viande`,
  `insecte`, `œuf-d'oiseau` (à ne pas confondre avec l'œuf de dragon).
- Tags de biome : chaque plante/animal n'apparaît que dans les biomes
  compatibles (poisson → point d'eau, champignon → grotte/sous-bois, etc.),
  cohérent avec le système de biomes déjà décrit.
- Une même ressource peut porter plusieurs tags (ex. un poisson est à la
  fois `poisson` et `viande`).

Comportement de la faune (proposition de départ, à valider ensemble) :
principalement **passive/fuyante** (elle s'enfuit quand on l'approche, il
faut la traquer ou la piéger) plutôt qu'hostile, pour rester cohérent avec un
jeu où la pression vient surtout de la survie et de la quête, pas du combat.
Une variante hostile reste une option pour plus tard (voir "Questions
ouvertes").

Récolte : cueillette pour la flore, chasse/pêche pour la faune. Certaines
ressources rares peuvent elles-mêmes faire partie d'un gabarit d'énigme
(ex. "il faut trouver le poisson qui ne vit que près de la falaise rouge"),
ce qui relie naturellement ce système à celui des artefacts.

## Boucle de survie

- **Faim / soif** : jauges qui descendent avec le temps et l'effort (courir,
  creuser). Se reconstituent en mangeant (flore/faune récoltée, cuite ou non
  selon la ressource) et buvant (point d'eau, ou eau bouillie/plus sûre).
- **Cycle jour/nuit** : la nuit est plus dangereuse (froid accru, visibilité
  réduite). Durée d'un cycle à calibrer en playtest (proposition de départ :
  ~15-20 min réelles par cycle complet).
- **Température / intempéries** : le froid la nuit ou sous la pluie draine
  une jauge de "confort/chaleur" ; s'abriter (cabane, feu) la restaure.
- **Sommeil** : dormir dans un abri fait passer la nuit plus vite et/ou
  restaure une jauge de fatigue (à définir si on modélise la fatigue comme
  jauge séparée ou pas — proposition : ne pas complexifier au MVP, dormir
  sert juste à passer la nuit en sécurité).
- Mourir de faim/froid ne doit pas être punitif au point de casser une
  partie de plusieurs heures : à trancher ensemble (perte d'objets ? retour à
  un checkpoint ? simple malus temporaire ?).

## Jardinage : cultiver sa nourriture

En plus de la cueillette/chasse directe (voir "Flore et faune", qui reste
la source de nourriture de base, toujours disponible), on peut **cultiver**
pour avoir une source fiable et renouvelable sur la durée :

1. **Préparer le sol** avec un outil dédié (houe/bêche) — à trouver sur la
   plateforme, comme le briquet ou l'horloge (voir "La quête : artefacts,
   indices, œuf"), pas fabriqué au début.
2. **Planter** une graine ou une bouture récupérée en cueillant une plante
   sauvage (une plante récoltée donne soit de la nourriture immédiate, soit
   de quoi replanter, soit les deux selon l'espèce/le tag).
3. **Arroser** régulièrement avec un seau rempli à une **source d'eau**
   (point d'eau douce déjà prévu dans "Le monde : la plateforme" — sert
   aussi à boire directement). Le seau est un deuxième outil à trouver.
4. Attendre la pousse (durée en jours/cycles jour-nuit à calibrer), puis
   récolter — la plante peut donner plusieurs récoltes ou une seule selon
   l'espèce.

Le jardinage n'est jamais obligatoire (cueillette/chasse suffisent pour ne
pas mourir de faim), mais évite de dépendre uniquement de ce qu'on trouve
au hasard sur une partie de plusieurs heures — utile en particulier si le
régime du dragon (voir plus bas) demande un tag de nourriture rare ou
difficile à trouver autrement : cultiver la bonne plante peut devenir la
solution la plus fiable.

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
5. Une récompense de gabarit n'est pas forcément un indice de lieu : ça peut
   aussi être un indice sur le **régime alimentaire du dragon** (voir plus
   bas), un outil, ou une ressource rare. Ça évite que la chaîne ne soit
   qu'une suite de "va au point suivant".

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
- **Le carnet du gardien** : un journal ou une gravure qui ne donne pas un
  lieu mais un indice sur le **régime alimentaire du dragon** de cette
  partie (ex. "les anciens nourrissaient leurs dragons de poisson et de
  baies, jamais de viande"). Peut apparaître à n'importe quel maillon de la
  chaîne, pas seulement à la fin.
- **L'horloge (à trouver ou à fabriquer)** : tant qu'on ne l'a pas, les
  joueurs n'ont aucune indication fiable de l'heure — seulement ce qu'ils
  voient à l'œil (position du soleil, luminosité). La trouver (une montre
  ou un cadran solaire caché, comme les autres artefacts) ou la fabriquer
  (assembler un cadran solaire avec les bons matériaux, à un endroit
  suffisamment dégagé pour voir le soleil) débloque un indicateur d'heure
  à l'écran. Peut aussi conditionner une énigme qui a besoin d'un moment
  précis (ex. "l'ombre ne pointe sur la porte qu'au midi solaire").
  Implication technique : ça renforce l'idée que l'heure du jour doit
  devenir une vraie donnée partagée (autorité côté hôte + synchro), pas
  calculée en indépendant par chaque joueur comme c'est le cas maintenant
  (voir `TASKS.md`) — sinon les deux joueurs pourraient voir une heure
  légèrement différente une fois qu'elle est affichée explicitement à
  l'écran, ce qui serait bien plus visible/gênant qu'un simple décalage
  cosmétique sur la position du soleil.

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

### Le régime alimentaire du dragon

Demande explicite : **chaque partie, le dragon a un régime différent**, à
découvrir en jouant plutôt qu'à connaître à l'avance. Ça réutilise le
système de tags de la flore/faune :

- À la génération de la partie, on tire un **profil alimentaire** pour ce
  dragon : par exemple 1-2 tags "adorés" (croissance forte), 1-2 tags
  "tolérés" (croissance faible/neutre), le reste "refusés" (aucune
  croissance, le dragon recrache/ignore). Les tags viennent de la même liste
  que la flore/faune (`fruit`, `poisson`, `viande`, `insecte`, etc.).
- **Découverte** : essentiellement par essai-erreur avec un retour clair
  (réaction visuelle/sonore différente selon que le dragon adore, tolère ou
  refuse), complété éventuellement par un indice de type "carnet du
  gardien" (voir gabarits ci-dessus) qui donne une longueur d'avance sans
  être obligatoire.
- **Croissance** : chaque repas "aimé" fait avancer une jauge de croissance
  cumulée ; passer un palier de cette jauge fait passer le dragon au stade
  visuel suivant. La croissance est donc pilotée par *ce qu'on lui donne à
  manger*, pas seulement par le temps passé.
- **Tension avec la survie du joueur** : la nourriture est une ressource
  partagée entre le joueur et le dragon. Si le tag préféré du dragon est
  rare sur cette plateforme (ex. un poisson qui ne vit que dans une seule
  zone), nourrir le dragon devient un vrai objectif d'exploration, pas
  juste un menu à cocher. C'est un levier d'équilibrage à calibrer en
  playtest : le régime ne doit pas tomber uniquement sur des ressources
  quasi introuvables.

### Vol et dressage

La capacité de vol du dragon est liée à ses stades de croissance (voir
ci-dessus), avec au moins ces paliers :

1. **Nouveau-né** : ne vole pas. Suit/se laisse porter, se nourrit.
2. **Juvénile** : peut voler, mais sans passager. C'est le stade où
   commence le **dressage**.
3. **Adolescent** : peut porter **un seul joueur** en vol → premier moment
   où un départ (partiel) devient possible.
4. **Adulte** : peut porter **les deux joueurs** → condition de victoire
   complète du jeu.

**Dressage** : une fois le dragon capable de voler (stade 2), les joueurs
débloquent des séances d'entraînement guidées par des consignes en jeu
(ex. "traverse les 5 anneaux avant la fin du temps", "pose-toi précisément
sur la zone marquée", "suis le joueur qui court en contrebas"). Réussir des
séances fait progresser une jauge de dressage distincte de la croissance
"nutrition" ; il faut probablement un minimum des deux (bien nourri *et*
bien dressé) pour débloquer le passage au stade suivant, plutôt qu'un seul
critère — sinon un joueur pourrait suffisamment gaver le dragon en ignorant
le dressage, ou l'inverse.

**Le dilemme du départ** : dès le stade 3, techniquement un des deux joueurs
pourrait s'envoler et terminer la partie en laissant l'autre sur la
plateforme. C'est une tension voulue, mais il faut décider ensemble
comment le jeu la traite (voir "Questions ouvertes") : le permettre
franchement (avec une fin "amère" dédiée si un joueur part seul), ou exiger
un accord des deux joueurs pour déclencher un départ, ce qui transforme le
dilemme en décision collective ("on tente le solo maintenant ou on attend
ensemble ?") plutôt qu'en trahison possible d'un joueur envers l'autre.

## Sauvegarde

Doit persister au minimum :

- la seed du monde et l'état des voxels modifiés (diff par rapport au monde
  généré, pas le monde entier si évitable),
- l'inventaire et les jauges de survie de chaque joueur,
- la progression de la quête (quels artefacts trouvés, quel indice actif),
- l'état de l'œuf/dragon (pas trouvé / en incubation / éclos + stade de
  croissance),
- le régime alimentaire tiré pour le dragon (tags aimés/tolérés/refusés) et
  ce que les joueurs en ont déjà découvert,
- la jauge de dressage/vol du dragon,
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

Point technique important induit par la quête **partagée** : il ne suffira
pas de synchroniser la position des joueurs comme dans le prototype actuel.
Il faudra aussi synchroniser l'état du monde (voxels modifiés), la
progression de la quête, et l'état du dragon entre les deux pairs — l'hôte
fera probablement autorité sur ces données, un peu comme il l'est déjà pour
le spawn des joueurs.

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
8. **Œuf, éclosion, élevage (régime alimentaire, croissance).**
9. **Dressage et vol, paliers de capacité de transport, condition de
   victoire (solo puis à deux).**
10. **Sauvegarde/chargement.**
11. Polish, équilibrage, playtests à deux.

Rien n'empêche de paralléliser certaines étapes entre les deux
développeurs une fois l'architecture de base (étapes 0-2) posée — c'est
justement l'objet de `TASKS.md`.

## Questions ouvertes à trancher ensemble

- Style visuel des voxels (taille de bloc, style graphique — cube "Minecraft"
  franc ou plus stylisé/lissé) ?
- **Départ solo au stade 3 (voir "Vol et dressage")** : le jeu le permet
  franchement (avec une fin dédiée si un joueur part seul et laisse l'autre)
  ou bien exige un accord des deux joueurs pour déclencher tout départ ?
  Choix de ton important, à trancher ensemble avant d'implémenter la
  condition de victoire.
- La faune est-elle uniquement passive/fuyante (proposition actuelle, voir
  "Flore et faune"), ou certaines créatures sont-elles hostiles ?
- Sur quelle plateforme veut-on distribuer le jeu au final (juste vous deux
  en LAN/VPN, ou export public) ? Impacte les priorités de polish.
