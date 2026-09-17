extends SceneTree

# Sonde : que transporte reellement le mailleur dans CUSTOM1 ?
#
#   godot --headless --path . --script res://scripts/probe_weights.gd
#
# Reproduction minimale, volontairement coupee du monde : un plan horizontal,
# des matieres ECRITES A LA MAIN, et on relit ce qui ressort. Elle existe parce
# que 64 % des sommets de surface sortaient avec quatre poids nuls, et qu'il
# fallait savoir si la faute etait a l'ecriture, au mailleur, ou a la relecture.

const SIZE := 16
static var SURFACE := 8.0


func _initialize() -> void:
	for h in [8.0, 2.0, 1.0, 14.0, 15.0]:
		SURFACE = h
		_probe("surface a y=%.0f" % h, Vector4i(0, 4, 0, 0), Color(0.5, 0.5, 0.0, 0.0))
	SURFACE = 8.0
	_probe("deux a parts egales", Vector4i(0, 4, 0, 0), Color(0.5, 0.5, 0.0, 0.0))
	_probe("quatre matieres", Vector4i(0, 2, 4, 6), Color(0.4, 0.3, 0.2, 0.1))
	# LE SUSPECT. Le vrai generateur termine par compress_uniform_channels(),
	# que cette sonde n'appelait pas — c'est la seule difference entre les deux.
	_probe("une seule matiere, COMPRESSEE",
		Vector4i(4, 0, 0, 0), Color(1.0, 0.0, 0.0, 0.0), true)
	_probe("quatre matieres, COMPRESSEES",
		Vector4i(0, 2, 4, 6), Color(0.4, 0.3, 0.2, 0.1), true)
	_probe_gradient("degrade, MEME jeu d indices", true)
	_probe_gradient("degrade, jeux d indices DIFFERENTS", false)
	_probe_real_generator()
	quit(0)


func _probe(label: String, indices: Vector4i, weights: Color, compress := false) -> void:
	var buffer := VoxelBuffer.new()
	buffer.create(SIZE, SIZE, SIZE)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_16_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_WEIGHTS, VoxelBuffer.DEPTH_16_BIT)

	var encoded_indices := VoxelTool.vec4i_to_u16_indices(indices)
	var encoded_weights := VoxelTool.color_to_u16_weights(weights)

	for z in SIZE:
		for y in SIZE:
			for x in SIZE:
				buffer.set_voxel_f(
					clampf((float(y) - SURFACE) / 8.0, -1.0, 1.0),
					x, y, z, VoxelBuffer.CHANNEL_SDF)
				buffer.set_voxel(encoded_indices, x, y, z, VoxelBuffer.CHANNEL_INDICES)
				buffer.set_voxel(encoded_weights, x, y, z, VoxelBuffer.CHANNEL_WEIGHTS)

	if compress:
		buffer.compress_uniform_channels()

	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_MIXEL4_S4
	mesher.textures_ignore_air_voxels = false

	var mesh: ArrayMesh = mesher.build_mesh(buffer, [], {})
	print("\n=== %s ===" % label)
	print("  ecrit   indices %s  poids %s" % [str(indices), str(weights)])
	print("  encode  indices 0x%04x  poids 0x%04x" % [encoded_indices, encoded_weights])

	if mesh == null or mesh.get_surface_count() == 0:
		printerr("  aucun maillage produit")
		return

	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var custom1 = arrays[Mesh.ARRAY_CUSTOM1]
	if custom1 == null:
		printerr("  CUSTOM1 absent")
		return

	@warning_ignore("integer_division")
	var stride: int = custom1.size() / maxi(vertices.size(), 1)
	print("  %d sommets, %d flottants par sommet" % [vertices.size(), stride])

	var empty := 0
	for i in vertices.size():
		if _bytes(custom1[i * stride + 1]) == PackedByteArray([0, 0, 0, 0]):
			empty += 1
	print("  sommets a poids nuls : %d / %d" % [empty, vertices.size()])
	for i in mini(3, vertices.size()):
		print("    lu  indices %s  poids %s" % [
			_bytes(custom1[i * stride]), _bytes(custom1[i * stride + 1])])


# Materiau VARIABLE d'un voxel a l'autre, ce que la sonde precedente ne testait
# pas : elle remplissait tout le bloc avec la meme matiere, alors que le
# melange de surface fait justement changer indices et poids d'une colonne a la
# suivante.
func _probe_gradient(label: String, same_set: bool) -> void:
	var buffer := VoxelBuffer.new()
	buffer.create(SIZE, SIZE, SIZE)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_16_BIT)
	buffer.set_channel_depth(VoxelBuffer.CHANNEL_WEIGHTS, VoxelBuffer.DEPTH_16_BIT)

	for z in SIZE:
		for y in SIZE:
			for x in SIZE:
				buffer.set_voxel_f(
					clampf((float(y) - SURFACE) / 8.0, -1.0, 1.0),
					x, y, z, VoxelBuffer.CHANNEL_SDF)

				var t := float(x) / float(SIZE - 1)
				var indices := Vector4i(0, 4, 0, 0)
				var weights := Color(1.0 - t, t, 0.0, 0.0)
				if not same_set:
					# Jeux d'indices DIFFERENTS de part et d'autre, comme au
					# bord d'un biome ou les quatre matieres retenues changent.
					if t > 0.5:
						indices = Vector4i(4, 6, 0, 0)
						weights = Color(1.0 - (t - 0.5) * 2.0, (t - 0.5) * 2.0, 0.0, 0.0)
					else:
						weights = Color(1.0 - t * 2.0, t * 2.0, 0.0, 0.0)

				buffer.set_voxel(VoxelTool.vec4i_to_u16_indices(indices),
					x, y, z, VoxelBuffer.CHANNEL_INDICES)
				buffer.set_voxel(VoxelTool.color_to_u16_weights(weights),
					x, y, z, VoxelBuffer.CHANNEL_WEIGHTS)

	buffer.compress_uniform_channels()

	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_MIXEL4_S4
	mesher.textures_ignore_air_voxels = false

	var mesh: ArrayMesh = mesher.build_mesh(buffer, [], {})
	print("\n=== %s ===" % label)
	if mesh == null or mesh.get_surface_count() == 0:
		printerr("  aucun maillage produit")
		return

	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var custom1 = arrays[Mesh.ARRAY_CUSTOM1]
	@warning_ignore("integer_division")
	var stride: int = custom1.size() / maxi(vertices.size(), 1)

	var empty := 0
	for i in vertices.size():
		if _bytes(custom1[i * stride + 1]) == PackedByteArray([0, 0, 0, 0]):
			empty += 1
	print("  sommets a poids nuls : %d / %d" % [empty, vertices.size()])
	for i in mini(4, vertices.size()):
		print("    x=%5.1f  indices %s  poids %s" % [
			vertices[i].x, _bytes(custom1[i * stride]), _bytes(custom1[i * stride + 1])])


# Le VRAI generateur, sur une vraie carte. Les sondes synthetiques ci-dessus
# transportent toutes leurs poids correctement ; si celle-ci ne le fait pas, la
# faute est dans TerrainGenerator et nulle part ailleurs.
func _probe_real_generator() -> void:
	var map := WorldMap.new(300, 64)
	map.generate(7)
	var generator := TerrainGenerator.new()
	generator.map = map

	# Une colonne bien au-dessus du niveau de la mer, pour tomber sur du relief.
	var wx := 150
	var wz := 150
	var ground := map.terrain_height(wx, wz)
	@warning_ignore("integer_division")
	var origin := Vector3i((wx / SIZE) * SIZE, (ground / SIZE) * SIZE, (wz / SIZE) * SIZE)

	var buffer := VoxelBuffer.new()
	buffer.create(SIZE, SIZE, SIZE)
	generator._generate_block(buffer, origin, 0)

	print("\n=== vrai generateur, bloc %s (sol a y=%d) ===" % [str(origin), ground])
	# Ce que le generateur a REELLEMENT ecrit dans le tampon, avant maillage.
	var written := buffer.get_voxel(
		wx - origin.x, ground - origin.y, wz - origin.z, VoxelBuffer.CHANNEL_WEIGHTS)
	print("  dans le tampon : poids 0x%04x  indices 0x%04x" % [written, buffer.get_voxel(
		wx - origin.x, ground - origin.y, wz - origin.z, VoxelBuffer.CHANNEL_INDICES)])

	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_MIXEL4_S4
	mesher.textures_ignore_air_voxels = false

	var mesh: ArrayMesh = mesher.build_mesh(buffer, [], {})
	if mesh == null or mesh.get_surface_count() == 0:
		printerr("  aucun maillage produit")
		return

	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var custom1 = arrays[Mesh.ARRAY_CUSTOM1]
	@warning_ignore("integer_division")
	var stride: int = custom1.size() / maxi(vertices.size(), 1)

	var empty := 0
	for i in vertices.size():
		if _bytes(custom1[i * stride + 1]) == PackedByteArray([0, 0, 0, 0]):
			empty += 1
	print("  sommets a poids nuls : %d / %d" % [empty, vertices.size()])
	var shown := 0
	for i in vertices.size():
		if shown >= 6 or _bytes(custom1[i * stride + 1]) != PackedByteArray([0, 0, 0, 0]):
			continue
		shown += 1
		print("    VIDE pos %s  indices %s" % [str(vertices[i].round()), _bytes(custom1[i * stride])])
	for i in mini(0, vertices.size()):
		print("    y=%5.1f  indices %s  poids %s" % [
			vertices[i].y, _bytes(custom1[i * stride]), _bytes(custom1[i * stride + 1])])


func _bytes(packed: float) -> PackedByteArray:
	return PackedFloat32Array([packed]).to_byte_array()
