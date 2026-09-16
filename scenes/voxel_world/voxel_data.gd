class_name VoxelData
extends RefCounted

# Grille de voxels en 3 dimensions (issue #4).
#
# Difference fondamentale avec `scenes/world/platform.gd` : la plateforme
# actuelle stocke UNE hauteur par colonne, donc elle ne peut representer ni
# grotte, ni surplomb, ni toit separe du sol. Ici chaque voxel existe
# independamment, donc tout ca devient possible.
#
# Stockage : un seul PackedByteArray plat pour tout le monde (1 octet = 1
# type de bloc). A 256x64x256 ca fait 4,2 Mo, a 300x64x300 environ 5,8 Mo —
# negligeable, et ca evite deux pieges d'un stockage par chunks :
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

# --- Parametres de generation ---------------------------------------------
# Le contour irregulier et le rivage en pente sont repris de platform.gd pour
# que l'ile garde la meme silhouette. S'y ajoutent une epaisseur et une
# quille, puisqu'on a maintenant un volume et plus un simple feuillet.

const EDGE_RATIO := 0.85          # fraction de size/2 ou commence le rivage
const SURFACE_BASE := 40.0        # altitude moyenne du sol, en voxels
const SURFACE_AMPLITUDE := 6.0    # amplitude du relief
const SHORE_Y := 33.0             # altitude du sol au bord de l'ile
const KEEL_MAX := 24.0            # profondeur max de la quille, au centre
const KEEL_MIN := 2.0             # epaisseur minimale, au rivage
const SAND_BAND := 2.5            # hauteur de plage au-dessus du rivage
const SNOW_Y := 44.0              # altitude a partir de laquelle il neige
const DIRT_DEPTH := 4             # epaisseur de terre sous la surface
const DARK_STONE_DEPTH := 3       # epaisseur de roche sombre au fond

# Seuil du bruit 3D au-dessus duquel un voxel est creuse en grotte. Plus le
# seuil est haut, plus les grottes sont rares et etroites.
const CAVE_THRESHOLD := 0.42
# On ne creuse pas juste sous la surface : sans cette marge, les grottes
# ouvrent des trous beants dans le sol au lieu de rester souterraines.
const CAVE_SURFACE_MARGIN := 3

var size_xz: int
var size_y: int
var chunks_xz: int
var chunks_y: int

var _voxels: PackedByteArray
# Cles des chunks contenant au moins un voxel plein. Une ile occupe une
# tranche mince de sa boite englobante, donc sans ca le mailleur passerait
# l'essentiel de son temps sur des chunks de ciel vide.
var _solid_chunks: Dictionary = {}


func _init(world_size_xz: int = 256, world_size_y: int = 64) -> void:
	size_xz = world_size_xz
	size_y = world_size_y
	chunks_xz = int(ceil(float(size_xz) / float(CHUNK_SIZE)))
	chunks_y = int(ceil(float(size_y) / float(CHUNK_SIZE)))
	_voxels = PackedByteArray()
	_voxels.resize(size_xz * size_y * size_xz) # zeros = AIR


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
		_solid_chunks[chunk_of(x, y, z)] = true


func chunk_of(x: int, y: int, z: int) -> Vector3i:
	@warning_ignore("integer_division")
	return Vector3i(x / CHUNK_SIZE, y / CHUNK_SIZE, z / CHUNK_SIZE)


func solid_chunk_keys() -> Array:
	return _solid_chunks.keys()


# Altitude du premier voxel plein rencontre en descendant depuis le ciel.
# Sert a poser quelque chose sur le sol (joueur, props, vegetation) sans
# avoir a connaitre la forme du terrain. Retourne -1 si la colonne est vide.
func surface_y(x: int, z: int) -> int:
	if x < 0 or z < 0 or x >= size_xz or z >= size_xz:
		return -1
	for y in range(size_y - 1, -1, -1):
		if _voxels[(y * size_xz + z) * size_xz + x] != BlockLibrary.Type.AIR:
			return y
	return -1


# --- Generation ------------------------------------------------------------

# Tout part de la seed : meme seed -> meme ile, chez les deux joueurs comme
# d'une session a l'autre. C'est ce qui rendra la sauvegarde possible (stocker
# la seed plutot que le terrain) et ce sur quoi repose deja tout le design
# deterministe du jeu. Attention : des que la seed sera tiree au hasard par
# partie, elle devra etre TRANSMISE au client et ne pourra plus etre une
# constante compilee — voir issue #31.
func generate(seed_value: int) -> void:
	var height_noise := FastNoiseLite.new()
	height_noise.seed = seed_value
	height_noise.frequency = 0.015
	height_noise.fractal_octaves = 4

	var edge_noise := FastNoiseLite.new()
	edge_noise.seed = seed_value + 1

	var keel_noise := FastNoiseLite.new()
	keel_noise.seed = seed_value + 2
	keel_noise.frequency = 0.02

	var cave_noise := FastNoiseLite.new()
	cave_noise.seed = seed_value + 3
	cave_noise.frequency = 0.045
	cave_noise.fractal_octaves = 2

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
			if dist > local_radius:
				continue

			# 0 au rivage, 1 des qu'on est rentre dans les terres.
			var inland := clampf((local_radius - dist) / 8.0, 0.0, 1.0)

			var raw_surface := SURFACE_BASE + height_noise.get_noise_2d(float(x), float(z)) * SURFACE_AMPLITUDE
			var surface := int(round(lerpf(SHORE_Y, raw_surface, inland)))
			surface = clampi(surface, 0, size_y - 1)

			# La quille s'epaissit vers le centre : l'ile est une lentille de
			# roche, pas une dalle d'epaisseur constante. Le bruit evite un
			# dessous parfaitement lisse vu d'en dessous.
			var keel := lerpf(KEEL_MIN, KEEL_MAX, pow(inland, 0.8))
			keel += keel_noise.get_noise_2d(float(x), float(z)) * 3.0
			var bottom := maxi(surface - int(round(maxf(keel, KEEL_MIN))), 0)

			var top_type := _surface_type(surface, inland)

			for y in range(bottom, surface + 1):
				var depth := surface - y
				# Grottes naturelles : elles existent AVANT que le joueur ne
				# creuse, ce que le design demande explicitement. C'est le
				# gain concret de la grille 3D sur la heightmap.
				#
				# On ne creuse ni juste sous la surface (trous beants dans le
				# sol) ni dans la bedrock du fond : cette derniere doit rester
				# une coque etanche, sinon une grotte peut deboucher sur le
				# vide sous l'ile et annuler l'interet de l'avoir rendue
				# indestructible (voir BlockLibrary.INDESTRUCTIBLE).
				if depth > CAVE_SURFACE_MARGIN and y - bottom >= DARK_STONE_DEPTH:
					if cave_noise.get_noise_3d(float(x), float(y), float(z)) > CAVE_THRESHOLD:
						continue
				set_voxel(x, y, z, _type_at_depth(top_type, depth, y - bottom))


func _surface_type(surface: int, inland: float) -> int:
	if float(surface) <= SHORE_Y + SAND_BAND or inland < 0.15:
		return BlockLibrary.Type.SAND
	if float(surface) >= SNOW_Y:
		return BlockLibrary.Type.SNOW
	return BlockLibrary.Type.GRASS


func _type_at_depth(top_type: int, depth: int, height_above_bottom: int) -> int:
	if depth == 0:
		return top_type
	if height_above_bottom < DARK_STONE_DEPTH:
		return BlockLibrary.Type.STONE_DARK
	if depth <= DIRT_DEPTH:
		# Sous une plage on trouve du sable, pas de la terre.
		return BlockLibrary.Type.SAND if top_type == BlockLibrary.Type.SAND else BlockLibrary.Type.DIRT
	return BlockLibrary.Type.STONE
