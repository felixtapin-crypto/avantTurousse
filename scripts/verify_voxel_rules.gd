extends SceneTree

# Verifie les invariants du terrain voxel et mesure le cout de generation.
#
#   godot --headless --path . --script res://scripts/verify_voxel_rules.gd
#
# Quatre controles, chacun motive par un bug reel ou une regle demandee :
#
# 1. ENROULEMENT DES FACES. Le sens des triangles a deja casse ce projet
#    deux fois sur platform.gd (terrain invisible vu d'en haut, puis terrain
#    traversable). Le symptome arrive tard, en jeu, et ressemble a tout sauf
#    a sa cause. On demande donc directement a Godot quelle normale il deduit
#    de notre enroulement.
#
# 2. PAS D'EAU ENTERREE. Regle demandee : on ne doit jamais tomber sur une
#    tuile d'eau en creusant. C'est garanti par construction, mais c'est
#    exactement le genre d'invariant qu'un futur ajout de grottes ou de
#    rivieres casse sans prevenir — et justement, les rivieres viennent
#    d'arriver.
#
# 3. REPARTITION DES BIOMES. Un biome peut exister dans le code et ne jamais
#    sortir a la generation parce qu'un seuil est mal calibre. On compte donc
#    les colonnes, et on echoue si une plage ou un desert est absent.
#
# 4. COUT DE GENERATION, pour que la taille de carte reste un choix informe.

const INVARIANT_SIZE := 300

func _initialize() -> void:
	var failures := 0
	failures += _check_analytic()
	failures += _check_against_godot()

	var data := VoxelData.new(INVARIANT_SIZE, 64)
	var t0 := Time.get_ticks_msec()
	data.generate(7)
	print("\n(carte de controle %d generee en %d ms)" % [INVARIANT_SIZE, Time.get_ticks_msec() - t0])

	failures += _check_water_placement(data)
	failures += _check_biomes(data)
	_benchmark()

	if failures == 0:
		print("\nOK — tous les invariants passent.")
	else:
		printerr("\nECHEC — %d probleme(s)." % failures)
	quit(1 if failures > 0 else 0)


# Regle de Godot : la face avant est celle dont les sommets tournent dans le
# sens HORAIRE vu de l'exterieur. Pour un triangle (p0,p1,p2), la normale
# sous cette convention vaut donc (p2-p0) x (p1-p0).
func _check_analytic() -> int:
	print("--- normales deduites de l'enroulement (calcul direct) ---")
	var failures := 0
	for f in 6:
		var expected := Vector3(VoxelMesher.FACE_NORMALS[f])
		var c: Array = VoxelMesher.FACE_CORNERS[f]
		var t1: Vector3 = (c[2] - c[0]).cross(c[1] - c[0]).normalized()
		var t2: Vector3 = (c[3] - c[0]).cross(c[2] - c[0]).normalized()
		var ok: bool = t1.is_equal_approx(expected) and t2.is_equal_approx(expected)
		if not ok:
			failures += 1
		print("  face %v  obtenu %v  %s" % [expected, t1, "ok" if ok else "MAUVAIS SENS"])
	return failures


# Le test qui compte vraiment : on laisse Godot deduire lui-meme les normales
# de notre enroulement, plutot que de se fier a notre lecture de sa convention.
func _check_against_godot() -> int:
	print("\n--- normales deduites par Godot (SurfaceTool.generate_normals) ---")
	var failures := 0
	for f in 6:
		var expected := Vector3(VoxelMesher.FACE_NORMALS[f])
		var corners: Array = VoxelMesher.FACE_CORNERS[f]

		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in [0, 1, 2, 0, 2, 3]:
			st.add_vertex(corners[i])
		st.generate_normals()
		var arrays := st.commit_to_arrays()
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]

		var ok := not normals.is_empty()
		for n in normals:
			if not n.normalized().is_equal_approx(expected):
				ok = false
		if not ok:
			failures += 1
		var got: Vector3 = normals[0] if not normals.is_empty() else Vector3.ZERO
		print("  face %v  godot dit %v  %s" % [expected, got, "ok" if ok else "MAUVAIS SENS"])
	return failures


# L'eau doit se trouver exclusivement AU-DESSUS du sol de sa propre colonne.
# Une riviere est donc legitime au-dessus du niveau de la mer ; une tuile
# d'eau au niveau du sol ou en dessous ne l'est jamais, c'est une tuile qu'on
# finirait par deterrer en creusant.
func _check_water_placement(data: VoxelData) -> int:
	print("\n--- placement de l'eau ---")

	var buried := 0
	var sea := 0
	var river := 0
	var first_bad := Vector3i(-1, -1, -1)

	for z in data.size_xz:
		for x in data.size_xz:
			var ground := data.terrain_height(x, z)
			for y in data.size_y:
				if data.get_voxel(x, y, z) != BlockLibrary.Type.WATER:
					continue
				if y <= ground:
					buried += 1
					if first_bad.x < 0:
						first_bad = Vector3i(x, y, z)
				elif y > VoxelData.SEA_LEVEL:
					river += 1
				else:
					sea += 1

	print("  mer : %d voxels" % sea)
	print("  riviere (au-dessus du niveau de la mer) : %d voxels" % river)
	print("  ENTERREE : %d %s" % [buried, "" if buried == 0 else "(premier: %v)" % first_bad])

	var failures := 0
	if sea == 0:
		printerr("  aucune mer generee")
		failures += 1
	if buried > 0:
		printerr("  de l'eau est enterree : on en trouvera en creusant")
		failures += 1
	return failures


# Un biome present dans le code mais absent de la carte est un seuil mal
# calibre, pas une fonctionnalite.
func _check_biomes(data: VoxelData) -> int:
	print("\n--- repartition des biomes ---")
	var counts := {}
	var total := data.size_xz * data.size_xz
	for z in data.size_xz:
		for x in data.size_xz:
			var b := data.biome_at(x, z)
			counts[b] = int(counts.get(b, 0)) + 1

	var ordered := counts.keys()
	ordered.sort_custom(func(a, b): return counts[a] > counts[b])
	for b in ordered:
		print("  %-14s %7d colonnes  (%5.2f %%)" % [
			data.biome_name(b), counts[b], 100.0 * float(counts[b]) / float(total)])

	_report_climate(data)

	var failures := 0
	for required in [VoxelData.Biome.BEACH, VoxelData.Biome.DESERT, VoxelData.Biome.SNOW, VoxelData.Biome.RIVER]:
		if int(counts.get(required, 0)) == 0:
			printerr("  biome absent de la carte : %s" % data.biome_name(required))
			failures += 1
	return failures


# Un biome absent se diagnostique sur les champs climatiques, pas en relisant
# la table des seuils : on regarde si la condition est atteignable du tout, et
# laquelle des deux moities bloque.
func _report_climate(data: VoxelData) -> void:
	var t_min := INF
	var t_max := -INF
	var m_min := INF
	var m_max := -INF
	var land := 0
	var hot := 0
	var dry := 0
	var hot_and_dry := 0

	for z in data.size_xz:
		for x in data.size_xz:
			if data.terrain_height(x, z) <= VoxelData.SEA_LEVEL:
				continue
			land += 1
			var t := data.temperature_at(x, z)
			var m := data.moisture_at(x, z)
			t_min = minf(t_min, t)
			t_max = maxf(t_max, t)
			m_min = minf(m_min, m)
			m_max = maxf(m_max, m)
			var is_hot := t > VoxelData.TEMP_DESERT
			var is_dry := m < VoxelData.MOIST_DESERT
			if is_hot:
				hot += 1
			if is_dry:
				dry += 1
			if is_hot and is_dry:
				hot_and_dry += 1

	if land == 0:
		print("\n  (aucune terre emergee)")
		return

	print("\n  climat sur %d colonnes emergees :" % land)
	print("    temperature %.2f .. %.2f  (seuil desert > %.2f)" % [t_min, t_max, VoxelData.TEMP_DESERT])
	print("    humidite    %.2f .. %.2f  (seuil desert < %.2f)" % [m_min, m_max, VoxelData.MOIST_DESERT])
	print("    assez chaud : %d (%.1f %%) · assez sec : %d (%.1f %%) · les deux : %d (%.1f %%)" % [
		hot, 100.0 * float(hot) / float(land),
		dry, 100.0 * float(dry) / float(land),
		hot_and_dry, 100.0 * float(hot_and_dry) / float(land)])


func _benchmark() -> void:
	print("\n--- cout de generation et de maillage ---")
	for size in [300, 600]:
		var data := VoxelData.new(size, 64)

		var t0 := Time.get_ticks_msec()
		data.generate(1)
		var gen_ms := Time.get_ticks_msec() - t0

		var keys := data.used_chunk_keys()
		var t1 := Time.get_ticks_msec()
		var solid_verts := 0
		var water_verts := 0
		for key in keys:
			var meshes := VoxelMesher.build_chunk(data, key)
			if meshes["solid"] != null:
				solid_verts += meshes["solid"].surface_get_array_len(0)
			if meshes["water"] != null:
				water_verts += meshes["water"].surface_get_array_len(0)
		var mesh_ms := Time.get_ticks_msec() - t1

		print("  %d x64x %d : generation %d ms, maillage %d ms (%d chunks, ~%d tris solides + ~%d tris d'eau)"
			% [size, size, gen_ms, mesh_ms, keys.size(), solid_verts / 4 * 2, water_verts / 4 * 2])
