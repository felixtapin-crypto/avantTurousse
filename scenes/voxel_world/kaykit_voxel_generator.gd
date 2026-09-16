class_name KayKitVoxelGenerator
extends VoxelGeneratorScript

# Generateur pour godot_voxel (issue #34). Equivalent strict de
# `VoxelData._fill_voxels()`, mais appele par chunk au lieu de remplir toute
# la carte d'un coup.
#
# Les deux lisent la MEME `WorldMap`, ce qui est tout l'interet du decoupage :
# l'hydrologie, le climat et les biomes ne sont pas reecrits pour godot_voxel,
# ils sont simplement consultes. Seul le remplissage 3D, qui est local par
# nature, est reimplemente ici selon l'API du moteur.
#
# ATTENTION AU MULTITHREAD. `_generate_block` est appele depuis plusieurs
# threads simultanement. C'est sur ici parce que :
#
# - `map` est en lecture seule une fois `generate()` termine, et le terrain
#   n'est branche qu'apres (voir godot_voxel_world.gd) ;
# - `FastNoiseLite` n'a pas d'etat d'echantillonnage, donc plusieurs threads
#   peuvent l'interroger en parallele. Ce n'est PAS vrai de tout : un `Curve`
#   se cuit paresseusement au premier echantillonnage et plante quand
#   plusieurs threads y arrivent ensemble — les demos de Zylann appellent
#   `Curve.bake()` dans `_init()` exactement pour ca.

const CHANNEL := VoxelBuffer.CHANNEL_TYPE

var map: WorldMap


func _get_used_channels_mask() -> int:
	return 1 << CHANNEL


func _generate_block(buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	if map == null:
		return

	# A LOD > 0, un voxel du tampon couvre 2^lod voxels du monde.
	var step := 1 << lod
	var bs := buffer.get_size()
	var oy := origin_in_voxels.y
	var block_top := oy + bs.y * step

	var heights := map.height_range()
	var highest := maxi(heights.y, WorldMap.SEA_LEVEL)

	# Sorties anticipees. Sans elles, chaque chunk de ciel ou de roche
	# profonde serait parcouru voxel par voxel pour rien : c'est le premier
	# reflexe de performance des generateurs de godot_voxel.
	if oy > highest:
		buffer.fill(BlockLibrary.Type.AIR, CHANNEL)
		return
	if block_top <= WorldMap.BEDROCK_DEPTH:
		buffer.fill(BlockLibrary.Type.STONE_DARK, CHANNEL)
		return
	# Sous la profondeur max des grottes, plus rien n'est creuse : le chunk
	# est de la pierre pleine. On ne peut pas simplement tester "sous le
	# relief minimal", justement a cause des grottes.
	if oy >= WorldMap.BEDROCK_DEPTH and block_top < heights.x - WorldMap.CAVE_MAX_DEPTH:
		buffer.fill(BlockLibrary.Type.STONE, CHANNEL)
		return

	buffer.fill(BlockLibrary.Type.AIR, CHANNEL)

	for z in bs.z:
		var wz := origin_in_voxels.z + z * step
		for x in bs.x:
			var wx := origin_in_voxels.x + x * step

			var top := map.terrain_height(wx, wz)
			if top < 0:
				continue

			var biome := map.biome_at(wx, wz)
			var surface_type := map.surface_block(biome)
			var strata := map.sub_surface(biome)
			var sub_type := strata.x
			var sub_depth := strata.y

			# Eau : au-dessus du sol uniquement, jamais dedans. C'est ce qui
			# garantit qu'on n'en deterre jamais en creusant.
			var water_top := -1
			if top < WorldMap.SEA_LEVEL:
				water_top = WorldMap.SEA_LEVEL
			elif biome == WorldMap.Biome.RIVER:
				water_top = top + 1

			for y in bs.y:
				var wy := oy + y * step
				var type := BlockLibrary.Type.AIR

				if wy <= top:
					if wy < WorldMap.BEDROCK_DEPTH:
						type = BlockLibrary.Type.STONE_DARK
					else:
						var depth := top - wy
						if map.is_cave(wx, wy, wz, depth):
							continue
						if depth == 0:
							type = surface_type
						elif depth <= sub_depth:
							type = sub_type
						else:
							type = BlockLibrary.Type.STONE
				elif wy <= water_top:
					type = BlockLibrary.Type.WATER
				else:
					# Au-dessus du sol et de l'eau : le reste de la colonne
					# est de l'air, deja en place depuis le fill initial.
					break

				if type != BlockLibrary.Type.AIR:
					buffer.set_voxel(type, x, y, z, CHANNEL)

	# Un chunk uniforme (ciel, roche pleine, pleine mer) est alors stocke en
	# une seule valeur au lieu de 4096 octets.
	buffer.compress_uniform_channels()
