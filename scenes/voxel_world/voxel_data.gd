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
# type de bloc). A 300x64x300 ca fait environ 5,8 Mo — negligeable, et ca
# evite deux pieges d'un stockage par chunks :
#
# - les Packed*Array de Godot sont en copie-sur-ecriture, donc garder un
#   chunk dans une variable puis ecrire dedans ne modifie PAS la copie
#   rangee dans le dictionnaire, silencieusement ;
# - un acces voxel devient une simple indexation, sans recherche de chunk,
#   ce qui compte quand le mailleur fait 6 lectures de voisins par voxel.
#
# Le decoupage en chunks reste, mais uniquement comme unite de MAILLAGE
# (issue #3) : on ne remaille que le chunk touche par un creusage.

const CHUNK_SIZE := 16

# --- Regles de construction du monde ---------------------------------------
#
# Inspirees de Terrain3D, dont l'auto-shader repose sur deux regles simples
# et tres efficaces qu'on transpose ici en choix de blocs :
#
#   1. BANDES D'ALTITUDE, ancrees sur le niveau de la mer : fond marin,
#      plage, prairie, sommets. C'est ce qui donne la lecture immediate d'un
#      relief.
#   2. SURCHARGE PAR LA PENTE : au-dela d'un certain denivele, la surface
#      passe en roche nue quelle que soit son altitude. C'est la regle qui
#      fait qu'une falaise ressemble a une falaise et pas a une prairie
#      verticale, et c'est celle qui manque le plus quand on ne fait que des
#      bandes d'altitude.
#
# Les deux seuils sont brouilles par un bruit pour que les transitions ne
# soient pas des courbes de niveau parfaites.
#
# Les biomes sont volontairement restreints a ce que le pack KayKit Block
# Bits fournit reellement (voir issue #30) — pas de marecage ni de desert,
# faute de blocs pour les rendre credibles :
#
#   Biome            | Bloc de surface | Sous la surface
#   -----------------|-----------------|-----------------
#   Mer profonde     | gravel          | stone
#   Mer cotiere      | sand            | sand -> stone
#   Plage            | sand            | sand -> stone
#   Prairie          | grass           | dirt -> stone
#   Rocaille (pente) | stone           | stone
#   Eboulis (pente)  | gravel          | stone
#   Sommets          | snow            | stone
#
# Le fond de la carte est en stone_dark, qui sert de bedrock indestructible
# (voir BlockLibrary.INDESTRUCTIBLE).

enum Biome {
	DEEP_SEA,
	SHALLOW_SEA,
	BEACH,
	PLAINS,
	ROCK,
	SCREE,
	PEAK,
}

const SEA_LEVEL := 30             # altitude de la surface de l'eau
const EDGE_RATIO := 0.62          # fraction de size/2 ou commence le rivage
const SHORE_WIDTH := 16.0         # largeur de la transition ile -> fond marin

const SURFACE_BASE := 40.0        # altitude moyenne des terres
const SURFACE_AMPLITUDE := 7.0    # amplitude du relief de l'ile
const SEABED_BASE := 22.0         # altitude moyenne du fond marin
const SEABED_AMPLITUDE := 2.5
const SEABED_FALLOFF := 7.0       # de combien le fond s'enfonce au large
const SEABED_FALLOFF_RANGE := 40.0

const BEDROCK_DEPTH := 3          # couches indestructibles au fond de la carte
const BEACH_BAND := 2             # hauteur de sable au-dessus du niveau de la mer
const DEEP_SEA_DEPTH := 6         # profondeur a partir de laquelle le fond passe en gravier
const SNOW_LEVEL := 45            # altitude a partir de laquelle il neige
const SLOPE_ROCK := 3             # denivele (voxels) au-dela duquel c'est de la roche nue
const SLOPE_SCREE := 2            # denivele au-dela duquel c'est de l'eboulis
const DIRT_DEPTH := 4             # epaisseur de terre sous une prairie
const SAND_DEPTH := 3             # epaisseur de sable sous une plage ou un fond marin

# Seuil du bruit 3D au-dessus duquel un voxel est creuse en grotte. Plus le
# seuil est haut, plus les grottes sont rares et etroites.
const CAVE_THRESHOLD := 0.42
# Marge sous la surface en-deca de laquelle on ne creuse pas. Elle a deux
# roles : eviter que les grottes ouvrent des trous beants dans le sol, et
# garantir qu'une grotte creusee sous le fond marin ne debouche jamais dans
# la mer — ce qui inonderait une galerie alors qu'on ne simule aucun ecoulement.
const CAVE_SURFACE_MARGIN := 4

var size_xz: int
var size_y: int
var chunks_xz: int
var chunks_y: int

var _voxels: PackedByteArray
# Altitude du sol (hors eau) par colonne. Conservee apres la generation : la
# pente en a besoin, le placement des props et du joueur aussi, et ca evite
# de rescanner une colonne de haut en bas pour retrouver le sol.
var _heights: PackedInt32Array
# Cles des chunks contenant au moins un voxel non-vide. Sans ca le mailleur
# passerait l'essentiel de son temps sur des chunks de ciel.
var _used_chunks: Dictionary = {}


func _init(world_size_xz: int = 300, world_size_y: int = 64) -> void:
	size_xz = world_size_xz
	size_y = world_size_y
	chunks_xz = int(ceil(float(size_xz) / float(CHUNK_SIZE)))
	chunks_y = int(ceil(float(size_y) / float(CHUNK_SIZE)))
	_voxels = PackedByteArray()
	_voxels.resize(size_xz * size_y * size_xz) # zeros = AIR
	_heights = PackedInt32Array()
	_heights.resize(size_xz * size_xz)


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
		_used_chunks[chunk_of(x, y, z)] = true


# Copie une rangee de voxels alignee sur X dans un tampon de `count` octets.
#
# Sert au mailleur, qui travaille sur une copie locale du chunk plus un voxel
# de bordure. Une rangee en X est contigue en memoire (l'index est
# (y * size + z) * size + x), donc le cas courant — rangee entierement dans
# le monde — se resout en une seule tranche memoire au lieu de `count`
# appels a get_voxel. Hors du monde, les octets restent a zero, c'est-a-dire
# AIR, ce qui est le bon voisin pour une face au bord de la carte.
func copy_row(y: int, z: int, x0: int, count: int) -> PackedByteArray:
	if y < 0 or y >= size_y or z < 0 or z >= size_xz:
		var empty := PackedByteArray()
		empty.resize(count)
		return empty

	var row_base := (y * size_xz + z) * size_xz
	if x0 >= 0 and x0 + count <= size_xz:
		return _voxels.slice(row_base + x0, row_base + x0 + count)

	# Rangee a cheval sur le bord de la carte : repli voxel par voxel.
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
	return _used_chunks.keys()


# Altitude du sol d'une colonne, eau exclue. C'est la donnee a utiliser pour
# poser quelque chose par terre — contrairement a un scan du haut vers le
# bas, qui s'arreterait sur la surface de la mer.
func terrain_height(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= size_xz or z >= size_xz:
		return -1
	return _heights[z * size_xz + x]


func is_underwater(x: int, z: int) -> bool:
	var h := terrain_height(x, z)
	return h >= 0 and h < SEA_LEVEL


# --- Generation ------------------------------------------------------------

# Tout part de la seed : meme seed -> meme ile, chez les deux joueurs comme
# d'une session a l'autre. C'est ce qui rendra la sauvegarde possible (stocker
# la seed plutot que le terrain). Attention : des que la seed sera tiree au
# hasard par partie, elle devra etre TRANSMISE au client et ne pourra plus
# etre une constante compilee — voir issue #31.
func generate(seed_value: int) -> void:
	_build_height_field(seed_value)
	_fill_voxels(seed_value)


# Passe 1 : l'altitude du sol de chaque colonne, ile et fond marin confondus.
# On la calcule entierement avant de remplir quoi que ce soit, parce que la
# regle de pente a besoin des colonnes voisines.
func _build_height_field(seed_value: int) -> void:
	var height_noise := FastNoiseLite.new()
	height_noise.seed = seed_value
	height_noise.frequency = 0.015
	height_noise.fractal_octaves = 4

	var edge_noise := FastNoiseLite.new()
	edge_noise.seed = seed_value + 1

	var seabed_noise := FastNoiseLite.new()
	seabed_noise.seed = seed_value + 2
	seabed_noise.frequency = 0.02

	var center := float(size_xz) / 2.0
	var base_radius := center * EDGE_RATIO

	for z in size_xz:
		for x in size_xz:
			var dx := float(x) - center
			var dz := float(z) - center
			var dist := sqrt(dx * dx + dz * dz)
			# Le rayon varie selon l'angle : contour irregulier plutot qu'un
			# disque parfait (meme principe que platform.gd).
			var angle := atan2(dz, dx)
			var local_radius := base_radius + edge_noise.get_noise_1d(angle * 12.0) * center * 0.15

			# Fond marin : il s'enfonce progressivement en s'eloignant du
			# rivage, sinon la mer est une dalle plate.
			var offshore := clampf((dist - local_radius) / SEABED_FALLOFF_RANGE, 0.0, 1.0)
			var seabed := SEABED_BASE \
				+ seabed_noise.get_noise_2d(float(x), float(z)) * SEABED_AMPLITUDE \
				- offshore * SEABED_FALLOFF

			# Terres : le relief de l'ile proprement dite.
			var land := SURFACE_BASE + height_noise.get_noise_2d(float(x), float(z)) * SURFACE_AMPLITUDE

			# Transition douce entre les deux. C'est cette bande qui traverse
			# le niveau de la mer et fabrique la plage : sans elle, l'ile
			# serait une falaise verticale plantee dans l'eau.
			var inland := smoothstep(0.0, SHORE_WIDTH, local_radius - dist)
			var height := lerpf(seabed, land, inland)

			_heights[z * size_xz + x] = clampi(int(round(height)), BEDROCK_DEPTH, size_y - 2)


# Passe 2 : remplissage. Chaque colonne est pleine du fond de la carte
# jusqu'a son altitude de sol, puis remplie d'eau jusqu'au niveau de la mer
# si elle est immergee.
func _fill_voxels(seed_value: int) -> void:
	var cave_noise := FastNoiseLite.new()
	cave_noise.seed = seed_value + 3
	cave_noise.frequency = 0.045
	cave_noise.fractal_octaves = 2

	var jitter_noise := FastNoiseLite.new()
	jitter_noise.seed = seed_value + 4
	jitter_noise.frequency = 0.08

	for z in size_xz:
		for x in size_xz:
			var top := _heights[z * size_xz + x]
			var slope := _slope_at(x, z)
			var jitter := jitter_noise.get_noise_2d(float(x), float(z)) * 2.0
			var biome := _biome_at(top, slope, jitter)
			var surface_type := _surface_block(biome)

			for y in range(0, top + 1):
				# Bedrock : les couches du fond ne sont ni creusables ni
				# percables par une grotte, donc le bas du monde reste une
				# coque etanche.
				if y < BEDROCK_DEPTH:
					set_voxel(x, y, z, BlockLibrary.Type.STONE_DARK)
					continue

				var depth := top - y
				if depth > CAVE_SURFACE_MARGIN:
					if cave_noise.get_noise_3d(float(x), float(y), float(z)) > CAVE_THRESHOLD:
						continue

				set_voxel(x, y, z, _block_at_depth(biome, surface_type, depth))

			# L'eau n'est posee QUE au-dessus du sol, jamais a l'interieur.
			# C'est ce qui garantit qu'on ne tombe jamais sur une tuile d'eau
			# en creusant dans l'ile : il n'y en a pas a trouver.
			if top < SEA_LEVEL:
				for y in range(top + 1, SEA_LEVEL + 1):
					set_voxel(x, y, z, BlockLibrary.Type.WATER)


# Denivele maximal entre cette colonne et ses 4 voisines, en voxels. C'est la
# mesure de pente qui pilote la surcharge "roche nue" heritee de Terrain3D.
func _slope_at(x: int, z: int) -> int:
	var h := _heights[z * size_xz + x]
	var worst := 0
	if x > 0:
		worst = maxi(worst, absi(_heights[z * size_xz + x - 1] - h))
	if x < size_xz - 1:
		worst = maxi(worst, absi(_heights[z * size_xz + x + 1] - h))
	if z > 0:
		worst = maxi(worst, absi(_heights[(z - 1) * size_xz + x] - h))
	if z < size_xz - 1:
		worst = maxi(worst, absi(_heights[(z + 1) * size_xz + x] - h))
	return worst


func _biome_at(top: int, slope: int, jitter: float) -> int:
	var level := float(top) + jitter

	# Sous l'eau, la pente ne change rien : on ne voit du fond que sa nature.
	if level < float(SEA_LEVEL - DEEP_SEA_DEPTH):
		return Biome.DEEP_SEA
	if level < float(SEA_LEVEL):
		return Biome.SHALLOW_SEA
	if level <= float(SEA_LEVEL + BEACH_BAND):
		return Biome.BEACH

	# Regle de pente : elle l'emporte sur l'altitude. Une paroi raide est de
	# la roche, qu'elle soit a 31 ou a 48 voxels.
	if slope >= SLOPE_ROCK:
		return Biome.ROCK
	if level >= float(SNOW_LEVEL):
		return Biome.PEAK
	if slope >= SLOPE_SCREE:
		return Biome.SCREE
	return Biome.PLAINS


func _surface_block(biome: int) -> int:
	match biome:
		Biome.DEEP_SEA:
			return BlockLibrary.Type.GRAVEL
		Biome.SHALLOW_SEA, Biome.BEACH:
			return BlockLibrary.Type.SAND
		Biome.ROCK:
			return BlockLibrary.Type.STONE
		Biome.SCREE:
			return BlockLibrary.Type.GRAVEL
		Biome.PEAK:
			return BlockLibrary.Type.SNOW
		_:
			return BlockLibrary.Type.GRASS


func _block_at_depth(biome: int, surface_type: int, depth: int) -> int:
	if depth == 0:
		return surface_type

	match biome:
		Biome.SHALLOW_SEA, Biome.BEACH:
			return BlockLibrary.Type.SAND if depth <= SAND_DEPTH else BlockLibrary.Type.STONE
		Biome.PLAINS:
			return BlockLibrary.Type.DIRT if depth <= DIRT_DEPTH else BlockLibrary.Type.STONE
		_:
			# Rocaille, eboulis, sommets et fond marin profond : de la roche
			# des le premier voxel sous la surface.
			return BlockLibrary.Type.STONE
