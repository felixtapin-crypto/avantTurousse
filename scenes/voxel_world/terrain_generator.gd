class_name TerrainGenerator
extends VoxelGeneratorScript

# Generateur pour le terrain LISSE (Transvoxel), a comparer avec le rendu en
# blocs de `kaykit_voxel_generator.gd`. Les deux lisent la meme `WorldMap` :
# c'est le meme monde, seule la facon de le representer change.
#
# Trois differences de fond avec le rendu en blocs :
#
# 1. On n'ecrit plus un TYPE par voxel mais une DISTANCE SIGNEE (canal SDF) :
#    negative dans la matiere, positive dans le vide, et le mailleur place la
#    surface la ou elle vaut zero. C'est ce qui permet une pente continue au
#    lieu d'un escalier.
#
# 2. La matiere n'est plus portee par le voxel mais par deux canaux separes,
#    INDICES et WEIGHTS : jusqu'a 4 matieres melangees par voxel, encodees sur
#    4 bits chacune (donc 16 matieres possibles au maximum). Le shader les
#    echantillonne dans un Texture2DArray en projection triplanaire.
#
# 3. L'eau ne peut plus etre un voxel : un volume translucide n'a pas de place
#    dans une surface d'isovaleur unique. Elle devient un plan a hauteur de
#    mer, pose par la scene.
#
# Consequence de conception a ne pas perdre de vue : en lisse, creuser devient
# du sculptage a la sphere, pas du retrait de bloc. `DESIGN.md` demande de
# "poser des voxels/blocs pour batir une cabane" — c'est nettement moins
# naturel ici.

const SDF_CHANNEL := VoxelBuffer.CHANNEL_SDF
const INDICES_CHANNEL := VoxelBuffer.CHANNEL_INDICES
const WEIGHTS_CHANNEL := VoxelBuffer.CHANNEL_WEIGHTS

# Correspondance matiere -> couche du Texture2DArray. Cet ordre est le contrat
# avec le tableau de textures : changer l'un sans l'autre repeint le monde.
enum Layer {
	GRASS = 0,
	DIRT = 1,
	STONE = 2,
	STONE_DARK = 3,
	SAND = 4,
	SAND_PALE = 5,
	GRAVEL = 6,
	SNOW = 7,
}

const LAYER_COUNT := 8

# Epaisseur, en voxels, de la couche de surface.
#
# En terrain lisse elle ne peut PAS faire un seul voxel, contrairement au
# rendu en blocs. La surface ne tombe pas sur une frontiere de voxel : elle
# traverse une cellule de Transvoxel, et la matiere du sommet est prise sur
# les voxels PLEINS de cette cellule. Avec une surface d'un seul voxel, ce
# sont ceux du dessous qui l'emportent — mesure a l'appui, 61 % seulement des
# sommets portaient la bonne matiere, les prairies sortaient en terre et les
# sommets enneiges en roche.
const SURFACE_SKIN := 2

# Poids « une seule matiere » : la premiere a 100 %, les autres a zero.
#
# Il servait autrefois PARTOUT, au motif que l'interpolation des sommets faite
# par le mailleur suffirait a fondre deux matieres voisines. Elle ne le peut
# pas : le shader lit les indices de matiere en `flat` — il le doit, ce sont
# des entiers, voir la note dans smooth_terrain.gdshader — donc chaque triangle
# prend le jeu d'indices d'un seul de ses sommets. Avec une matiere unique par
# voxel, la limite entre deux biomes suivait exactement les aretes des
# triangles, et se voyait d'autant plus que les matieres se ressemblaient peu.
#
# Il ne sert donc plus que SOUS la surface, ou une limite franche entre deux
# strates est geologiquement juste et se lit bien en creusant.
const FULL_WEIGHT := Color(1.0, 0.0, 0.0, 0.0)

# Ecart, en metres, entre deux points du noyau qui melange les matieres de
# surface. Le fondu s'etale sur a peu pres quatre fois cette valeur.
#
# Il vaut 1 et pas davantage : c'est le pas d'echantillonnage qui QUANTIFIE la
# transition. A 2, les poids ne changeaient que tous les deux metres et la
# limite ressortait en escalier a marches carrees — le defaut meme qu'on
# cherchait a effacer, simplement deplace d'une echelle.
const BLEND_SPACING := 1

var map: WorldMap

var _encoded_weights := 0
# Biome -> couche de surface. Ce melange fait vingt-cinq lectures par colonne :
# une table evite d'y refaire a chaque fois deux appels de fonction.
var _biome_layer := PackedInt32Array()


func _init() -> void:
	_encoded_weights = VoxelTool.color_to_u16_weights(FULL_WEIGHT)


func _get_used_channels_mask() -> int:
	return (1 << SDF_CHANNEL) | (1 << INDICES_CHANNEL) | (1 << WEIGHTS_CHANNEL)


func _generate_block(buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	if map == null:
		return
	_ensure_biome_layers()

	# Les canaux de matiere sont sur 16 bits : 4 indices et 4 poids de 4 bits.
	buffer.set_channel_depth(INDICES_CHANNEL, VoxelBuffer.DEPTH_16_BIT)
	buffer.set_channel_depth(WEIGHTS_CHANNEL, VoxelBuffer.DEPTH_16_BIT)

	var step := 1 << lod
	var bs := buffer.get_size()
	var oy := origin_in_voxels.y
	var block_top := oy + bs.y * step

	var heights := map.height_range()

	# Sorties anticipees. En SDF, "loin au-dessus du relief" vaut 1 (vide
	# franc) et "loin en dessous" vaut -1 (matiere franche) : le mailleur n'y
	# trouve aucune surface et ne produit rien.
	if float(oy) > float(heights.y) + 2.0:
		buffer.fill_f(1.0, SDF_CHANNEL)
		return
	if block_top < heights.x - WorldMap.CAVE_MAX_DEPTH:
		buffer.fill_f(-1.0, SDF_CHANNEL)
		_fill_material(buffer, Layer.STONE)
		return

	for z in bs.z:
		var wz := origin_in_voxels.z + z * step
		for x in bs.x:
			var wx := origin_in_voxels.x + x * step

			var ground := map.terrain_height_f(wx, wz)
			var top := map.terrain_height(wx, wz)
			var biome := map.biome_at(wx, wz)
			var strata := map.sub_surface(biome)
			var sub_layer := layer_for(strata.x)
			var sub_depth: int = strata.y
			# Calcule une fois par COLONNE : le melange ne depend que de x et z.
			var surface_mix := _surface_mix(wx, wz)

			for y in bs.y:
				var wy := oy + y * step
				var depth := top - wy

				# Distance au sol, en voxels. C'est une approximation (la
				# vraie distance a une pente est plus courte), mais c'est
				# l'usage courant pour un terrain issu d'une carte de
				# hauteurs, et le mailleur ne lit que le signe et le
				# voisinage du zero.
				var sdf := float(wy) - ground

				# Bedrock : jamais creusee, meme par une grotte.
				if wy >= WorldMap.BEDROCK_DEPTH:
					sdf = maxf(sdf, map.cave_sdf(wx, wy, wz, depth))

				buffer.set_voxel_f(clampf(sdf / 8.0, -1.0, 1.0), x, y, z, SDF_CHANNEL)

				# La couche de surface est testee AVANT la stratification :
				# sans ca, un biome dont le sous-sol est directement de la
				# roche (la neige, par exemple) n'aurait aucune epaisseur de
				# surface et ressortirait en pierre.
				if wy < WorldMap.BEDROCK_DEPTH:
					_set_material(buffer, x, y, z, Layer.STONE_DARK)
				elif depth <= SURFACE_SKIN:
					# Seule la surface est fondue : c'est la seule qu'on voie
					# sans creuser, et sous terre une limite nette entre deux
					# strates est ce qu'on veut lire.
					_set_material_mix(buffer, x, y, z, surface_mix)
				elif depth <= sub_depth:
					_set_material(buffer, x, y, z, sub_layer)
				else:
					_set_material(buffer, x, y, z, Layer.STONE)

	buffer.compress_uniform_channels()


func _fill_material(buffer: VoxelBuffer, layer: int) -> void:
	buffer.fill(VoxelTool.vec4i_to_u16_indices(Vector4i(layer, 0, 0, 0)), INDICES_CHANNEL)
	buffer.fill(_encoded_weights, WEIGHTS_CHANNEL)


func _set_material(buffer: VoxelBuffer, x: int, y: int, z: int, layer: int) -> void:
	buffer.set_voxel(
		VoxelTool.vec4i_to_u16_indices(Vector4i(layer, 0, 0, 0)), x, y, z, INDICES_CHANNEL)
	buffer.set_voxel(_encoded_weights, x, y, z, WEIGHTS_CHANNEL)


func _set_material_mix(buffer: VoxelBuffer, x: int, y: int, z: int, mix: Vector2i) -> void:
	buffer.set_voxel(mix.x, x, y, z, INDICES_CHANNEL)
	buffer.set_voxel(mix.y, x, y, z, WEIGHTS_CHANNEL)


# Melange des matieres de surface autour d'une colonne, sous la forme des deux
# mots de 16 bits qu'attendent les canaux : `x` les quatre indices, `y` les
# quatre poids.
#
# Le noyau est un 5x5 a ponderation triangulaire. Une moyenne des quatre
# voisins immediats donnerait un fondu de deux metres, encore lu comme une
# limite ; un noyau beaucoup plus large delaverait les petits biomes, qui font
# parfois une dizaine de metres a peine.
func _surface_mix(wx: int, wz: int) -> Vector2i:
	var totals := PackedInt32Array()
	totals.resize(LAYER_COUNT)

	for j in range(-2, 3):
		var row := 3 - absi(j)
		var sz := wz + j * BLEND_SPACING
		for i in range(-2, 3):
			var sx := wx + i * BLEND_SPACING
			var layer := _biome_layer[map.biome_at(sx, sz)]
			totals[layer] += row * (3 - absi(i))

	# Les quatre matieres les plus representees : au-dela, le format n'a plus
	# de place. Selection par passes plutot que par tri — il n'y a que huit
	# couches, et un tri coute davantage.
	var kept := PackedInt32Array()
	for _n in 4:
		var best := -1
		for layer in LAYER_COUNT:
			if totals[layer] > 0 and not kept.has(layer):
				if best < 0 or totals[layer] > totals[best]:
					best = layer
		if best < 0:
			break
		kept.append(best)

	# Ordre CANONIQUE, par indice croissant. C'est indispensable, pas cosmetique
	# : les indices etant lus en `flat`, un triangle applique des poids
	# INTERPOLES au jeu d'indices d'un seul de ses sommets. Deux colonnes
	# voisines qui listeraient les memes matieres dans un ordre different
	# feraient tomber chaque poids sur la mauvaise matiere.
	kept.sort()

	var total := 0
	for layer in kept:
		total += totals[layer]

	var indices := PackedInt32Array([0, 0, 0, 0])
	var weights := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for k in kept.size():
		indices[k] = kept[k]
		weights[k] = float(totals[kept[k]]) / float(maxi(total, 1))

	return Vector2i(
		VoxelTool.vec4i_to_u16_indices(
			Vector4i(indices[0], indices[1], indices[2], indices[3])),
		VoxelTool.color_to_u16_weights(
			Color(weights[0], weights[1], weights[2], weights[3])))


# Construite une fois : `surface_block` et `layer_for` ne dependent que du
# biome, et `_surface_mix` les appellerait vingt-cinq fois par colonne.
func _ensure_biome_layers() -> void:
	if not _biome_layer.is_empty():
		return
	_biome_layer.resize(WorldMap.Biome.size())
	for biome in _biome_layer.size():
		_biome_layer[biome] = layer_for(map.surface_block(biome))


func layer_for(block_type: int) -> int:
	match block_type:
		TerrainMaterials.Type.GRASS: return Layer.GRASS
		TerrainMaterials.Type.DIRT: return Layer.DIRT
		TerrainMaterials.Type.STONE: return Layer.STONE
		TerrainMaterials.Type.STONE_DARK: return Layer.STONE_DARK
		TerrainMaterials.Type.SAND: return Layer.SAND
		TerrainMaterials.Type.SAND_PALE: return Layer.SAND_PALE
		TerrainMaterials.Type.GRAVEL: return Layer.GRAVEL
		TerrainMaterials.Type.SNOW: return Layer.SNOW
		_: return Layer.STONE
