class_name KayKitBlockyLibrary
extends RefCounted

# Construit la VoxelBlockyLibrary de godot_voxel a partir de notre palette
# (issue #34).
#
# Point agreable : aucun atlas de texture n'est necessaire. `VoxelBlockyModel`
# expose une propriete `color`, et `VoxelMesherBlocky.TINT_RAW_COLOR` la
# repercute en couleur de sommet. Comme la palette KayKit est un nuancier
# d'aplats et non une matiere a repeter (voir issue #30), c'est exactement le
# bon mecanisme : on obtient les teintes du pack, au pixel pres, sans texture.
#
# La bibliotheque est construite EN CODE plutot que rangee en .tres, parce que
# l'indice d'un modele dans la liste est l'identifiant du bloc dans les
# donnees voxel. Les construire dans l'ordre de `BlockLibrary.Type` garantit
# que les deux moteurs parlent des memes identifiants ; un .tres edite a la
# main pourrait diverger silencieusement.

# Ordre imperatif : l'indice dans la liste EST l'identifiant du voxel.
const ORDER: Array[int] = [
	BlockLibrary.Type.AIR,
	BlockLibrary.Type.GRASS,
	BlockLibrary.Type.DIRT,
	BlockLibrary.Type.STONE,
	BlockLibrary.Type.STONE_DARK,
	BlockLibrary.Type.SAND,
	BlockLibrary.Type.SAND_PALE,
	BlockLibrary.Type.GRAVEL,
	BlockLibrary.Type.SNOW,
	BlockLibrary.Type.WATER,
]

const CUBE_AABB := AABB(Vector3.ZERO, Vector3.ONE)


static func build() -> VoxelBlockyLibrary:
	var library := VoxelBlockyLibrary.new()
	var opaque := _opaque_material()
	var translucent := _translucent_material()

	for type in ORDER:
		if type == BlockLibrary.Type.AIR:
			var air := VoxelBlockyModelEmpty.new()
			air.resource_name = BlockLibrary.NAME[type]
			library.add_model(air)
			continue

		var cube := VoxelBlockyModelCube.new()
		cube.resource_name = BlockLibrary.NAME[type]
		cube.color = BlockLibrary.COLOR[type]

		if type == BlockLibrary.Type.WATER:
			# Pas de boite de collision : on ne marche pas sur la mer, on la
			# traverse et on coule jusqu'au fond.
			cube.collision_aabbs = []
			cube.set_material_override(0, translucent)
			# Un indice de transparence different de celui des blocs pleins
			# fait que les faces eau/eau se masquent entre elles, mais pas les
			# faces solide/eau : sans ca, le fond marin disparaitrait des
			# qu'on le regarde a travers l'eau.
			cube.transparency_index = 1
			cube.culls_neighbors = false
		else:
			cube.collision_aabbs = [CUBE_AABB]
			cube.set_material_override(0, opaque)

		library.add_model(cube)

	return library


static func build_mesher() -> VoxelMesherBlocky:
	var mesher := VoxelMesherBlocky.new()
	mesher.library = build()
	# Sans ca, la couleur portee par chaque modele est ignoree et tout le
	# terrain ressort blanc.
	mesher.tint_mode = VoxelMesherBlocky.TINT_RAW_COLOR
	# Occlusion ambiante par bloc : assombrit les creux et les pieds de
	# falaise. C'est ce qui evite qu'un terrain en aplats paraisse plat.
	mesher.occlusion_enabled = true
	return mesher


static func _opaque_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.metallic = 0.0
	material.roughness = 1.0
	return material


static func _translucent_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.metallic = 0.0
	material.roughness = 0.15
	return material
