extends SceneTree

# Verifie les invariants du monde et mesure le cout de generation.
#
#   godot --headless --path . --script res://scripts/verify_voxel_rules.gd
#
# Ce que ces controles protegent :
#
# 1. PAS D'EAU ENTERREE. Regle demandee : on ne doit jamais tomber sur une
#    tuile d'eau en creusant. C'est garanti par construction, mais c'est
#    exactement le genre d'invariant qu'un ajout de grottes ou de rivieres
#    casse sans prevenir. Le controle passe par le VRAI generateur
#    godot_voxel, pas par une relecture de la carte : c'est le code qui
#    tourne en jeu qu'on veut tester.
#
# 2. REPARTITION DES BIOMES. Un biome peut exister dans le code et ne jamais
#    sortir a la generation parce qu'un seuil est mal calibre. C'est ainsi
#    qu'on a trouve que le desert etait litteralement impossible (temperature
#    et humidite anti-correlees) et que la neige ne sortait jamais.
#
# 3. COUT DE GENERATION, pour que la taille de carte reste un choix informe.

# Taille de la carte de controle. A ne pas trop reduire pour gagner du temps :
# la frequence du masque continental est absolue, donc une petite carte ne
# contient qu'un fragment de continent, souvent sans relief marque ni biome
# d'altitude — un faux echec qui n'a rien a voir avec le code teste.
const INVARIANT_SIZE := 300
const CHUNK := 16
# Un chunk sur deux en x et z : assez pour couvrir toute la carte sans
# regenerer chaque voxel deux fois.
const CHUNK_STRIDE := 2


func _initialize() -> void:
	var map := WorldMap.new(INVARIANT_SIZE, 64)
	var t0 := Time.get_ticks_msec()
	map.generate(7)
	print("carte de controle %d generee en %d ms" % [INVARIANT_SIZE, Time.get_ticks_msec() - t0])

	var failures := 0
	failures += _check_generated_water(map)
	failures += _check_biomes(map)
	_benchmark()

	if failures == 0:
		print("\nOK — tous les invariants passent.")
	else:
		printerr("\nECHEC — %d probleme(s)." % failures)
	quit(1 if failures > 0 else 0)


# Fait tourner le generateur godot_voxel sur un echantillon de chunks et
# verifie que chaque voxel d'eau se trouve STRICTEMENT au-dessus du sol de sa
# colonne. Une riviere au-dessus du niveau de la mer est legitime ; une tuile
# d'eau au niveau du sol ou en dessous ne l'est jamais.
func _check_generated_water(map: WorldMap) -> int:
	print("\n--- eau produite par le generateur godot_voxel ---")

	var generator := KayKitVoxelGenerator.new()
	generator.map = map

	var buried := 0
	var sea := 0
	var river := 0
	var solid := 0
	var first_bad := Vector3i(-1, -1, -1)

	var chunks := int(ceil(float(map.size_xz) / float(CHUNK)))
	@warning_ignore("integer_division")
	var chunks_y := map.size_y / CHUNK

	for cz in range(0, chunks, CHUNK_STRIDE):
		for cx in range(0, chunks, CHUNK_STRIDE):
			for cy in chunks_y:
				var origin := Vector3i(cx * CHUNK, cy * CHUNK, cz * CHUNK)
				var buffer := VoxelBuffer.new()
				buffer.create(CHUNK, CHUNK, CHUNK)
				generator._generate_block(buffer, origin, 0)

				for y in CHUNK:
					for z in CHUNK:
						for x in CHUNK:
							var v := buffer.get_voxel(x, y, z, VoxelBuffer.CHANNEL_TYPE)
							if v == BlockLibrary.Type.AIR:
								continue
							if v != BlockLibrary.Type.WATER:
								solid += 1
								continue
							var wx := origin.x + x
							var wy := origin.y + y
							var wz := origin.z + z
							var ground := map.terrain_height(wx, wz)
							if wy <= ground:
								buried += 1
								if first_bad.x < 0:
									first_bad = Vector3i(wx, wy, wz)
							elif wy > WorldMap.SEA_LEVEL:
								river += 1
							else:
								sea += 1

	print("  solide : %d voxels" % solid)
	print("  mer : %d voxels" % sea)
	print("  riviere : %d voxels" % river)
	print("  ENTERREE : %d %s" % [buried, "" if buried == 0 else "(premier: %v)" % first_bad])

	var failures := 0
	if solid == 0:
		printerr("  le generateur ne produit aucun solide")
		failures += 1
	if sea == 0:
		printerr("  aucune mer generee")
		failures += 1
	if buried > 0:
		printerr("  de l'eau est enterree : on en trouvera en creusant")
		failures += 1
	return failures


func _check_biomes(map: WorldMap) -> int:
	print("\n--- repartition des biomes ---")
	var counts := {}
	var total := map.size_xz * map.size_xz
	for z in map.size_xz:
		for x in map.size_xz:
			var b := map.biome_at(x, z)
			counts[b] = int(counts.get(b, 0)) + 1

	var ordered := counts.keys()
	ordered.sort_custom(func(a, b): return counts[a] > counts[b])
	for b in ordered:
		print("  %-14s %7d colonnes  (%5.2f %%)" % [
			map.biome_name(b), counts[b], 100.0 * float(counts[b]) / float(total)])

	_report_climate(map)

	var failures := 0
	for required in [WorldMap.Biome.BEACH, WorldMap.Biome.DESERT,
			WorldMap.Biome.SNOW, WorldMap.Biome.RIVER]:
		if int(counts.get(required, 0)) == 0:
			printerr("  biome absent de la carte : %s" % map.biome_name(required))
			failures += 1
	return failures


# Un biome absent se diagnostique sur les champs climatiques, pas en relisant
# la table des seuils : on regarde si la condition est atteignable du tout, et
# laquelle des deux moities bloque.
func _report_climate(map: WorldMap) -> void:
	var t_min := INF
	var t_max := -INF
	var m_min := INF
	var m_max := -INF
	var land := 0
	var hot := 0
	var dry := 0
	var both := 0

	for z in map.size_xz:
		for x in map.size_xz:
			if map.terrain_height(x, z) <= WorldMap.SEA_LEVEL:
				continue
			land += 1
			var t := map.temperature_at(x, z)
			var m := map.moisture_at(x, z)
			t_min = minf(t_min, t)
			t_max = maxf(t_max, t)
			m_min = minf(m_min, m)
			m_max = maxf(m_max, m)
			var is_hot := t > WorldMap.TEMP_DESERT
			var is_dry := m < WorldMap.MOIST_DESERT
			if is_hot:
				hot += 1
			if is_dry:
				dry += 1
			if is_hot and is_dry:
				both += 1

	if land == 0:
		print("\n  (aucune terre emergee)")
		return

	print("\n  climat sur %d colonnes emergees :" % land)
	print("    temperature %.2f .. %.2f  (seuil desert > %.2f)" % [t_min, t_max, WorldMap.TEMP_DESERT])
	print("    humidite    %.2f .. %.2f  (seuil desert < %.2f)" % [m_min, m_max, WorldMap.MOIST_DESERT])
	print("    assez chaud : %d (%.1f %%) · assez sec : %d (%.1f %%) · les deux : %d (%.1f %%)" % [
		hot, 100.0 * float(hot) / float(land),
		dry, 100.0 * float(dry) / float(land),
		both, 100.0 * float(both) / float(land)])


func _benchmark() -> void:
	print("\n--- cout ---")
	for size in [300, 600]:
		var map := WorldMap.new(size, 64)
		var t0 := Time.get_ticks_msec()
		map.generate(1)
		var map_ms := Time.get_ticks_msec() - t0

		# Cout d'un chunk au niveau du sol : c'est ce que godot_voxel paiera
		# par bloc, en tache de fond, pendant que le joueur se deplace.
		var generator := KayKitVoxelGenerator.new()
		generator.map = map
		var centre := int(size / 2.0)
		@warning_ignore("integer_division")
		var cy := map.terrain_height(centre, centre) / CHUNK
		var t1 := Time.get_ticks_usec()
		var blocks := 64
		for i in blocks:
			var buffer := VoxelBuffer.new()
			buffer.create(CHUNK, CHUNK, CHUNK)
			generator._generate_block(
				buffer, Vector3i(centre + (i % 8) * CHUNK, cy * CHUNK, centre + (i / 8) * CHUNK), 0)
		var per_block := float(Time.get_ticks_usec() - t1) / float(blocks) / 1000.0

		print("  %d x64x %d : carte %d ms, puis %.2f ms par chunk de surface" % [size, size, map_ms, per_block])
