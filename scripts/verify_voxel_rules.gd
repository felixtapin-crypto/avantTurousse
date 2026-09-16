extends SceneTree

# Verifie les invariants du monde et mesure le cout de generation.
#
#   godot --headless --path . --script res://scripts/verify_voxel_rules.gd
#
# Ce que ces controles protegent :
#
# 1. LA SURFACE SUIT LA CARTE. La distance signee doit changer de signe a
#    l'altitude annoncee par la carte, sans quoi le joueur flotte ou se
#    retrouve enterre, et l'ecran d'apercu ment sur ce qu'on trouvera en jeu.
#    Le controle passe par le VRAI generateur et non par une relecture de la
#    carte : c'est le code qui tourne en partie qu'on veut tester.
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

# Part minimale sous laquelle un biome n'est plus un biome mais un artefact.
const MIN_BIOME_SHARE := 0.0015
const SIZES_TO_CHECK := [300, 450, 600]
const SEEDS_TO_CHECK := [1, 7, 99]


func _initialize() -> void:
	var map := WorldMap.new(INVARIANT_SIZE, 64)
	var t0 := Time.get_ticks_msec()
	map.generate(7)
	print("carte de controle %d generee en %d ms" % [INVARIANT_SIZE, Time.get_ticks_msec() - t0])

	var failures := 0
	failures += _check_surface(map)
	failures += _check_biomes(map)
	failures += _check_cache()

	# Plusieurs tailles et plusieurs seeds : un biome peut sortir sur une carte
	# et manquer sur une autre, et ce n'est pas acceptable — une partie tiree
	# au hasard ne doit jamais se retrouver sans desert ni sans neige.
	for size in SIZES_TO_CHECK:
		for seed_value in SEEDS_TO_CHECK:
			var other := WorldMap.new(size, 64)
			other.generate(seed_value)
			var missing := _missing_biomes(other)
			if missing.is_empty():
				print("\n  %d / seed %d : les %d biomes sont presents"
					% [size, seed_value, WorldMap.Biome.values().size()])
			else:
				printerr("\n  %d / seed %d : manquent %s" % [size, seed_value, ", ".join(missing)])
				failures += 1

	_benchmark()

	if failures == 0:
		print("\nOK — tous les invariants passent.")
	else:
		printerr("\nECHEC — %d probleme(s)." % failures)
	quit(1 if failures > 0 else 0)

# Le generateur ecrit une distance signee : negative dans la matiere, positive
# dans le vide. La surface est donc la ou elle change de signe, et elle doit
# tomber sur l'altitude du sol annoncee par la carte.
#
# C'est l'invariant central du terrain lisse. S'il derive, le joueur se
# retrouve a flotter ou enterre, et la carte d'apercu ment sur ce qu'on
# trouvera en jeu. On balaie depuis le CIEL vers le bas : la premiere valeur
# negative rencontree est la surface, ce qui rend le controle insensible aux
# grottes, situees plus bas.
func _check_surface(map: WorldMap) -> int:
	print("\n--- surface produite par le generateur ---")

	var generator := TerrainGenerator.new()
	generator.map = map

	var checked := 0
	var drift_total := 0.0
	var worst := 0.0
	var worst_at := Vector2i(-1, -1)
	var missing := 0
	var bedrock_holes := 0

	var chunks := int(ceil(float(map.size_xz) / float(CHUNK)))
	@warning_ignore("integer_division")
	var chunks_y := map.size_y / CHUNK

	for cz in range(0, chunks, CHUNK_STRIDE):
		for cx in range(0, chunks, CHUNK_STRIDE):
			# Une colonne de chunks, du sol au ciel, pour retrouver la surface.
			var column: Array[VoxelBuffer] = []
			for cy in chunks_y:
				var buffer := VoxelBuffer.new()
				buffer.create(CHUNK, CHUNK, CHUNK)
				generator._generate_block(
					buffer, Vector3i(cx * CHUNK, cy * CHUNK, cz * CHUNK), 0)
				column.append(buffer)

			for lz in CHUNK:
				for lx in CHUNK:
					var wx := cx * CHUNK + lx
					var wz := cz * CHUNK + lz
					if wx >= map.size_xz or wz >= map.size_xz:
						continue

					# La bedrock du fond doit etre pleine partout.
					if column[0].get_voxel_f(lx, 0, lz, VoxelBuffer.CHANNEL_SDF) >= 0.0:
						bedrock_holes += 1

					var surface := -1
					for y in range(map.size_y - 1, -1, -1):
						@warning_ignore("integer_division")
						var buffer: VoxelBuffer = column[y / CHUNK]
						if buffer.get_voxel_f(lx, y % CHUNK, lz, VoxelBuffer.CHANNEL_SDF) < 0.0:
							surface = y
							break

					if surface < 0:
						missing += 1
						continue

					var drift := absf(float(surface) - float(map.terrain_height(wx, wz)))
					checked += 1
					drift_total += drift
					if drift > worst:
						worst = drift
						worst_at = Vector2i(wx, wz)

	print("  %d colonnes verifiees" % checked)
	if checked > 0:
		print("  ecart a la carte : %.2f voxel en moyenne, %.1f au pire (en %v)" % [
			drift_total / float(checked), worst, worst_at])
	print("  colonnes sans surface : %d" % missing)
	print("  trous dans la bedrock : %d" % bedrock_holes)

	var failures := 0
	if checked == 0:
		printerr("  le generateur ne produit aucune matiere")
		failures += 1
	if missing > 0:
		printerr("  des colonnes n'ont aucune surface : le joueur y tomberait sans fin")
		failures += 1
	if bedrock_holes > 0:
		printerr("  la bedrock est percee : le fond du monde n'est pas etanche")
		failures += 1
	if checked > 0 and drift_total / float(checked) > 1.5:
		printerr("  la surface derive de la carte : l'apercu ne dit pas la verite du terrain")
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

	# On exige que CHAQUE biome de l'enumeration sorte, sans liste choisie a la
	# main : un biome qu'on oublierait d'inscrire ici pourrait disparaitre sans
	# que rien ne le signale, et resterait du code mort dans le generateur.
	# Un biome doit aussi depasser un plancher de visibilite — trois colonnes
	# perdues sur une carte ne sont pas un biome, c'est un artefact.
	var failures := 0
	for required in WorldMap.Biome.values():
		var found := int(counts.get(required, 0))
		if found == 0:
			printerr("  ABSENT : %s" % map.biome_name(required))
			failures += 1
		elif float(found) / float(total) < MIN_BIOME_SHARE:
			printerr("  TROP RARE : %s, %d colonnes (%.3f %%)" % [
				map.biome_name(required), found, 100.0 * float(found) / float(total)])
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
	var flat := 0

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
			if map.slope_at(x, z) <= WorldMap.FLAT_SLOPE:
				flat += 1

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
	print("    terrain plat (pente <= %.2f) : %d (%.1f %%)" % [
		WorldMap.FLAT_SLOPE, flat, 100.0 * float(flat) / float(land)])


func _benchmark() -> void:
	print("\n--- cout ---")
	for size in [300, 600]:
		var map := WorldMap.new(size, 64)
		var t0 := Time.get_ticks_msec()
		map.generate(1)
		var map_ms := Time.get_ticks_msec() - t0

		# Cout d'un chunk au niveau du sol : c'est ce que godot_voxel paiera
		# par bloc, en tache de fond, pendant que le joueur se deplace.
		var generator := TerrainGenerator.new()
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


# Noms des biomes qui n'apparaissent pas, ou trop peu pour compter.
func _missing_biomes(map: WorldMap) -> PackedStringArray:
	var counts := {}
	for z in map.size_xz:
		for x in map.size_xz:
			var biome := map.biome_at(x, z)
			counts[biome] = int(counts.get(biome, 0)) + 1

	var total := map.size_xz * map.size_xz
	var missing := PackedStringArray()
	for biome in WorldMap.Biome.values():
		if float(int(counts.get(biome, 0))) / float(total) < MIN_BIOME_SHARE:
			missing.append(map.biome_name(biome))
	return missing


# Une carte relue du cache doit etre RIGOUREUSEMENT identique a celle qu'on
# vient de calculer. Sinon le cache introduit un bug invisible : l'apercu et
# la partie montreraient deux mondes differents pour la meme seed, et le
# desaccord serait mis sur le compte de la generation.
#
# On compare aussi la sortie du generateur 3D, ce qui verifie au passage que
# le bruit des grottes a bien ete rededuit de la seed — il n'est pas stocke.
func _check_cache() -> int:
	print("\n--- cache de cartes ---")

	var size := 300
	var seed_value := 424242

	var first := MapCache.load_or_generate(seed_value, size, 64)
	var second := MapCache.load_or_generate(seed_value, size, 64)

	if not MapCache.last_was_cached():
		printerr("  la seconde lecture n'est pas passee par le cache")
		return 1

	var mismatches := 0
	for z in size:
		for x in size:
			if first.terrain_height(x, z) != second.terrain_height(x, z) \
					or first.biome_at(x, z) != second.biome_at(x, z) \
					or not is_equal_approx(first.terrain_height_f(x, z), second.terrain_height_f(x, z)) \
					or not is_equal_approx(first.temperature_at(x, z), second.temperature_at(x, z)) \
					or not is_equal_approx(first.moisture_at(x, z), second.moisture_at(x, z)) \
					or not is_equal_approx(first.flow_at(x, z), second.flow_at(x, z)) \
					or not is_equal_approx(first.rain_shadow_at(x, z), second.rain_shadow_at(x, z)) \
					or not is_equal_approx(first.continentality_at(x, z), second.continentality_at(x, z)):
				mismatches += 1

	var cave_mismatches := 0
	var generators := [TerrainGenerator.new(), TerrainGenerator.new()]
	generators[0].map = first
	generators[1].map = second
	var centre := size / 2
	@warning_ignore("integer_division")
	var cy := first.terrain_height(centre, centre) / CHUNK
	var buffers := []
	for generator in generators:
		var buffer := VoxelBuffer.new()
		buffer.create(CHUNK, CHUNK, CHUNK)
		generator._generate_block(buffer, Vector3i(centre, cy * CHUNK, centre), 0)
		buffers.append(buffer)
	for y in CHUNK:
		for z in CHUNK:
			for x in CHUNK:
				var a: float = buffers[0].get_voxel_f(x, y, z, VoxelBuffer.CHANNEL_SDF)
				var b: float = buffers[1].get_voxel_f(x, y, z, VoxelBuffer.CHANNEL_SDF)
				if not is_equal_approx(a, b):
					cave_mismatches += 1

	print("  empreinte des reglages : %x" % (MapCache.parameters_hash() & 0xffffffff))
	print("  colonnes differentes : %d" % mismatches)
	print("  voxels differents dans un chunk temoin : %d" % cave_mismatches)

	var failures := 0
	if mismatches > 0:
		printerr("  la carte relue differe de la carte calculee")
		failures += 1
	if cave_mismatches > 0:
		printerr("  le terrain 3D differe : le bruit des grottes n'a pas ete rededuit")
		failures += 1
	return failures
