class_name VoxelData
extends RefCounted

# Grille de voxels en 3 dimensions (issue #4) : une ile entouree par la mer.
#
# Difference fondamentale avec `scenes/world/platform.gd` : la plateforme
# actuelle stocke UNE hauteur par colonne, donc elle ne peut representer ni
# grotte, ni surplomb, ni toit separe du sol. Ici chaque voxel existe
# independamment, donc tout ca devient possible.
#
# Stockage : un seul PackedByteArray plat pour tout le monde (1 octet = 1
# type de bloc). Les Packed*Array de Godot sont en copie-sur-ecriture, donc
# garder un chunk dans une variable puis ecrire dedans ne modifierait PAS la
# copie rangee dans un dictionnaire, silencieusement — un tableau plat evite
# ce piege et rend l'acces voxel a une simple indexation, ce qui compte quand
# le mailleur lit 6 voisins par voxel.
#
# Le decoupage en chunks reste, mais uniquement comme unite de MAILLAGE
# (issue #3) : on ne remaille que le chunk touche par un creusage.

const CHUNK_SIZE := 16

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

# --- Geometrie de l'ile ----------------------------------------------------
const SEA_LEVEL := 30
const EDGE_RATIO := 0.62          # fraction de size/2 ou commence le rivage
const SHORE_WIDTH := 34.0         # largeur de la transition ile -> fond marin

# Le relief doit avoir assez d'ampleur pour que les sommets soient
# reellement froids : c'est l'altitude qui fabrique la neige, pas un seuil
# qu'on baisserait jusqu'a ce qu'un peu de blanc apparaisse. Une ile quatre
# fois plus grande supporte de toute facon un relief plus marque.
const SURFACE_BASE := 45.0
const SURFACE_AMPLITUDE := 14.0
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

# Fraction des colonnes emergees qui portent une riviere. Un seuil de debit
# EN DUR ne peut pas marcher : le debit d'une colonne est le nombre de
# colonnes qui s'ecoulent a travers elle, donc il croit avec la surface de la
# carte. La meme constante donnerait des rivieres partout sur une grande
# carte et aucune sur une petite. On vise donc un quantile.
const RIVER_FRACTION := 0.008

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
const TEMP_LATITUDE := 0.34       # gradient nord-sud sur toute la carte
const TEMP_NOISE := 0.12

const MOIST_BASE := 0.30
const MOIST_COAST := 0.26         # l'air humide vient de la mer
const MOIST_RIVER := 0.30         # une vallee a fort debit est humide
const MOIST_SHADOW := 0.52        # assechement sous le vent
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
const SHADOW_SCALE := 11.0        # denivele au vent au-dela duquel l'ombre sature

# --- Seuils de biome -------------------------------------------------------
const DEEP_SEA_DEPTH := 6
const BEACH_BAND := 4             # hauteur de plage au-dessus du niveau de la mer
const BEACH_MAX_SLOPE := 1        # au-dela, la cote est une falaise, pas une plage
const SLOPE_ROCK := 3
const SLOPE_SCREE := 2
const TEMP_SNOW := 0.30           # en-dessous : neige
const TEMP_DESERT := 0.56         # au-dessus, et sec : desert
const MOIST_DESERT := 0.38
const MOIST_FOREST := 0.58

# --- Sous-sol --------------------------------------------------------------
const BEDROCK_DEPTH := 3
const DIRT_DEPTH := 4
const SAND_DEPTH := 3
const DESERT_SAND_DEPTH := 6

# --- Grottes ---------------------------------------------------------------
const CAVE_THRESHOLD := 0.42
# Marge sous la surface en-deca de laquelle on ne creuse pas : evite que les
# grottes ouvrent des trous beants dans le sol, et garantit qu'une galerie
# sous le fond marin ne debouche jamais dans la mer — ce qui inonderait une
# galerie alors qu'on ne simule aucun ecoulement.
const CAVE_SURFACE_MARGIN := 4
# Profondeur au-dela de laquelle on cesse de creuser. Les voxels tres
# profonds ne sont ni visibles ni atteints en pratique, et c'est l'appel au
# bruit 3D qui domine le cout de la generation.
const CAVE_MAX_DEPTH := 24

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

var size_xz: int
var size_y: int
var chunks_xz: int
var chunks_y: int

var _voxels: PackedByteArray
var _heights: PackedInt32Array      # altitude du sol, entiere, apres erosion
var _height_f: PackedFloat32Array   # la meme, en flottant, pendant la generation
var _continentality: PackedFloat32Array # 0 au rivage, 1 au coeur des terres
var _flow: PackedFloat32Array       # debit accumule
# Champs climatiques conserves apres la generation : ils servent au placement
# de la vegetation et de la faune (chaque espece declarera ses tolerances),
# et ils rendent un calibrage de biome inspectable au lieu d'etre a deviner.
var _temperature: PackedFloat32Array
var _moisture: PackedFloat32Array
var _shadow: PackedFloat32Array     # ombre pluviometrique, 0 au vent, 1 sous le vent
var _biomes: PackedByteArray
# Marquage des chunks non vides par un tableau de drapeaux plutot que par un
# dictionnaire de Vector3i. Le remplissage ecrit des millions de voxels, et
# une insertion de dictionnaire par voxel (construction de la cle comprise)
# coutait plus cher que l'ecriture du voxel elle-meme.
var _chunk_used: PackedByteArray


func _init(world_size_xz: int = 600, world_size_y: int = 64) -> void:
	size_xz = world_size_xz
	size_y = world_size_y
	chunks_xz = int(ceil(float(size_xz) / float(CHUNK_SIZE)))
	chunks_y = int(ceil(float(size_y) / float(CHUNK_SIZE)))

	var columns := size_xz * size_xz
	_voxels = PackedByteArray()
	_voxels.resize(columns * size_y)
	_heights = PackedInt32Array()
	_heights.resize(columns)
	_height_f = PackedFloat32Array()
	_height_f.resize(columns)
	_continentality = PackedFloat32Array()
	_continentality.resize(columns)
	_flow = PackedFloat32Array()
	_flow.resize(columns)
	_temperature = PackedFloat32Array()
	_temperature.resize(columns)
	_moisture = PackedFloat32Array()
	_moisture.resize(columns)
	_shadow = PackedFloat32Array()
	_shadow.resize(columns)
	_biomes = PackedByteArray()
	_biomes.resize(columns)
	_chunk_used = PackedByteArray()
	_chunk_used.resize(chunks_xz * chunks_y * chunks_xz)


# --- Acces ----------------------------------------------------------------

func is_inside(x: int, y: int, z: int) -> bool:
	return x >= 0 and y >= 0 and z >= 0 \
		and x < size_xz and y < size_y and z < size_xz


func get_voxel(x: int, y: int, z: int) -> int:
	if not is_inside(x, y, z):
		return BlockLibrary.Type.AIR
	return _voxels[(y * size_xz + z) * size_xz + x]


func set_voxel(x: int, y: int, z: int, type: int) -> void:
	if not is_inside(x, y, z):
		return
	_voxels[(y * size_xz + z) * size_xz + x] = type
	if type != BlockLibrary.Type.AIR:
		@warning_ignore("integer_division")
		_mark_chunk(x / CHUNK_SIZE, y / CHUNK_SIZE, z / CHUNK_SIZE)


func _mark_chunk(cx: int, cy: int, cz: int) -> void:
	_chunk_used[(cy * chunks_xz + cz) * chunks_xz + cx] = 1


# Copie une rangee de voxels alignee sur X dans un tampon de `count` octets.
#
# Sert au mailleur, qui travaille sur une copie locale du chunk plus un voxel
# de bordure. Une rangee en X est contigue en memoire, donc le cas courant se
# resout en une seule tranche memoire au lieu de `count` appels a get_voxel.
# Hors du monde, les octets restent a zero, c'est-a-dire AIR, ce qui est le
# bon voisin pour une face au bord de la carte.
func copy_row(y: int, z: int, x0: int, count: int) -> PackedByteArray:
	if y < 0 or y >= size_y or z < 0 or z >= size_xz:
		var empty := PackedByteArray()
		empty.resize(count)
		return empty

	var row_base := (y * size_xz + z) * size_xz
	if x0 >= 0 and x0 + count <= size_xz:
		return _voxels.slice(row_base + x0, row_base + x0 + count)

	var out := PackedByteArray()
	out.resize(count)
	for i in count:
		var x := x0 + i
		if x >= 0 and x < size_xz:
			out[i] = _voxels[row_base + x]
	return out


func chunk_of(x: int, y: int, z: int) -> Vector3i:
	@warning_ignore("integer_division")
	return Vector3i(x / CHUNK_SIZE, y / CHUNK_SIZE, z / CHUNK_SIZE)


func used_chunk_keys() -> Array:
	var out := []
	for cy in chunks_y:
		for cz in chunks_xz:
			for cx in chunks_xz:
				if _chunk_used[(cy * chunks_xz + cz) * chunks_xz + cx] == 1:
					out.append(Vector3i(cx, cy, cz))
	return out


# Altitude du sol d'une colonne, eau exclue. C'est la donnee a utiliser pour
# poser quelque chose par terre — contrairement a un scan du haut vers le
# bas, qui s'arreterait sur la surface de la mer.
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
	_build_base_relief(seed_value)
	_apply_hydrology()
	_build_rain_shadow()
	_classify(seed_value)
	_fill_voxels(seed_value)


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

	var edge_noise := FastNoiseLite.new()
	edge_noise.seed = seed_value + 1

	var seabed_noise := FastNoiseLite.new()
	seabed_noise.seed = seed_value + 2
	seabed_noise.frequency = 0.01

	var center := float(size_xz) / 2.0
	var base_radius := center * EDGE_RATIO

	for z in size_xz:
		for x in size_xz:
			var dx := float(x) - center
			var dz := float(z) - center
			var dist := sqrt(dx * dx + dz * dz)
			var angle := atan2(dz, dx)
			var local_radius := base_radius + edge_noise.get_noise_1d(angle * 12.0) * center * 0.15

			var offshore := clampf((dist - local_radius) / SEABED_FALLOFF_RANGE, 0.0, 1.0)
			var seabed := SEABED_BASE \
				+ seabed_noise.get_noise_2d(float(x), float(z)) * SEABED_AMPLITUDE \
				- offshore * SEABED_FALLOFF

			var land := SURFACE_BASE + height_noise.get_noise_2d(float(x), float(z)) * SURFACE_AMPLITUDE

			var shore_blend := smoothstep(0.0, SHORE_WIDTH, local_radius - dist)
			var index := z * size_xz + x
			_height_f[index] = lerpf(seabed, land, shore_blend)

			# Continentalite : 0 sur le rivage, 1 au coeur des terres, sur une
			# echelle bien plus large que la plage. C'est elle qui rendra
			# l'interieur sec (donc desertique) et les cotes humides.
			_continentality[index] = clampf((local_radius - dist) / (local_radius * 0.75), 0.0, 1.0)


# Etape 2 : hydrologie.
#
# On calcule ou l'eau s'ecoule, puis on creuse proportionnellement au debit.
# Deux passes suffisent a faire apparaitre un reseau ramifie ; au-dela le
# relief s'aplatit sans gagner en lisibilite.
func _apply_hydrology() -> void:
	for pass_index in EROSION_PASSES:
		_accumulate_flow()
		_incise()
	# Le debit final est recalcule apres la derniere incision : c'est celui-la
	# qui sert a placer les rivieres et a nourrir l'humidite, donc il doit
	# correspondre au relief definitif et non a celui d'avant erosion.
	_accumulate_flow()
	_smooth_heights()


# Accumulation d'ecoulement facon D8 : chaque colonne verse tout ce qu'elle a
# recu dans sa voisine la plus pentue, en traitant les colonnes de la plus
# haute a la plus basse. Une seule passe suffit donc a propager les debits de
# la crete jusqu'a la mer.
func _accumulate_flow() -> void:
	var n := size_xz * size_xz
	_flow.fill(1.0)

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

		var h := _height_f[i]
		var best := -1
		var best_drop := 0.0
		for d in 8:
			var j: int = i + offsets[d]
			var drop: float = (h - _height_f[j]) * inv_dist[d]
			if drop > best_drop:
				best_drop = drop
				best = j
		if best >= 0:
			_flow[best] += _flow[i]


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
		var h := _height_f[i]
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
		var b := int((_height_f[i] - lo) / span * float(SORT_BUCKETS - 1))
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
func _classify(seed_value: int) -> void:
	var temp_noise := FastNoiseLite.new()
	temp_noise.seed = seed_value + 5
	temp_noise.frequency = 0.004

	var moist_noise := FastNoiseLite.new()
	moist_noise.seed = seed_value + 6
	moist_noise.frequency = 0.005

	var river_flow := _river_threshold()
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
				+ (float(z) / float(size_xz) - 0.5) * TEMP_LATITUDE \
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

			var is_river := _flow[i] >= river_flow and height > SEA_LEVEL
			if is_river:
				# Le lit est creuse d'un voxel pour que l'eau y tienne au lieu
				# de napper la plaine autour.
				height = maxi(height - 1, SEA_LEVEL)

			_temperature[i] = temp
			_moisture[i] = moist
			_heights[i] = height
			_biomes[i] = _biome_for(height, _slope_i(i, height), temp, moist, is_river)


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


# Pente en voxels entiers, calculee sur les altitudes definitives.
func _slope_i(i: int, height: int) -> int:
	var x := i % size_xz
	@warning_ignore("integer_division")
	var z := i / size_xz
	var worst := 0
	if x > 0:
		worst = maxi(worst, absi(int(round(_height_f[i - 1])) - height))
	if x < size_xz - 1:
		worst = maxi(worst, absi(int(round(_height_f[i + 1])) - height))
	if z > 0:
		worst = maxi(worst, absi(int(round(_height_f[i - size_xz])) - height))
	if z < size_xz - 1:
		worst = maxi(worst, absi(int(round(_height_f[i + size_xz])) - height))
	return worst


# Croisement climat x altitude x pente, facon diagramme de Whittaker mais
# restreint aux blocs que KayKit Block Bits fournit reellement : pas de
# marecage, de jungle ni de savane, faute de blocs pour les rendre credibles
# (voir issue #30).
#
# L'ordre des tests compte : la pente l'emporte sur le climat, parce qu'une
# paroi raide est de la roche nue qu'elle soit gelee ou brulante — c'est la
# regle heritee de Terrain3D, et celle qui fait qu'une falaise ressemble a
# une falaise plutot qu'a une prairie verticale.
func _biome_for(height: int, slope: int, temp: float, moist: float, is_river: bool) -> int:
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
	if slope >= SLOPE_SCREE:
		return Biome.SCREE
	if temp > TEMP_DESERT and moist < MOIST_DESERT:
		return Biome.DESERT
	if moist > MOIST_FOREST:
		return Biome.FOREST
	return Biome.PLAINS


func _fill_voxels(seed_value: int) -> void:
	var cave_noise := FastNoiseLite.new()
	cave_noise.seed = seed_value + 3
	cave_noise.frequency = 0.045
	cave_noise.fractal_octaves = 2

	var layer := size_xz * size_xz

	for z in size_xz:
		@warning_ignore("integer_division")
		var cz := z / CHUNK_SIZE
		for x in size_xz:
			var i := z * size_xz + x
			var top := _heights[i]
			var biome := _biomes[i]
			var surface_type := _surface_block(biome)
			# La stratification ne depend que du biome : on la resout une
			# fois par colonne au lieu d'appeler une fonction par voxel.
			var strata := _sub_surface(biome)
			var sub_type := strata.x
			var sub_depth := strata.y

			# Ecriture directe dans le tableau plat. Passer par set_voxel
			# couterait un appel de fonction, une verification de bornes et
			# un marquage de chunk PAR VOXEL, soit des dizaines de millions
			# d'operations sur une grande carte — plus cher que l'ecriture
			# du voxel elle-meme.
			for y in range(0, top + 1):
				var type := BlockLibrary.Type.STONE_DARK
				# Bedrock : les couches du fond ne sont ni creusables ni
				# percables par une grotte, donc le bas du monde reste une
				# coque etanche.
				if y >= BEDROCK_DEPTH:
					var depth := top - y
					if depth > CAVE_SURFACE_MARGIN and depth < CAVE_MAX_DEPTH \
							and cave_noise.get_noise_3d(float(x), float(y), float(z)) > CAVE_THRESHOLD:
						continue
					if depth == 0:
						type = surface_type
					elif depth <= sub_depth:
						type = sub_type
					else:
						type = BlockLibrary.Type.STONE
				_voxels[y * layer + i] = type

			# L'eau n'est posee QUE au-dessus du sol, jamais a l'interieur.
			# C'est ce qui garantit qu'on ne tombe jamais sur une tuile d'eau
			# en creusant dans l'ile : il n'y en a pas a trouver.
			var highest := top
			if top < SEA_LEVEL:
				for y in range(top + 1, SEA_LEVEL + 1):
					_voxels[y * layer + i] = BlockLibrary.Type.WATER
				highest = SEA_LEVEL
			elif biome == Biome.RIVER and top + 1 < size_y:
				_voxels[(top + 1) * layer + i] = BlockLibrary.Type.WATER
				highest = top + 1

			@warning_ignore("integer_division")
			var cx := x / CHUNK_SIZE
			@warning_ignore("integer_division")
			var top_chunk := highest / CHUNK_SIZE
			for cy in range(0, top_chunk + 1):
				_mark_chunk(cx, cy, cz)


func _surface_block(biome: int) -> int:
	match biome:
		Biome.DEEP_SEA:
			return BlockLibrary.Type.GRAVEL
		Biome.SHALLOW_SEA, Biome.BEACH:
			return BlockLibrary.Type.SAND
		Biome.RIVER:
			return BlockLibrary.Type.GRAVEL
		Biome.DESERT:
			return BlockLibrary.Type.SAND_PALE
		Biome.ROCK:
			return BlockLibrary.Type.STONE
		Biome.SCREE:
			return BlockLibrary.Type.GRAVEL
		Biome.SNOW:
			return BlockLibrary.Type.SNOW
		_:
			return BlockLibrary.Type.GRASS


# Couche meuble sous la surface d'un biome : (type de bloc, epaisseur).
# En-dessous, c'est de la pierre dans tous les cas.
func _sub_surface(biome: int) -> Vector2i:
	match biome:
		Biome.DESERT:
			# Une dune est du sable sur une bonne epaisseur, pas un voile.
			return Vector2i(BlockLibrary.Type.SAND_PALE, DESERT_SAND_DEPTH)
		Biome.SHALLOW_SEA, Biome.BEACH:
			return Vector2i(BlockLibrary.Type.SAND, SAND_DEPTH)
		Biome.PLAINS, Biome.FOREST:
			return Vector2i(BlockLibrary.Type.DIRT, DIRT_DEPTH)
		_:
			return Vector2i(BlockLibrary.Type.STONE, 0)
