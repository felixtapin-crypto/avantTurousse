class_name WorldMap
extends RefCounted

# Carte du monde en 2D : une altitude, un climat et un biome par colonne.
# Ne contient AUCUN voxel — c'est la couche au-dessus, qui empile les blocs.
#
# Cette separation n'est pas cosmetique, elle est ce qui rend les deux
# moteurs de rendu interchangeables (voir issue #34) :
#
# - le moteur maison (`voxel_data.gd` + `voxel_mesher.gd`) remplit un tableau
#   de voxels complet et maille lui-meme ;
# - godot_voxel appelle `_generate_block()` par chunk, DEPUIS PLUSIEURS
#   THREADS, et suppose donc une generation strictement locale.
#
# Le second modele est incompatible avec deux de nos passes, qui ont un rayon
# NON BORNE : l'accumulation d'ecoulement (le debit d'une colonne depend de
# tout son bassin amont) et l'ombre pluviometrique (54 voxels au vent). Le
# pattern des demos de godot_voxel — re-deriver les chunks voisins avec la
# meme graine — ne marche que pour un rayon borne, comme un arbre.
#
# La resolution tient en une observation : tout ce travail global est en 2D,
# et le 3D (empiler une colonne, creuser les grottes) est purement local. On
# calcule donc cette carte UNE fois, et les deux moteurs se contentent de la
# lire. En lecture seule apres `generate()`, elle est sure en multithread.

# ===========================================================================
# CHAINE DE GENERATION
# ===========================================================================
#
# Le relief ne sort pas d'un bruit pose tel quel. Il passe par quatre etapes,
# dans cet ordre, parce que chacune a besoin de la precedente :
#
#   1. RELIEF DE BASE       bruit fractal + masque d'ile + fond marin
#   2. HYDROLOGIE           accumulation d'ecoulement puis incision fluviale
#   3. CLIMAT               temperature et humidite par colonne
#   4. BIOMES               croisement climat x altitude x pente
#
# L'etape 2 est ce qui separe un terrain "organique" d'un terrain "bruite".
# Un bruit fractal seul produit des bosses sans logique : pas de vallees qui
# se rejoignent, pas de cretes entre bassins versants, pas de reseau. On
# calcule donc ou l'eau s'ecoule, et on creuse proportionnellement au debit —
# c'est le modele d'incision fluviale classique (loi de puissance de
# ruisseau, erosion proportionnelle a debit^m x pente^n). Le resultat est un
# reseau de vallees ramifiees, et des cretes qui apparaissent toutes seules
# la ou deux bassins se rencontrent.
#
# Note sur Terrain3D : son auto-shader ne connait QUE l'altitude et la pente,
# il n'a aucune notion de climat — c'est un moteur de rendu de terrain, pas
# un generateur de biomes. On garde ses deux regles (bandes d'altitude,
# surcharge par la pente, qui restent excellentes pour la lecture visuelle
# d'un relief), mais un vrai biome demande un climat : c'est ce que font les
# etapes 3 et 4, sur le principe du diagramme de Whittaker (temperature x
# humidite). Sans ca, un desert tomberait n'importe ou plutot que la ou il
# fait chaud et sec.

# Version de l'ALGORITHME, a incrementer des qu'on modifie le code de la
# generation sans toucher a une constante — reordonner les passes, changer une
# formule, ajouter une etape.
#
# Le cache (voir `map_cache.gd`) calcule son empreinte sur les constantes de ce
# fichier, par introspection, ce qui couvre tout changement de REGLAGE sans
# qu'on ait a y penser. Mais l'introspection ne voit pas le corps des
# fonctions : sans ce compteur, une refonte de l'erosion servirait d'anciennes
# cartes en silence.
const GENERATION_VERSION := 4

# --- Geometrie de l'ile ----------------------------------------------------
const SEA_LEVEL := 30

# Portee du continent, en fraction de la DEMI-largeur de carte : 1.0 est le
# milieu d'un bord, et les coins sont a 1.41. Rester sous 1.0 est ce qui
# garantit de l'ocean sur les quatre bords, donc une terre entierement
# entouree d'eau quoi que raconte le bruit. La marge est la largeur de la
# transition vers le large.
const CONTINENT_REACH := 0.94
const OCEAN_MARGIN := 0.26

# Forme du continent. La frequence fixe la taille des golfes et des
# peninsules : plus elle est basse, plus les decoupes sont amples. Le seuil
# decide de la proportion de terres — le monter noie le continent, le
# descendre le fait deborder jusqu'aux bords de la carte.
const CONTINENT_FREQUENCY := 0.0035
const CONTINENT_OCTAVES := 4
const COAST_THRESHOLD := 0.31
# Largeur du degrade au littoral, et courbure de la montee vers les terres.
#
# Les deux fabriquent les plages, et le passage au masque continental les a
# fait disparaitre : de 2 614 colonnes de plage a 129, parce qu'un masque
# seuille monte bien plus vite qu'un rayon interpole. L'exposant maintient la
# cote basse plus longtemps, ce qui etale un plateau littoral au lieu d'une
# falaise plantee dans l'eau.
const COAST_BLEND := 0.15
const COAST_CURVE := 1.9

# Le relief doit avoir assez d'ampleur pour que les sommets soient
# reellement froids : c'est l'altitude qui fabrique la neige, pas un seuil
# qu'on baisserait jusqu'a ce qu'un peu de blanc apparaisse. Une ile quatre
# fois plus grande supporte de toute facon un relief plus marque.
const SURFACE_BASE := 45.0
const SURFACE_AMPLITUDE := 14.0

# Plaines : des zones ou le relief est volontairement ecrase.
#
# Un bruit fractal ne produit jamais de terrain PLAT — il produit du vallonne
# a toutes les echelles, donc partout une pente. Pour qu'il existe des plaines
# ou s'installer, il faut les creuser dans le modele : un second bruit basse
# frequence designe les regions plates, et on y attenue le relief au lieu de
# le laisser osciller.
#
# L'erosion fluviale ne les detruit pas ensuite : elle creuse
# proportionnellement a la pente, donc elle ne mord presque pas sur du plat.
const PLAIN_FREQUENCY := 0.0055
const PLAIN_THRESHOLD := 0.12
const PLAIN_BLEND := 0.34
# Part du relief conservee au coeur d'une plaine. Zero donnerait une table de
# billard, qu'aucun terrain naturel ne montre.
const PLAIN_RELIEF := 0.16
# Pente en-deca de laquelle on considere un terrain comme praticable et plat,
# pour la mesure affichee a l'ecran de generation.
const FLAT_SLOPE := 0.22
const SEABED_BASE := 22.0
const SEABED_AMPLITUDE := 2.5
const SEABED_FALLOFF := 8.0
const SEABED_FALLOFF_RANGE := 60.0

# --- Hydrologie ------------------------------------------------------------
const EROSION_PASSES := 2
const EROSION_K := 0.012          # intensite de l'incision
const EROSION_M := 0.5            # exposant du debit
const EROSION_N := 1.0            # exposant de la pente
# Incision max par passe. A regler avec parcimonie : a 7, l'erosion faisait
# passer pres d'un tiers des terres sous le niveau de la mer, ce qui rabotait
# l'ile au point qu'aucun sommet n'atteignait plus l'altitude de la neige.
const EROSION_MAX := 4.0
const SORT_BUCKETS := 2048        # finesse du tri par altitude

# Comblement des cuvettes, avant toute accumulation d'ecoulement.
#
# UN ECOULEMENT D8 S'ARRETE DANS LE PREMIER TROU VENU. Un bruit fractal erode
# puis lisse en compte des centaines : mesure sur une carte de 300, 244
# cuvettes pour 38 000 colonnes emergees, et surtout SEULEMENT 37,6 % DES
# COLONNES ATTEIGNAIENT LA MER en suivant la pente. Le debit ne s'accumulait
# donc jamais sur une longue distance, et le quantile des rivieres designait
# l'exutoire de chaque petit bassin ferme plutot qu'un collecteur.
#
# Ce defaut est aussi vieux que l'hydrologie de ce fichier. Il est reste
# invisible tant qu'une riviere etait un trait d'une colonne sur la carte
# d'apercu : des centaines de traits epars ressemblent a un reseau. Des qu'ils
# sont devenus des chenaux creuses de trois metres, ils se sont lus pour ce
# qu'ils etaient — des flaques sans amont ni aval.
#
# On comble donc par inondation prioritaire depuis la mer (Priority-Flood
# d'epsilon, Barnes et al.) : chaque colonne recoit l'altitude a laquelle
# l'eau l'atteindrait, soit la sienne, soit le seuil qu'il a fallu franchir
# pour venir jusqu'a elle. Toute colonne a alors un voisin strictement plus
# bas — celui d'ou l'inondation est venue — donc plus aucun trou.
#
# Le resultat va dans un champ SEPARE. Combler le vrai relief remonterait le
# fond de chaque dépression du terrain, c'est-a-dire modifierait un paysage
# qui convient ; ici on ne corrige que la carte sur laquelle l'eau CHOISIT son
# chemin, pas celle qu'on voit.
const FILL_EPSILON := 0.005
# Finesse de la file de priorite. Deux colonnes du meme seau sortent dans un
# ordre quelconque, et c'est sans danger : quelle que soit la sortie, toute
# colonne inondee garde un parent strictement plus bas, donc aucune cuvette ne
# peut renaitre. On n'y perd qu'un comblement legerement moins econome.
const FILL_BUCKETS := 4096

# Fraction des colonnes emergees qui portent une riviere. Un seuil de debit
# EN DUR ne peut pas marcher : le debit d'une colonne est le nombre de
# colonnes qui s'ecoulent a travers elle, donc il croit avec la surface de la
# carte. La meme constante donnerait des rivieres partout sur une grande
# carte et aucune sur une petite. On vise donc un quantile.
#
# Attention : cette fraction compte les colonnes de la LIGNE d'ecoulement, pas
# celles du chenal. Elargies a un lit de 1 a 4 m borde de ses berges (voir
# `river_network.gd`), elles couvrent environ dix fois cette surface.
#
# C'est ce qui a impose de la diviser par deux en passant du ruban d'une colonne
# au vrai chenal : a 0,008 le creusement occupait 7,7 % des terres, et l'ile
# ressemblait a un marecage. C'est ce curseur-ci qu'on bouge quand le reseau
# parait dense, jamais la largeur du lit, qui est une demande.
const RIVER_FRACTION := 0.004

# --- Climat ----------------------------------------------------------------
# Temperature et humidite sont normalisees entre 0 et 1.
#
# Le gradient adiabatique doit etre franc pour que les sommets soient
# reellement froids (sans quoi le biome de neige n'apparait jamais et reste
# du code mort). Il n'est tenable que PARCE QUE l'ombre pluviometrique
# decouple l'humidite de l'altitude : le desert se forme desormais dans les
# basses terres sous le vent, pas dans l'interieur en altitude, donc
# refroidir les hauteurs ne le supprime plus. Avec un simple gradient
# continentalite/altitude, les deux reglages s'excluaient.
const TEMP_BASE := 0.70
const TEMP_LAPSE := 0.024         # refroidissement par voxel au-dessus de la mer
const TEMP_LATITUDE := 0.34       # amplitude du gradient nord-sud
# Position de l'equateur, en fraction de la carte sur l'axe Z. A 1.0 il tombe
# exactement sur le bord sud, ce qui redonne un gradient monotone du froid au
# chaud — le comportement d'origine, a l'identique. Le ramener vers 0.5 place
# une vraie bande equatoriale au milieu de la carte, avec deux moities
# froides ; c'est plus juste physiquement mais ca reduit l'ecart climatique
# traverse par un continent centre, donc a recalibrer si on le change.
const TEMP_EQUATOR := 1.0
const TEMP_NOISE := 0.12

const MOIST_BASE := 0.30
const MOIST_COAST := 0.26         # l'air humide vient de la mer
const MOIST_RIVER := 0.30         # une vallee a fort debit est humide
const MOIST_SHADOW := 0.64        # assechement sous le vent
const MOIST_NOISE := 0.16

# Ombre pluviometrique : le vent dominant charge d'humidite au-dessus de la
# mer, la lache en montant sur le premier relief, et arrive sec de l'autre
# cote. C'est LE mecanisme qui fabrique un desert chaud.
#
# Sans lui, humidite et temperature sont mecaniquement anti-correlees sur une
# ile : l'interieur est haut donc froid et sec, la cote est basse donc chaude
# et humide — et l'intersection "chaud ET sec" est rigoureusement vide, ce
# qu'on a mesure (28 % de terres assez chaudes, 6,8 % assez seches, 0 % les
# deux). L'ombre pluviometrique asseche un versant sous le vent A TOUTE
# ALTITUDE, ce qui decouple enfin les deux champs.
const WIND_DIR := Vector2(0.82, 0.57)
const SHADOW_SAMPLES := 6
const SHADOW_STEP := 9.0
const SHADOW_SCALE := 8.0         # denivele au vent au-dela duquel l'ombre sature

# --- Seuils de biome -------------------------------------------------------
const DEEP_SEA_DEPTH := 6
const BEACH_BAND := 4             # hauteur de plage au-dessus du niveau de la mer
# Seuils de pente, en voxels de denivele par voxel parcouru, mesures sur
# l'altitude FLOTTANTE et non sur l'entier.
#
# L'entier ne marchait pas, pour deux raisons. Il quantifie brutalement : tout
# ce qui est entre deux marches tombe dans la meme classe, donc un seuil a 3
# demandait 71 degres, une paroi que presque rien n'atteint. Et surtout, plus
# la carte est grande, plus les bassins versants sont vastes, donc plus
# l'incision fluviale est forte et plus les pentes s'adoucissent : la rocaille
# sortait a 300 et disparaissait a 600, pour un code inchange.
const BEACH_MAX_SLOPE := 0.6      # au-dela, la cote est une falaise, pas une plage
const SLOPE_ROCK := 1.5
const SLOPE_SCREE := 0.9
const TEMP_SNOW := 0.30           # en-dessous : neige
const TEMP_DESERT := 0.50        # au-dessus, et sec : desert
const MOIST_DESERT := 0.43
const MOIST_FOREST := 0.58

# --- Sous-sol --------------------------------------------------------------
const BEDROCK_DEPTH := 3
const DIRT_DEPTH := 4
const SAND_DEPTH := 3
const DESERT_SAND_DEPTH := 6

# --- Grottes ---------------------------------------------------------------
#
# Le bruit 3D d'origine a ete remplace par un vrai reseau : des salles reliees
# par des galeries, avec des entrees. Voir `cave_network.gd`, qui explique
# pourquoi il est EVALUE et non creuse.
#
# Ce qui a decide du remplacement : le bruit ne pouvait pas avoir d'entrees. La
# marge sous la surface qui l'empechait d'ouvrir des trous beants lui
# interdisait du meme coup toute ouverture, et les grottes existaient donc sans
# que le joueur puisse jamais en trouver une.

enum Biome {
	DEEP_SEA,
	SHALLOW_SEA,
	BEACH,
	RIVER,
	DESERT,
	PLAINS,
	FOREST,
	ROCK,
	SCREE,
	SNOW,
}

var seed_used: int = 0
var size_xz: int
var size_y: int

var _heights: PackedInt32Array      # altitude du sol, entiere, apres erosion
var _height_f: PackedFloat32Array   # la meme, en flottant, pendant la generation
var _continentality: PackedFloat32Array # 0 au rivage, 1 au coeur des terres
var _flow: PackedFloat32Array       # debit accumule
# Relief SANS cuvette, servant uniquement a decider ou l'eau va. Voir
# FILL_EPSILON : c'est le seul champ sur lequel une descente ne s'arrete
# jamais avant la mer. Le relief visible, lui, garde ses creux.
var _drain: PackedFloat32Array
# Voisin vers lequel chaque colonne s'ecoule, -1 si elle n'en a pas (bord,
# mer, cuvette). Sous-produit de l'accumulation d'ecoulement, conserve parce
# que le trace des rivieres en a besoin : le recalculer serait cinq millions
# d'operations pour retrouver le meme tableau, et surtout deux copies d'une
# meme regle a garder d'accord. Purement interne a la generation, donc jamais
# mis en cache.
var _receiver: PackedInt32Array
# Champs climatiques conserves apres la generation : ils servent au placement
# de la vegetation et de la faune (chaque espece declarera ses tolerances),
# et ils rendent un calibrage de biome inspectable au lieu d'etre a deviner.
var _temperature: PackedFloat32Array
var _moisture: PackedFloat32Array
var _shadow: PackedFloat32Array     # ombre pluviometrique, 0 au vent, 1 sous le vent
var _biomes: PackedByteArray
# Reseau de grottes. Redérive de la graine, jamais stocke : c est la meme
# politique que le bruit qu il remplace, et elle est ce qui rend le monde
# gratuit a sauvegarder.
# Avancement de `generate()`, entre 0 et 1, et demande d'interruption.
#
# La generation tourne sur un fil separe pendant que l'interface reste vivante.
# Ces deux variables sont le seul lien entre les deux, et elles se passent de
# verrou : un float et un booleen, ecrits par un cote et lus par l'autre, sans
# qu'aucune decision ne depende de leur coherence mutuelle. Le pire cas est une
# barre de progression en retard d'une image.
#
# `cancel_requested` est relu entre les passes ET au fil des boucles longues :
# une carte de 800 met plusieurs secondes, et n'annuler qu'entre deux passes
# laisserait l'utilisateur attendre l'essentiel du calcul qu'il vient d'annuler.
var progress := 0.0
var cancel_requested := false

var caves: CaveNetwork = CaveNetwork.new()
# Reseau de rivieres. A la difference des grottes, il est TAMPONNE dans les
# hauteurs plutot qu'evalue par voxel — voir `river_network.gd`. Le trace
# survit a la generation parce que les hauteurs en cache sont deja creusees :
# retracer dessus suivrait le chenal au lieu de le reproduire.
var rivers: RiverNetwork = RiverNetwork.new()
var _min_height := 0
var _max_height := 0


func _init(world_size_xz: int = 600, world_size_y: int = 64) -> void:
	size_xz = world_size_xz
	size_y = world_size_y

	var columns := size_xz * size_xz
	_heights = PackedInt32Array()
	_heights.resize(columns)
	_height_f = PackedFloat32Array()
	_height_f.resize(columns)
	_continentality = PackedFloat32Array()
	_continentality.resize(columns)
	_flow = PackedFloat32Array()
	_flow.resize(columns)
	_drain = PackedFloat32Array()
	_drain.resize(columns)
	_receiver = PackedInt32Array()
	_receiver.resize(columns)
	_temperature = PackedFloat32Array()
	_temperature.resize(columns)
	_moisture = PackedFloat32Array()
	_moisture.resize(columns)
	_shadow = PackedFloat32Array()
	_shadow.resize(columns)
	_biomes = PackedByteArray()
	_biomes.resize(columns)


# --- Acces ----------------------------------------------------------------

# Altitudes extremes du terrain, bornes comprises. Sert aux moteurs a sauter
# d'un bloc un chunk entierement au-dessus du relief (tout en air) ou
# entierement en dessous (tout en pierre), sans l'examiner voxel par voxel.
func height_range() -> Vector2i:
	return Vector2i(_min_height, _max_height)


# Le bruit 3D des grottes est expose plutot que consomme sur place : le
# creusement est la seule partie du remplissage qui n'est pas deductible de
# la carte 2D, et les deux moteurs doivent en faire exactement la meme
# lecture pour produire le meme monde. FastNoiseLite n'a pas d'etat
# d'echantillonnage, donc l'appel est sur depuis plusieurs threads — a la
# difference d'un Curve, qui se cuit paresseusement et plante dans ce cas
# (piege documente dans les demos de godot_voxel).
# Altitude du sol en flottant, avant arrondi a l'entier.
#
# Le rendu en blocs n'a besoin que de l'entier, mais le rendu lisse construit
# une fonction de distance signee : arrondir d'abord y ferait apparaitre des
# marches d'escalier de la hauteur d'un voxel, c'est-a-dire exactement ce que
# le lissage est cense supprimer.
func terrain_height_f(x: int, z: int) -> float:
	if x < 0 or z < 0 or x >= size_xz or z >= size_xz:
		return -1.0
	return _height_f[z * size_xz + x]


# Capsules du reseau susceptibles de concerner une colonne.
#
# Le generateur la demande UNE fois par colonne, puis la reutilise pour tous
# les voxels de celle-ci : la recherche par case est un acces de dictionnaire,
# bien trop cher pour etre refait a chaque voxel.
func cave_column(x: int, z: int) -> PackedInt32Array:
	return caves.column(x, z)


# Distance signee au vide de la grotte : positive dedans, negative dans la
# roche. Le generateur en prend le MAXIMUM avec la distance au terrain, ce qui
# creuse.
func cave_sdf_in(indices: PackedInt32Array, x: int, y: int, z: int) -> float:
	return caves.sdf_in(indices, x, y, z)


func cave_sdf(x: int, y: int, z: int) -> float:
	return caves.sdf(x, y, z)


# Bande d'altitudes concernee par ces capsules, pour ne pas tester le reseau
# sur toute la hauteur d'un chunk.
# Accesseurs du reseau, pour l apercu et les controles.
func cave_rooms() -> Array[Vector4]:
	return caves.rooms


func cave_entrances() -> Array[Vector3i]:
	return caves.entrances


func cave_capsule_count() -> int:
	return caves.capsule_count()


func cave_y_bounds(indices: PackedInt32Array) -> Vector2i:
	return caves.y_bounds(indices)


# Le reseau touche-t-il ce pave ? Permet de remplir d'un bloc les chunks
# souterrains qu'aucune galerie ne traverse.
func caves_touch(origin: Vector3i, extent: Vector3i) -> bool:
	return caves.touches(
		origin.x, origin.z, origin.x + extent.x, origin.z + extent.z,
		origin.y, origin.y + extent.y)

func terrain_height(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= size_xz or z >= size_xz:
		return -1
	return _heights[z * size_xz + x]


func temperature_at(x: int, z: int) -> float:
	if x < 0 or z < 0 or x >= size_xz or z >= size_xz:
		return 0.0
	return _temperature[z * size_xz + x]


func moisture_at(x: int, z: int) -> float:
	if x < 0 or z < 0 or x >= size_xz or z >= size_xz:
		return 0.0
	return _moisture[z * size_xz + x]


func continentality_at(x: int, z: int) -> float:
	if x < 0 or z < 0 or x >= size_xz or z >= size_xz:
		return 0.0
	return _continentality[z * size_xz + x]


func rain_shadow_at(x: int, z: int) -> float:
	if x < 0 or z < 0 or x >= size_xz or z >= size_xz:
		return 0.0
	return _shadow[z * size_xz + x]


func flow_at(x: int, z: int) -> float:
	if x < 0 or z < 0 or x >= size_xz or z >= size_xz:
		return 0.0
	return _flow[z * size_xz + x]


# Cette colonne est-elle un lit de riviere ?
#
# Lu dans les BIOMES et non dans le masque du reseau : le masque ne vit que le
# temps de la generation, alors que les biomes partent au cache. Une carte
# rechargee repond donc aussi bien qu'une carte fraiche.
#
# Appele par `cave_network.gd` sur une reference NON TYPEE, ce qui est ce qui
# evite le cycle de classes entre les deux fichiers.
func is_river(x: int, z: int) -> bool:
	return biome_at(x, z) == Biome.RIVER


# Contribution de la latitude a la temperature, isolee du reste. Purement
# pour l'affichage : elle permet de voir ou passe l'equateur du monde, que
# l'altitude et le bruit masquent sur la carte de temperature.
func latitude_temperature(z: int) -> float:
	return TEMP_LATITUDE * (0.5 - absf(float(z) / float(size_xz) - TEMP_EQUATOR))


func biome_at(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= size_xz or z >= size_xz:
		return Biome.DEEP_SEA
	return _biomes[z * size_xz + x]


func biome_name(biome: int) -> String:
	match biome:
		Biome.DEEP_SEA: return "mer profonde"
		Biome.SHALLOW_SEA: return "mer cotiere"
		Biome.BEACH: return "plage"
		Biome.RIVER: return "riviere"
		Biome.DESERT: return "desert"
		Biome.PLAINS: return "prairie"
		Biome.FOREST: return "foret"
		Biome.ROCK: return "rocaille"
		Biome.SCREE: return "eboulis"
		Biome.SNOW: return "neige"
		_: return "?"


# --- Generation ------------------------------------------------------------

# Tout part de la seed : meme seed -> meme ile, chez les deux joueurs comme
# d'une session a l'autre. Attention : des que la seed sera tiree au hasard
# par partie, elle devra etre TRANSMISE au client et ne pourra plus etre une
# constante compilee — voir issue #31.
func generate(seed_value: int) -> void:
	seed_used = seed_value
	progress = 0.0

	# Les fractions ne sont pas reparties uniformement : elles suivent le cout
	# MESURE de chaque passe. Le relief de base et l'hydrologie pesent a eux
	# deux les quatre cinquiemes du total, et une barre qui les traiterait a
	# egalite avec les autres passerait son temps a mentir.
	_build_base_relief(seed_value)
	if cancel_requested:
		return
	progress = 0.45

	_apply_hydrology()
	if cancel_requested:
		return
	progress = 0.72

	# Le reseau est TRACE ici, sur le relief final, mais il ne creuse pas
	# encore : le creusement attend que les biomes soient poses. Voir plus bas.
	#
	# Le seuil est calcule UNE fois et passe aux deux etapes qui s'en servent :
	# c'est un histogramme sur toute la carte, et le recalculer coutait une
	# seconde traversee pour un resultat identique.
	var river_flow := _river_threshold()
	rivers.build(_height_f, _flow, _receiver, size_xz, SEA_LEVEL, river_flow)
	if cancel_requested:
		return
	progress = 0.80

	_build_rain_shadow()
	if cancel_requested:
		return
	progress = 0.88

	_classify(seed_value, river_flow)
	if cancel_requested:
		return
	progress = 0.94

	# CREUSER APRES AVOIR CLASSE, et c'est le point delicat de tout l'ordre.
	#
	# `_biome_for` fait passer la pente avant le climat : au-dela de
	# SLOPE_SCREE une colonne devient un eboulis, au-dela de SLOPE_ROCK une
	# rocaille. Or les berges d'un chenal de deux metres de fond depassent
	# largement les deux. Creuser d'abord borderait donc CHAQUE riviere de
	# rubans d'eboulis et de rocaille, et rognerait au passage la foret et la
	# prairie qu'elle traverse.
	#
	# On classe donc le PAYSAGE, puis on y estampe le chenal.
	_height_f = rivers.carve(_height_f)
	_refresh_heights()
	progress = 0.96

	_min_height = size_y
	_max_height = 0
	for h in _heights:
		_min_height = mini(_min_height, h)
		_max_height = maxi(_max_height, h)

	# EN DERNIER : le reseau lit les hauteurs pour rester sous terre et pour
	# placer ses entrees sur des versants emerges. Le bruit qu'il remplace, lui,
	# ne dependait de rien et se preparait en tete.
	caves.build(self, seed_value, SEA_LEVEL, BEDROCK_DEPTH)
	progress = 1.0


# Ombre pluviometrique : on remonte le vent sur quelques dizaines de voxels et
# on retient le plus fort denivele rencontre. Une colonne derriere une crete
# est a l'abri des pluies, donc seche ; une colonne exposee au large recoit
# tout. Calcule apres l'hydrologie, pour que ce soit le relief erode — celui
# qu'on verra — qui porte l'ombre, et pas le bruit d'origine.
func _build_rain_shadow() -> void:
	var upwind := -WIND_DIR.normalized()
	for z in size_xz:
		for x in size_xz:
			var i := z * size_xz + x
			var h := _height_f[i]
			var blocked := 0.0
			for s in range(1, SHADOW_SAMPLES + 1):
				var sx := int(round(float(x) + upwind.x * SHADOW_STEP * float(s)))
				var sz := int(round(float(z) + upwind.y * SHADOW_STEP * float(s)))
				if sx < 0 or sz < 0 or sx >= size_xz or sz >= size_xz:
					break
				blocked = maxf(blocked, _height_f[sz * size_xz + sx] - h)
			_shadow[i] = clampf(blocked / SHADOW_SCALE, 0.0, 1.0)


# Etape 1 : le relief brut. Masque d'ile a contour irregulier, relief fractal
# sur les terres, fond marin qui s'enfonce au large, et une transition douce
# entre les deux — c'est cette transition qui traverse le niveau de la mer et
# fabrique la plage.
func _build_base_relief(seed_value: int) -> void:
	var height_noise := FastNoiseLite.new()
	height_noise.seed = seed_value
	height_noise.frequency = 0.0075
	height_noise.fractal_octaves = 5

	# Masque continental : un bruit fractal 2D basse frequence, SEUILLE, et
	# non une ondulation du rayon selon l'angle.
	#
	# C'est la difference entre une ile et un continent. Faire varier le rayon
	# avec l'angle ne peut produire qu'un disque bossele : chaque direction
	# n'a qu'une seule cote, donc jamais de golfe profond, de peninsule ni de
	# presqu'ile tenue par un isthme. Un masque 2D seuille, lui, decoupe un
	# littoral quelconque.
	var shape_noise := FastNoiseLite.new()
	shape_noise.seed = seed_value + 1
	shape_noise.frequency = CONTINENT_FREQUENCY
	shape_noise.fractal_octaves = CONTINENT_OCTAVES

	var seabed_noise := FastNoiseLite.new()
	seabed_noise.seed = seed_value + 2
	seabed_noise.frequency = 0.01

	var plain_noise := FastNoiseLite.new()
	plain_noise.seed = seed_value + 7
	plain_noise.frequency = PLAIN_FREQUENCY
	plain_noise.fractal_octaves = 2

	var center := float(size_xz) / 2.0

	for z in size_xz:
		# Un relevé par RANGEE, pas par colonne : l interface n a besoin que
		# d une valeur par image, et le test d annulation doit rester assez
		# frequent pour qu un changement de reglage reponde tout de suite.
		progress = 0.45 * float(z) / float(size_xz)
		if cancel_requested:
			return
		for x in size_xz:
			var dx := float(x) - center
			var dz := float(z) - center
			var dist := sqrt(dx * dx + dz * dz) / center

			# Attenuation radiale : elle garantit que le continent est
			# ENTIEREMENT entoure d'eau quoi que raconte le bruit. Sans elle,
			# le masque atteindrait les bords de la carte et le littoral y
			# serait coupe net.
			var radial := 1.0 - smoothstep(CONTINENT_REACH - OCEAN_MARGIN, CONTINENT_REACH, dist)
			var shape := 0.5 + 0.5 * shape_noise.get_noise_2d(float(x), float(z))
			var mask := shape * radial

			# 0 en pleine mer, 1 franchement a terre.
			var landness := smoothstep(
				COAST_THRESHOLD - COAST_BLEND, COAST_THRESHOLD + COAST_BLEND, mask)

			var offshore := clampf((COAST_THRESHOLD - mask) / COAST_THRESHOLD, 0.0, 1.0)
			var seabed := SEABED_BASE \
				+ seabed_noise.get_noise_2d(float(x), float(z)) * SEABED_AMPLITUDE \
				- offshore * SEABED_FALLOFF

			# Relief des terres, attenue la ou la carte designe une plaine.
			var flatness := smoothstep(
				PLAIN_THRESHOLD, PLAIN_THRESHOLD + PLAIN_BLEND,
				plain_noise.get_noise_2d(float(x), float(z)))
			var relief := height_noise.get_noise_2d(float(x), float(z)) * SURFACE_AMPLITUDE
			var land := SURFACE_BASE + lerpf(relief, relief * PLAIN_RELIEF, flatness)

			var index := z * size_xz + x
			_height_f[index] = lerpf(seabed, land, pow(landness, COAST_CURVE))

			# Continentalite : 0 sur le rivage, 1 au coeur des terres. Tiree du
			# masque et non de la distance au centre : avec un littoral
			# decoupe, le rayon ne mesure plus du tout la "profondeur dans les
			# terres" — le fond d'un golfe est proche du centre tout en etant
			# au bord de l'eau.
			_continentality[index] = clampf(
				(mask - COAST_THRESHOLD) / (1.0 - COAST_THRESHOLD), 0.0, 1.0)


# Etape 2 : hydrologie.
#
# On calcule ou l'eau s'ecoule, puis on creuse proportionnellement au debit.
# Deux passes suffisent a faire apparaitre un reseau ramifie ; au-dela le
# relief s'aplatit sans gagner en lisibilite.
func _apply_hydrology() -> void:
	for pass_index in EROSION_PASSES:
		_fill_depressions()
		_accumulate_flow()
		_incise()
	# Le lissage passe AVANT le dernier calcul de debit, et non apres.
	#
	# C'est celui-la qui sert a placer les rivieres, a tracer leur lit et a
	# nourrir l'humidite : il doit donc decrire le relief DEFINITIF. Calcule
	# avant le lissage, il decrivait un terrain qui n'existe plus au moment ou
	# on s'en sert, et le chenal creuse ne suivait pas tout a fait la vallee
	# qu'on voit.
	_smooth_heights()
	_fill_depressions()
	_accumulate_flow()


# Inondation prioritaire depuis la mer : voir FILL_EPSILON pour le pourquoi.
#
# On part du trait de cote et on remonte les terres en traitant toujours la
# colonne la plus basse encore atteignable. Chacune recoit `max(son altitude,
# celle d'ou l'eau vient + epsilon)` : une colonne haute garde la sienne, une
# colonne en creux prend le niveau du seuil qu'il a fallu franchir. Le petit
# epsilon donne au fond comble une pente residuelle vers son exutoire, sans
# quoi il serait parfaitement plat et la descente s'y arreterait tout autant.
#
# La file de priorite est un tableau de seaux et non un tas : l'altitude de
# sortie ne decroit jamais, donc il suffit de balayer les seaux dans l'ordre.
# Un tas binaire en GDScript couterait un appel interprete par comparaison,
# soit des dizaines de millions pour une carte de 800.
func _fill_depressions() -> void:
	var n := size_xz * size_xz
	_drain = _height_f.duplicate()

	var lo := INF
	var hi := -INF
	for h in _height_f:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	var scale := float(FILL_BUCKETS - 1) / maxf(hi - lo, 0.001)

	# Seaux en Array et non en PackedInt32Array : les tableaux compacts sont
	# des types VALEUR, et `seaux[b].append(...)` travaillerait sur une copie.
	var buckets: Array = []
	buckets.resize(FILL_BUCKETS)
	for b in FILL_BUCKETS:
		buckets[b] = []

	# La mer n'a rien a combler : on la ferme d'un bloc, et seul le trait de
	# cote sert d'amorce. L'inondation ne parcourt donc que les terres.
	var closed := PackedByteArray()
	closed.resize(n)
	var sea := float(SEA_LEVEL)
	for i in n:
		if _height_f[i] <= sea:
			closed[i] = 1

	var offsets := [-size_xz, size_xz, -1, 1,
		-size_xz - 1, -size_xz + 1, size_xz - 1, size_xz + 1]

	for z in range(1, size_xz - 1):
		for x in range(1, size_xz - 1):
			var i := z * size_xz + x
			if closed[i] == 0:
				continue
			for d in 8:
				if closed[i + offsets[d]] == 0:
					buckets[clampi(int((_drain[i] - lo) * scale),
						0, FILL_BUCKETS - 1)].append(i)
					break

	var b := 0
	while b < FILL_BUCKETS:
		var bucket: Array = buckets[b]
		if bucket.is_empty():
			b += 1
			continue
		# Vide le seau avant de le parcourir : traiter une colonne peut en
		# reverser dans CE seau-ci (meme altitude), et la boucle exterieure les
		# reprendra au tour suivant sans avancer.
		buckets[b] = []
		for c in bucket:
			var cx: int = c % size_xz
			@warning_ignore("integer_division")
			var cz: int = c / size_xz
			if cx <= 0 or cz <= 0 or cx >= size_xz - 1 or cz >= size_xz - 1:
				continue
			var level: float = _drain[c] + FILL_EPSILON
			for d in 8:
				var j: int = c + offsets[d]
				if closed[j] != 0:
					continue
				closed[j] = 1
				var w := maxf(_height_f[j], level)
				_drain[j] = w
				# Jamais en-deca du seau courant : l'altitude d'inondation ne
				# decroit pas, et c'est ce qui rend le balayage valide.
				buckets[maxi(clampi(int((w - lo) * scale), 0, FILL_BUCKETS - 1),
					b)].append(j)


# Accumulation d'ecoulement facon D8 : chaque colonne verse tout ce qu'elle a
# recu dans sa voisine la plus pentue, en traitant les colonnes de la plus
# haute a la plus basse. Une seule passe suffit donc a propager les debits de
# la crete jusqu'a la mer.
func _accumulate_flow() -> void:
	var n := size_xz * size_xz
	_flow.fill(1.0)
	_receiver.fill(-1)

	var order := _cells_by_descending_height()

	# Decalages des 8 voisins et leur distance, pour ne pas recalculer une
	# racine carree des millions de fois.
	var offsets := [-size_xz, size_xz, -1, 1, -size_xz - 1, -size_xz + 1, size_xz - 1, size_xz + 1]
	var inv_dist := [1.0, 1.0, 1.0, 1.0, 0.7071, 0.7071, 0.7071, 0.7071]

	for k in n:
		var i := order[k]
		var x := i % size_xz
		@warning_ignore("integer_division")
		var z := i / size_xz
		# Les colonnes du bord ne s'ecoulent nulle part : elles sont deja en
		# pleine mer, et les exclure evite huit tests de bornes par colonne.
		if x <= 0 or z <= 0 or x >= size_xz - 1 or z >= size_xz - 1:
			continue

		# La descente se decide sur le relief COMBLE et non sur le relief
		# visible : c'est la seule surface ou une descente ne s'arrete jamais
		# avant la mer (voir `_fill_depressions`).
		var h := _drain[i]
		var best := -1
		var best_drop := 0.0
		for d in 8:
			var j: int = i + offsets[d]
			var drop: float = (h - _drain[j]) * inv_dist[d]
			if drop > best_drop:
				best_drop = drop
				best = j
		if best >= 0:
			_flow[best] += _flow[i]
			# Le recepteur est conserve : c'est le squelette du reseau
			# hydrographique, et `river_network.gd` le reprend tel quel pour
			# tracer les chenaux plutot que de re-deriver la meme regle.
			_receiver[i] = best


# Tri des colonnes par altitude decroissante, par comptage sur une altitude
# quantifiee. Un tri comparatif passerait par un rappel GDScript a chaque
# comparaison, soit des millions d'appels ; ici tout est en acces tableau.
# L'ordre a l'interieur d'un meme seau est arbitraire, ce qui est sans
# consequence pour une accumulation d'ecoulement.
func _cells_by_descending_height() -> PackedInt32Array:
	var n := size_xz * size_xz
	var lo := INF
	var hi := -INF
	for i in n:
		var h := _drain[i]
		if h < lo:
			lo = h
		if h > hi:
			hi = h
	var span := maxf(hi - lo, 0.001)

	var counts := PackedInt32Array()
	counts.resize(SORT_BUCKETS)
	var bucket_of := PackedInt32Array()
	bucket_of.resize(n)
	for i in n:
		var b := int((_drain[i] - lo) / span * float(SORT_BUCKETS - 1))
		bucket_of[i] = b
		counts[b] += 1

	# Offsets en partant du seau le plus haut : ordre decroissant.
	var offsets := PackedInt32Array()
	offsets.resize(SORT_BUCKETS)
	var running := 0
	for b in range(SORT_BUCKETS - 1, -1, -1):
		offsets[b] = running
		running += counts[b]

	var out := PackedInt32Array()
	out.resize(n)
	for i in n:
		var b := bucket_of[i]
		out[offsets[b]] = i
		offsets[b] += 1
	return out


# Incision fluviale : erosion proportionnelle a debit^m x pente^n. Les
# colonnes a fort debit se creusent en vallees, les cretes entre bassins ne
# recoivent presque rien et restent hautes. C'est ce contraste qui donne au
# relief son aspect organique, qu'aucun reglage de bruit ne reproduit.
func _incise() -> void:
	var n := size_xz * size_xz
	var floor_y := float(SEA_LEVEL) - 1.0
	for i in n:
		var h := _height_f[i]
		if h <= float(SEA_LEVEL):
			continue
		var slope := _slope_f(i)
		var cut := EROSION_K * pow(_flow[i], EROSION_M) * pow(slope + 0.05, EROSION_N)
		_height_f[i] = maxf(h - minf(cut, EROSION_MAX), floor_y)


func _slope_f(i: int) -> float:
	var x := i % size_xz
	@warning_ignore("integer_division")
	var z := i / size_xz
	if x <= 0 or z <= 0 or x >= size_xz - 1 or z >= size_xz - 1:
		return 0.0
	var h := _height_f[i]
	var worst := 0.0
	worst = maxf(worst, absf(_height_f[i - 1] - h))
	worst = maxf(worst, absf(_height_f[i + 1] - h))
	worst = maxf(worst, absf(_height_f[i - size_xz] - h))
	worst = maxf(worst, absf(_height_f[i + size_xz] - h))
	return worst


# L'incision laisse des colonnes isolees d'un voxel de haut ou de bas. Une
# moyenne legere les efface sans raboter les vallees creusees juste avant.
func _smooth_heights() -> void:
	var n := size_xz * size_xz
	var smoothed := _height_f.duplicate()
	for z in range(1, size_xz - 1):
		for x in range(1, size_xz - 1):
			var i := z * size_xz + x
			var sum := _height_f[i] * 4.0 \
				+ _height_f[i - 1] + _height_f[i + 1] \
				+ _height_f[i - size_xz] + _height_f[i + size_xz]
			smoothed[i] = sum / 8.0
	_height_f = smoothed


# Etape 3 et 4 : climat puis biome, par colonne.
func _classify(seed_value: int, river_flow: float) -> void:
	var temp_noise := FastNoiseLite.new()
	temp_noise.seed = seed_value + 5
	temp_noise.frequency = 0.004

	var moist_noise := FastNoiseLite.new()
	moist_noise.seed = seed_value + 6
	moist_noise.frequency = 0.005

	var flow_scale := 1.0 / maxf(log(1.0 + river_flow * 4.0), 1.0)

	for z in size_xz:
		for x in size_xz:
			var i := z * size_xz + x
			var height := clampi(int(round(_height_f[i])), BEDROCK_DEPTH, size_y - 2)

			# Temperature : elle chute avec l'altitude (gradient adiabatique),
			# suit un gradient nord-sud sur la carte, et se brouille d'un
			# bruit basse frequence pour ne pas etre une fonction pure de la
			# position.
			var altitude := float(height - SEA_LEVEL)
			var temp := TEMP_BASE \
				- maxf(altitude, 0.0) * TEMP_LAPSE \
				+ latitude_temperature(z) \
				+ temp_noise.get_noise_2d(float(x), float(z)) * TEMP_NOISE
			temp = clampf(temp, 0.0, 1.0)

			# Humidite : l'air humide vient de la mer, donc l'interieur des
			# terres est sec ; une vallee a fort debit est humide quoi qu'il
			# arrive. C'est ce qui place le desert au coeur des terres chaudes
			# plutot que n'importe ou.
			var wet_from_flow := log(1.0 + _flow[i]) * flow_scale
			var moist := MOIST_BASE \
				+ (1.0 - _continentality[i]) * MOIST_COAST \
				+ clampf(wet_from_flow, 0.0, 1.0) * MOIST_RIVER \
				- _shadow[i] * MOIST_SHADOW \
				+ moist_noise.get_noise_2d(float(x), float(z)) * MOIST_NOISE
			moist = clampf(moist, 0.0, 1.0)

			# Le lit vient du RESEAU TRACE, pas d'une comparaison de debit.
			#
			# Le debit seuille ne designe qu'une ligne d'ecoulement large d'une
			# colonne ; le reseau, lui, connait la largeur reelle du chenal a
			# cet endroit. La colonne n'est plus baissee d'un voxel non plus :
			# `rivers.carve()` s'en charge, avec un vrai profil.
			var is_river := rivers.is_bed(x, z) and height > SEA_LEVEL

			_temperature[i] = temp
			_moisture[i] = moist
			_heights[i] = height
			_biomes[i] = _biome_for(height, _slope_f(i), temp, moist, is_river)


# Re-derive les altitudes ENTIERES depuis le champ flottant.
#
# `_classify` les a deja posees, mais le creusement des rivieres passe apres
# lui : sans ce rattrapage, `terrain_height()` rendrait l'altitude d'avant le
# chenal alors que `terrain_height_f()` rendrait celle d'apres. Le generateur
# lit les DEUX — l'une pour la distance signee, l'autre pour la stratification
# et l'epaisseur de surface — et le desaccord ferait flotter la matiere
# au-dessus du lit.
#
# Le clamp est le meme que dans `_classify`, et il doit le rester.
func _refresh_heights() -> void:
	for i in _heights.size():
		_heights[i] = clampi(int(round(_height_f[i])), BEDROCK_DEPTH, size_y - 2)


# Debit a partir duquel une colonne porte une riviere, choisi comme quantile
# des debits des colonnes emergees plutot qu'en valeur absolue : le debit
# accumule croit avec la surface de la carte, donc une constante en dur
# donnerait des rivieres partout sur une grande carte et aucune sur une
# petite. On passe par un histogramme sur le logarithme du debit, la
# distribution etant tres etalee (la plupart des colonnes ne drainent
# qu'elles-memes, quelques collecteurs drainent des milliers de colonnes).
func _river_threshold() -> float:
	var n := size_xz * size_xz
	var buckets := 256
	var land := 0
	var max_log := 0.0

	for i in n:
		if _height_f[i] <= float(SEA_LEVEL):
			continue
		land += 1
		var l := log(1.0 + _flow[i])
		if l > max_log:
			max_log = l

	if land == 0 or max_log <= 0.0:
		return INF

	var counts := PackedInt32Array()
	counts.resize(buckets)
	for i in n:
		if _height_f[i] <= float(SEA_LEVEL):
			continue
		counts[int(log(1.0 + _flow[i]) / max_log * float(buckets - 1))] += 1

	var target := maxi(int(float(land) * RIVER_FRACTION), 1)
	var accumulated := 0
	for b in range(buckets - 1, -1, -1):
		accumulated += counts[b]
		if accumulated >= target:
			return exp(float(b) / float(buckets - 1) * max_log) - 1.0
	return INF


# Croisement climat x altitude x pente, facon diagramme de Whittaker mais
# restreint aux matieres que le terrain sait rendre : pas de marecage, de
# jungle ni de savane, faute de quoi les distinguer a l'oeil (voir issue #30).
#
# L'ordre des tests compte : la pente l'emporte sur le climat, parce qu'une
# paroi raide est de la roche nue qu'elle soit gelee ou brulante — c'est la
# regle heritee de Terrain3D, et celle qui fait qu'une falaise ressemble a
# une falaise plutot qu'a une prairie verticale.
func _biome_for(height: int, slope: float, temp: float, moist: float, is_river: bool) -> int:
	if is_river:
		return Biome.RIVER
	if height < SEA_LEVEL - DEEP_SEA_DEPTH:
		return Biome.DEEP_SEA
	if height < SEA_LEVEL:
		return Biome.SHALLOW_SEA
	# Plage : seulement la ou la cote est plate. Une cote raide est une
	# falaise, et une falaise de sable n'existe pas.
	if height <= SEA_LEVEL + BEACH_BAND and slope <= BEACH_MAX_SLOPE:
		return Biome.BEACH
	if slope >= SLOPE_ROCK:
		return Biome.ROCK
	if temp < TEMP_SNOW:
		return Biome.SNOW
	# Le desert passe AVANT l'eboulis : un versant chaud et sec reste un
	# desert, pas un talus de pierraille. Dans l'ordre inverse, toute zone
	# aride un tant soit peu pentue etait classee eboulis, ce qui rognait le
	# desert sans rien dire — les seuils de climat avaient l'air en cause
	# alors que c'etait l'ordre des tests.
	if temp > TEMP_DESERT and moist < MOIST_DESERT:
		return Biome.DESERT
	if slope >= SLOPE_SCREE:
		return Biome.SCREE
	if moist > MOIST_FOREST:
		return Biome.FOREST
	return Biome.PLAINS


func surface_block(biome: int) -> int:
	match biome:
		Biome.DEEP_SEA:
			return TerrainMaterials.Type.GRAVEL
		Biome.SHALLOW_SEA, Biome.BEACH:
			return TerrainMaterials.Type.SAND
		Biome.RIVER:
			return TerrainMaterials.Type.GRAVEL
		Biome.DESERT:
			return TerrainMaterials.Type.SAND_PALE
		Biome.ROCK:
			return TerrainMaterials.Type.STONE
		Biome.SCREE:
			return TerrainMaterials.Type.GRAVEL
		Biome.SNOW:
			return TerrainMaterials.Type.SNOW
		_:
			return TerrainMaterials.Type.GRASS


# Couche meuble sous la surface d'un biome : (type de bloc, epaisseur).
# En-dessous, c'est de la pierre dans tous les cas.
func sub_surface(biome: int) -> Vector2i:
	match biome:
		Biome.DESERT:
			# Une dune est du sable sur une bonne epaisseur, pas un voile.
			return Vector2i(TerrainMaterials.Type.SAND_PALE, DESERT_SAND_DEPTH)
		Biome.SHALLOW_SEA, Biome.BEACH:
			return Vector2i(TerrainMaterials.Type.SAND, SAND_DEPTH)
		Biome.PLAINS, Biome.FOREST:
			return Vector2i(TerrainMaterials.Type.DIRT, DIRT_DEPTH)
		_:
			return Vector2i(TerrainMaterials.Type.STONE, 0)


# --- Sauvegarde/restauration pour le cache ---------------------------------

# Etat complet de la carte, pour `map_cache.gd`.
#
# Tous les champs sont stockes, y compris ceux qui ne servent qu'a l'ecran
# d'apercu (debit, ombre, continentalite). Les recalculer reviendrait a refaire
# l'hydrologie, c'est-a-dire l'essentiel du cout qu'on cherche justement a
# eviter.
#
# Le bruit des grottes n'est PAS stocke : il se rededuit de la seed, qui l'est.
func capture_state() -> Dictionary:
	return {
		"seed": seed_used,
		"size": size_xz,
		"height": size_y,
		"heights": _heights,
		"height_f": _height_f,
		"continentality": _continentality,
		"flow": _flow,
		"temperature": _temperature,
		"moisture": _moisture,
		"shadow": _shadow,
		"biomes": _biomes,
		"min_height": _min_height,
		"max_height": _max_height,
		# Le trace des chenaux, quelques dizaines de kilo-octets. Contrairement
		# au reseau de grottes, il ne peut PAS se re-deriver : les hauteurs en
		# cache sont deja creusees, donc les retracer suivrait le chenal
		# existant au lieu de le reproduire. C'est aussi ce dont aura besoin la
		# surface d'eau, quand elle viendra.
		"rivers": rivers.capture(),
	}


# Retourne false si l'etat ne correspond pas a cette carte : l'appelant doit
# alors regenerer plutot que de partir avec des tableaux de la mauvaise
# taille, qui planteraient a la premiere lecture.
func restore_state(data: Dictionary) -> bool:
	var columns := size_xz * size_xz
	for key in ["heights", "height_f", "continentality", "flow",
			"temperature", "moisture", "shadow", "biomes"]:
		if not data.has(key) or data[key].size() != columns:
			return false

	seed_used = int(data["seed"])
	_heights = data["heights"]
	_height_f = data["height_f"]
	_continentality = data["continentality"]
	_flow = data["flow"]
	_temperature = data["temperature"]
	_moisture = data["moisture"]
	_shadow = data["shadow"]
	_biomes = data["biomes"]
	_min_height = int(data["min_height"])
	_max_height = int(data["max_height"])
	rivers.restore(data.get("rivers", {}), size_xz)

	# Le reseau est RECALCULE plutot que stocke. Il derive entierement de la
	# graine et des hauteurs, toutes deux dans le cache : le stocker reviendrait
	# a sauvegarder ce qu'on sait deja reproduire, et ferait grossir une entree
	# de cache de plusieurs milliers de capsules.
	caves.build(self, seed_used, SEA_LEVEL, BEDROCK_DEPTH)
	return true


# Pente du terrain a cette colonne, en voxels de denivele par voxel parcouru.
# Publique parce que l'ecran de generation s'en sert pour montrer ou sont les
# terrains plats — la ou on peut s'installer.
func slope_at(x: int, z: int) -> float:
	if x < 0 or z < 0 or x >= size_xz or z >= size_xz:
		return 0.0
	return _slope_f(z * size_xz + x)
