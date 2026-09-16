extends SceneTree

# Verifie les invariants du terrain voxel et mesure le cout de generation.
#
#   godot --headless --path . --script res://scripts/verify_voxel_rules.gd
#
# Trois controles, chacun motive par un bug reel ou une regle demandee :
#
# 1. ENROULEMENT DES FACES. Le sens des triangles a deja casse ce projet
#    deux fois sur platform.gd (terrain invisible vu d'en haut, puis terrain
#    traversable). Le symptome arrive tard, en jeu, et ressemble a tout sauf
#    a sa cause. On demande donc directement a Godot, via SurfaceTool,
#    quelle normale il deduit de notre enroulement.
#
# 2. PAS D'EAU ENTERREE. Regle demandee : on ne doit jamais tomber sur une
#    tuile d'eau en creusant dans l'ile. C'est garanti par construction (l'eau
#    n'est posee qu'au-dessus du sol), mais c'est exactement le genre
#    d'invariant qu'un futur ajout de grottes ou de rivieres casse sans
#    prevenir.
#
# 3. COUT DE GENERATION, pour que la taille de carte reste un choix informe.

func _initialize() -> void:
	var failures := 0
	failures += _check_analytic()
	failures += _check_against_godot()
	failures += _check_water_placement()
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
		# Les deux triangles du quad doivent donner la meme normale.
		var t1: Vector3 = (c[2] - c[0]).cross(c[1] - c[0]).normalized()
		var t2: Vector3 = (c[3] - c[0]).cross(c[2] - c[0]).normalized()
		var ok: bool = t1.is_equal_approx(expected) and t2.is_equal_approx(expected)
		if not ok:
			failures += 1
		print("  face %v  obtenu %v  %s" % [expected, t1, "ok" if ok else "MAUVAIS SENS"])
	return failures


# Le test qui compte vraiment : on laisse Godot deduire lui-meme les normales
# de notre enroulement, plutot que de se fier a notre lecture de sa
# convention.
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


# L'eau doit se trouver exclusivement AU-DESSUS du sol et AU PLUS au niveau
# de la mer. Toute tuile d'eau a l'interieur du terrain serait une tuile
# qu'on finirait par deterrer en creusant.
func _check_water_placement() -> int:
	print("\n--- placement de l'eau ---")
	var data := VoxelData.new(160, 64)
	data.generate(7)

	var buried := 0
	var above_sea := 0
	var water_total := 0
	var first_bad := Vector3i(-1, -1, -1)

	for z in data.size_xz:
		for x in data.size_xz:
			var ground := data.terrain_height(x, z)
			for y in data.size_y:
				if data.get_voxel(x, y, z) != BlockLibrary.Type.WATER:
					continue
				water_total += 1
				if y <= ground:
					buried += 1
					if first_bad.x < 0:
						first_bad = Vector3i(x, y, z)
				if y > VoxelData.SEA_LEVEL:
					above_sea += 1

	print("  %d voxels d'eau au total" % water_total)
	print("  enterres sous le sol : %d %s" % [buried, "" if buried == 0 else "(premier: %v)" % first_bad])
	print("  au-dessus du niveau de la mer : %d" % above_sea)

	var failures := 0
	if water_total == 0:
		printerr("  AUCUNE eau generee — l'ile n'est pas entouree de mer")
		failures += 1
	if buried > 0:
		printerr("  de l'eau est enterree : on en trouvera en creusant")
		failures += 1
	if above_sea > 0:
		printerr("  de l'eau flotte au-dessus du niveau de la mer")
		failures += 1
	return failures


func _benchmark() -> void:
	print("\n--- cout de generation et de maillage ---")
	for size in [160, 240, 300]:
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

		print("  %dx64x%d : generation %d ms, maillage %d ms (%d chunks, ~%d tris solides + ~%d tris d'eau)"
			% [size, size, gen_ms, mesh_ms, keys.size(), solid_verts / 4 * 2, water_verts / 4 * 2])
