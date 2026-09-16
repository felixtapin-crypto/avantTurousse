extends SceneTree

# Verifie que l'enroulement des faces de VoxelMesher est le bon, et mesure le
# cout de la generation + du maillage.
#
#   godot --headless --path . --script res://scripts/verify_voxel_winding.gd
#
# Pourquoi un test dedie : le sens des triangles a deja casse ce projet deux
# fois sur platform.gd (terrain invisible vu d'en haut, puis terrain
# traversable). Le symptome arrive tard, en jeu, et ressemble a tout sauf a
# sa cause. Ici on demande directement a Godot, via SurfaceTool, quelle
# normale il deduit de notre enroulement, et on la compare a la normale
# sortante attendue. Si ce test passe, le terrain est visible et
# collisionnant du bon cote.

func _initialize() -> void:
	var failures := 0
	failures += _check_analytic()
	failures += _check_against_godot()
	_benchmark()

	if failures == 0:
		print("\nOK — les 6 faces sont orientees vers l'exterieur.")
	else:
		printerr("\nECHEC — %d face(s) mal orientee(s)." % failures)
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
		print("  face %v  attendu %v  obtenu %v  %s" % [expected, expected, t1, "ok" if ok else "MAUVAIS SENS"])
	return failures


# Le test qui compte vraiment : on laisse Godot deduire lui-meme les normales
# de notre enroulement, plutot que de se fier a notre lecture de sa
# convention. Si generate_normals() sort la normale sortante attendue, alors
# notre enroulement est bien celui que Godot considere comme face avant.
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


func _benchmark() -> void:
	print("\n--- cout de generation et de maillage ---")
	for size in [128, 192, 256, 300]:
		var data := VoxelData.new(size, 64)

		var t0 := Time.get_ticks_msec()
		data.generate(1)
		var gen_ms := Time.get_ticks_msec() - t0

		var keys := data.solid_chunk_keys()
		var t1 := Time.get_ticks_msec()
		var triangles := 0
		for key in keys:
			var mesh := VoxelMesher.build_chunk(data, key)
			if mesh != null:
				triangles += mesh.surface_get_array_len(0) # sommets, /4*2 pour les tris
		var mesh_ms := Time.get_ticks_msec() - t1

		print("  %dx64x%d : generation %d ms, maillage %d ms (%d chunks pleins, ~%d triangles)"
			% [size, size, gen_ms, mesh_ms, keys.size(), triangles / 4 * 2])
