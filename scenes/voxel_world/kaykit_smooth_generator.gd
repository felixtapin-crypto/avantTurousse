class_name KayKitSmoothGenerator
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

# Poids « une seule matiere » : la premiere a 100 %, les autres a zero. Le
# melange entre matieres voisines vient alors de l'interpolation des sommets
# faite par le mailleur, ce qui suffit pour une transition propre.
const FULL_WEIGHT := Color(1.0, 0.0, 0.0, 0.0)

var map: WorldMap

var _encoded_weights := 0


func _init() -> void:
	_encoded_weights = VoxelTool.color_to_u16_weights(FULL_WEIGHT)


func _get_used_channels_mask() -> int:
	return (1 << SDF_CHANNEL) | (1 << INDICES_CHANNEL) | (1 << WEIGHTS_CHANNEL)


func _generate_block(buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	if map == null:
		return

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
			var surface_layer := _layer_for(map.surface_block(biome))
			var sub_layer := _layer_for(strata.x)
			var sub_depth: int = strata.y

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

				var layer := surface_layer
				if wy < WorldMap.BEDROCK_DEPTH:
					layer = Layer.STONE_DARK
				elif depth > sub_depth:
					layer = Layer.STONE
				elif depth > 0:
					layer = sub_layer
				_set_material(buffer, x, y, z, layer)

	buffer.compress_uniform_channels()


func _fill_material(buffer: VoxelBuffer, layer: int) -> void:
	buffer.fill(VoxelTool.vec4i_to_u16_indices(Vector4i(layer, 0, 0, 0)), INDICES_CHANNEL)
	buffer.fill(_encoded_weights, WEIGHTS_CHANNEL)


func _set_material(buffer: VoxelBuffer, x: int, y: int, z: int, layer: int) -> void:
	buffer.set_voxel(
		VoxelTool.vec4i_to_u16_indices(Vector4i(layer, 0, 0, 0)), x, y, z, INDICES_CHANNEL)
	buffer.set_voxel(_encoded_weights, x, y, z, WEIGHTS_CHANNEL)


func _layer_for(block_type: int) -> int:
	match block_type:
		BlockLibrary.Type.GRASS: return Layer.GRASS
		BlockLibrary.Type.DIRT: return Layer.DIRT
		BlockLibrary.Type.STONE: return Layer.STONE
		BlockLibrary.Type.STONE_DARK: return Layer.STONE_DARK
		BlockLibrary.Type.SAND: return Layer.SAND
		BlockLibrary.Type.SAND_PALE: return Layer.SAND_PALE
		BlockLibrary.Type.GRAVEL: return Layer.GRAVEL
		BlockLibrary.Type.SNOW: return Layer.SNOW
		_: return Layer.STONE
