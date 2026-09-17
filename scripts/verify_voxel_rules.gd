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
	failures += _check_mesh_carries_materials(map)
	failures += _check_surface_materials(map)
	failures += _check_rivers(map)
	failures += _check_river_splines(map)
	failures += _check_caves(map)

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

					# Une ENTREE de grotte est un trou VOULU dans le sol, donc
					# le premier vide rencontre en descendant du ciel n'y est
					# pas la surface. La compter faisait sortir des ecarts de
					# treize voxels et laissait croire a une derive du
					# generateur, alors que c'est exactement ce que
					# `_check_caves` verifie par ailleurs — qu'une entree ouvre
					# bien un vide.
					#
					# Le commentaire en tete de cette fonction affirmait le
					# controle « insensible aux grottes, situees plus bas ». Il
					# l'est partout sauf ici, ou une grotte est par definition
					# en haut.
					if _near_entrance(map, wx, wz):
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

	# Le trace des rivieres doit survivre au cache, et il est le seul champ qui
	# ne puisse PAS se re-deriver : les hauteurs relues sont deja creusees, donc
	# retracer dessus suivrait le chenal au lieu de le reproduire. S'il se
	# perdait, rien ne le dirait — le monde relu serait identique, et seule la
	# passe qui posera la surface d'eau tomberait sur un reseau vide.
	var river_loss := 0
	if first.rivers.path_count() != second.rivers.path_count() \
			or first.rivers.point_count() != second.rivers.point_count():
		printerr("  le trace des rivieres ne survit pas au cache (%d/%d chemins, %d/%d points)"
			% [first.rivers.path_count(), second.rivers.path_count(),
				first.rivers.point_count(), second.rivers.point_count()])
		river_loss = 1

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
	return failures + river_loss


# Le maillage doit reellement transporter la matiere jusqu'au shader.
#
# `VoxelMesherTransvoxel.texturing_mode` vaut TEXTURES_NONE par defaut, et
# dans ce cas le mailleur n'ecrit AUCUNE donnee de matiere : l'attribut
# CUSTOM1 reste vide, le shader lit des indices nuls et peint tout le monde
# avec la couche 0. Rien n'est signale — le terrain sort simplement tout en
# herbe, et le choix du pack de textures parait ignore.
#
# C'est la panne exacte rencontree en jeu, et elle est invisible a la lecture
# du code : le generateur remplit correctement ses canaux, le materiau recoit
# bien son tableau, et pourtant rien n'arrive. D'ou ce controle.
func _check_mesh_carries_materials(map: WorldMap) -> int:
	print("\n--- transport des matieres jusqu'au maillage ---")

	var generator := TerrainGenerator.new()
	generator.map = map

	# Un chunk a cheval sur la surface, donc garanti de contenir un maillage.
	var centre := map.size_xz / 2
	@warning_ignore("integer_division")
	var cy := map.terrain_height(centre, centre) / CHUNK
	var buffer := VoxelBuffer.new()
	buffer.create(CHUNK, CHUNK, CHUNK)
	generator._generate_block(buffer, Vector3i(centre, cy * CHUNK, centre), 0)

	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_MIXEL4_S4
	mesher.textures_ignore_air_voxels = true

	var mesh: ArrayMesh = mesher.build_mesh(buffer, [], {})
	if mesh == null or mesh.get_surface_count() == 0:
		printerr("  le mailleur ne produit aucune surface sur un chunk de surface")
		return 1

	var arrays := mesh.surface_get_arrays(0)
	var custom1 = arrays[Mesh.ARRAY_CUSTOM1]
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	print("  sommets : %d" % vertices.size())

	if custom1 == null or (custom1 is PackedFloat32Array and custom1.is_empty()):
		printerr("  CUSTOM1 absent : le shader peindra tout avec la couche 0")
		return 1

	var non_zero := 0
	for value in custom1:
		if value != 0.0:
			non_zero += 1
	print("  CUSTOM1 : %d valeurs, dont %d non nulles" % [custom1.size(), non_zero])

	if non_zero == 0:
		printerr("  CUSTOM1 entierement nul : aucune matiere ne parvient au shader")
		return 1
	return 0


# La matiere portee par chaque sommet de surface doit etre celle que la carte
# annonce pour cette colonne. C'est la promesse que fait l'ecran de
# generation : ce qu'on y voit doit etre ce qu'on trouvera sur place.
#
# Le controle decode CUSTOM1 comme le fait le shader — les quatre indices
# tiennent dans les octets d'un flottant — et compare au biome de la colonne
# situee sous le sommet.
func _check_surface_materials(map: WorldMap) -> int:
	print("\n--- matiere des sommets de surface ---")

	var generator := TerrainGenerator.new()
	generator.map = map

	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_MIXEL4_S4
	mesher.textures_ignore_air_voxels = true

	var matched := 0
	var present := 0
	var empty := 0
	var seen_stride := 0
	var total := 0
	var confusions := {}

	# Plusieurs chunks repartis sur la carte, pour couvrir plusieurs biomes.
	for sample in 24:
		var cx := 4 + (sample % 6) * 2
		var cz := 4 + int(sample / 6.0) * 4
		var wx := cx * CHUNK + CHUNK / 2
		var wz := cz * CHUNK + CHUNK / 2
		if wx >= map.size_xz or wz >= map.size_xz:
			continue
		var ground := map.terrain_height(wx, wz)
		if ground <= WorldMap.SEA_LEVEL:
			continue
		@warning_ignore("integer_division")
		var cy := ground / CHUNK

		var origin := Vector3i(cx * CHUNK, cy * CHUNK, cz * CHUNK)
		var buffer := VoxelBuffer.new()
		buffer.create(CHUNK, CHUNK, CHUNK)
		generator._generate_block(buffer, origin, 0)

		var mesh: ArrayMesh = mesher.build_mesh(buffer, [], {})
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var custom1: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]

		# Le PAS est deduit, jamais suppose. CUSTOM1 peut arriver en RG (deux
		# flottants par sommet) comme en RGBA (quatre), et se tromper ne casse
		# rien de visible : on lit alors la seconde moitie du sommet precedent,
		# donc des zeros, et on conclut a des poids nuls — un sommet sur deux.
		@warning_ignore("integer_division")
		var stride: int = custom1.size() / maxi(vertices.size(), 1)
		if stride < 2:
			continue
		if stride != seen_stride:
			seen_stride = stride
			print("  CUSTOM1 : %d flottants par sommet" % stride)

		for i in vertices.size():
			var world := Vector3(origin) + vertices[i]
			var col_x := floori(world.x)
			var col_z := floori(world.z)
			if map.terrain_height(col_x, col_z) <= WorldMap.SEA_LEVEL:
				continue
			# Un sommet n'est de surface que s'il est a l'altitude du sol ;
			# les parois d'une grotte porteraient legitimement de la roche.
			if absf(world.y - float(map.terrain_height(col_x, col_z))) > 1.5:
				continue

			var biome := map.biome_at(col_x, col_z)
			var expected: int = generator.layer_for(map.surface_block(biome))
			var got := _dominant_layer(custom1[i * stride], custom1[i * stride + 1])

			total += 1
			if _weights_are_empty(
					PackedFloat32Array([custom1[i * stride + 1]]).to_byte_array()):
				empty += 1
			if got == expected:
				matched += 1
			# Ce qui est VRAIMENT invariant, c'est la PRESENCE de la matiere du
			# biome parmi les quatre emplacements — pas qu'elle y domine.
			#
			# Le taux de domination etait le seul critere tant qu'un voxel ne
			# portait qu'une matiere. Depuis que la surface est fondue, un
			# sommet a sept metres d'une limite porte legitimement celle du
			# voisin en majorite, et ce taux baisse a MESURE que le fondu
			# s'elargit — c'est-a-dire qu'il descend quand le rendu s'ameliore.
			# Le garder comme seul garde-fou revenait a plafonner la largeur du
			# fondu sans l'avoir decide.
			if _has_layer(custom1[i * stride], custom1[i * stride + 1], expected):
				present += 1
			else:
				var key := "%s attendu %d, obtenu %d" % [map.biome_name(biome), expected, got]
				confusions[key] = int(confusions.get(key, 0)) + 1

	if total == 0:
		printerr("  aucun sommet de surface echantillonne")
		return 1

	var rate := 100.0 * float(matched) / float(total)
	var present_rate := 100.0 * float(present) / float(total)
	print("  %d sommets de surface" % total)
	print("    %.1f %% PORTENT la matiere du biome (invariant, seuil 95 %%)" % present_rate)
	print("    %.1f %% l'ont pour matiere dominante (indicatif : baisse quand le fondu s'elargit)"
		% rate)
	print("    %.1f %% sortent du mailleur SANS aucun poids (repli sur le 1er emplacement)"
		% (100.0 * float(empty) / float(total)))
	var keys := confusions.keys()
	keys.sort_custom(func(a, b): return confusions[a] > confusions[b])
	for key in keys.slice(0, 5):
		print("    %-44s %d sommets" % [key, confusions[key]])

	if present_rate < 95.0:
		printerr("  la matiere du biome est ABSENTE de trop de sommets")
		return 1
	return 0


# Indice de la matiere au poids le plus fort, decode comme le fait le shader :
# quatre indices dans les octets de CUSTOM1.x, quatre poids dans CUSTOM1.y.
# La matiere figure-t-elle parmi les quatre, avec un poids non nul ?
#
# Le decodage doit reproduire EXACTEMENT celui du shader, replis compris, sinon
# le controle mesure autre chose que ce qui s'affiche. En particulier, une part
# des sommets sort du mailleur avec quatre poids nuls ; le shader retombe alors
# sur le premier emplacement (voir smooth_terrain.gdshader), et c'est donc bien
# cette matiere-la qui est peinte.
func _has_layer(packed_indices: float, packed_weights: float, layer: int) -> bool:
	var indices := PackedFloat32Array([packed_indices]).to_byte_array()
	var weights := PackedFloat32Array([packed_weights]).to_byte_array()
	if _weights_are_empty(weights):
		return indices[0] == layer
	for slot in 4:
		if indices[slot] == layer and weights[slot] > 0:
			return true
	return false


func _weights_are_empty(weights: PackedByteArray) -> bool:
	return weights[0] + weights[1] + weights[2] + weights[3] == 0


func _dominant_layer(packed_indices: float, packed_weights: float) -> int:
	var indices := PackedFloat32Array([packed_indices]).to_byte_array()
	var weights := PackedFloat32Array([packed_weights]).to_byte_array()
	var best := 0
	var best_weight := -1
	for slot in 4:
		if weights[slot] > best_weight:
			best_weight = weights[slot]
			best = indices[slot]
	return best



# L'emprise des rivieres : le contour du creusement et la surface qu'il
# delimite.
func _check_river_splines(map: WorldMap) -> int:
	print("\n--- emprise des rivieres ---")
	var splines := RiverSplines.new()
	splines.setup(map)
	return _check_river_outlines(map, splines)


# Le contour des berges doit TOUCHER le terrain, etre ferme, et se tenir en
# HAUT du talus.
#
# Les trois sont la demande, et le premier est celui qui ne se voit pas :
# quelques centimetres de decollement passent inapercus a l'ecran et trahissent
# pourtant tout ce qui voudrait s'appuyer dessus. On mesure donc l'ecart entre
# chaque point de controle et le sol sous lui.
#
# « En haut du talus » se mesure par comparaison avec le FOND : un contour qui
# aurait glisse dans le chenal serait au niveau du lit, pas plusieurs metres
# au-dessus.
func _check_river_outlines(map: WorldMap, splines: RiverSplines) -> int:
	var outlines := splines.find_children("Berges*", "Path3D", false, false)
	print("  %d contours de berge, %d points de controle au total"
		% [outlines.size(), _control_points(outlines)])

	# Le nombre de contours n'est PAS celui des rivieres : deux rivieres qui se
	# rejoignent ne creusent qu'une seule region, donc ne bordent qu'un seul
	# contour. On attend donc nettement moins de boucles que de tronçons — si
	# les deux nombres se rapprochaient, c'est que les contours auraient cesse
	# de fusionner.
	var failures := 0
	if outlines.is_empty():
		printerr("  aucun contour de berge")
		return 1
	if outlines.size() >= map.rivers.path_count():
		printerr("  %d contours pour %d rivieres : ils ne fusionnent pas aux confluences"
			% [outlines.size(), map.rivers.path_count()])
		failures += 1

	var points := 0
	var detached := 0
	var worst_gap := 0.0
	var gap_total := 0.0
	var open_loops := 0
	var in_channel := 0
	var rise_total := 0.0

	for node in outlines:
		var curve: Curve3D = (node as Path3D).curve
		if curve == null or curve.point_count < 4:
			printerr("  un contour est trop court pour delimiter quoi que ce soit")
			failures += 1
			continue
		# Ferme : le dernier point revient sur le premier.
		if curve.get_point_position(0).distance_to(
				curve.get_point_position(curve.point_count - 1)) > 0.01:
			open_loops += 1

		for i in curve.point_count:
			var point := curve.get_point_position(i)
			points += 1
			var gap := absf(point.y - _ground_f(map, point.x, point.z))
			gap_total += gap
			worst_gap = maxf(worst_gap, gap)
			if gap > OUTLINE_CONTACT:
				detached += 1

	# Hauteur du contour au-dessus du fond voisin : c'est ce qui distingue une
	# crete de berge d'un trait tombe dans le lit.
	#
	# Le fond se lit sur le TERRAIN et non sur un axe de riviere — un contour
	# fusionne n'appartient plus a une riviere en particulier, et il n'existe de
	# toute facon plus d'axe depuis que le repere cyan a ete retire. Le point le
	# plus bas du voisinage est le fond du chenal que le contour longe.
	var compared := 0
	for node in outlines:
		var outline: Curve3D = (node as Path3D).curve
		if outline == null:
			continue
		for i in outline.point_count:
			var point := outline.get_point_position(i)
			var bed := INF
			for dz in range(-BED_LOOKUP, BED_LOOKUP + 1):
				for dx in range(-BED_LOOKUP, BED_LOOKUP + 1):
					bed = minf(bed, map.terrain_height_f(
						roundi(point.x) + dx, roundi(point.z) + dz))
			if bed == INF:
				continue
			compared += 1
			var rise := point.y - bed
			rise_total += rise
			if rise < 0.4:
				in_channel += 1

	print("  contact au sol : %.3f m d'ecart moyen, %.2f m au pire (%d points)"
		% [gap_total / float(maxi(points, 1)), worst_gap, points])
	if compared > 0:
		print("  hauteur au-dessus du fond : %.2f m en moyenne, %d point(s) restes dans le lit"
			% [rise_total / float(compared), in_channel])

	if detached > 0:
		printerr("  %d point(s) de contour ne touchent pas la berge (plus de %.2f m)"
			% [detached, OUTLINE_CONTACT])
		failures += 1
	if open_loops > 0:
		printerr("  %d contour(s) ne se referment pas" % open_loops)
		failures += 1
	if compared > 0 and float(in_channel) / float(compared) > 0.15:
		printerr("  le contour retombe dans le chenal au lieu de suivre la crete")
		failures += 1
	return failures + _check_river_fill(map, splines)


# Le remplissage doit couvrir CE QUE LE CONTOUR DELIMITE, ni plus ni moins.
#
# Les deux sortent du meme champ, donc un ecart entre eux ne pourrait venir que
# d'une divergence entre le trace du bord et le decoupage de l'interieur — le
# genre de desaccord qui se voit en jeu comme un liseré vert debordant sur la
# prairie, et qui ne se lit pas du tout dans le code.
func _check_river_fill(map: WorldMap, splines: RiverSplines) -> int:
	var meshes := splines.find_children("Surface", "MeshInstance3D", false, false)
	if meshes.size() != 1:
		printerr("  %d surface(s) de remplissage au lieu d'une" % meshes.size())
		return 1
	var mesh: ArrayMesh = (meshes[0] as MeshInstance3D).mesh
	if mesh == null or mesh.get_surface_count() != 1:
		printerr("  le remplissage ne sort pas une surface unique")
		return 1

	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var outside := 0
	var buried := 0
	var worst_dip := 0.0
	var depth_total := 0.0
	for v in vertices:
		# Le creusement est exactement ce que le biome RIVER couvre, berges
		# comprises — sauf sous le niveau marin, rendu a la mer.
		var inside := false
		for cz in [floori(v.z), ceili(v.z)]:
			for cx in [floori(v.x), ceili(v.x)]:
				if map.is_river(cx, cz) \
						or map.terrain_height(cx, cz) <= WorldMap.SEA_LEVEL:
					inside = true
		if not inside:
			outside += 1

		# C'est un PLAN D'EAU : il se tient au-dessus du lit, jamais dedans.
		# Un remplissage qui epouserait le terrain donnerait une epaisseur nulle
		# partout, et c'est exactement le defaut qu'on vient de corriger.
		var ground := _ground_f(map, v.x, v.z)
		depth_total += v.y - ground
		if v.y < ground - FILL_TOLERANCE:
			buried += 1
			worst_dip = maxf(worst_dip, ground - v.y)

	@warning_ignore("integer_division")
	print("  remplissage : 1 surface, %d triangles · %.2f m d'eau en moyenne"
		% [vertices.size() / 3, depth_total / float(maxi(vertices.size(), 1))])
	if vertices.size() < 3:
		printerr("  le remplissage est vide")
		return 1
	var failures := 0
	if outside > 0:
		printerr("  %d sommet(s) de remplissage hors du creusement" % outside)
		failures += 1
	if buried > 0:
		printerr("  %d sommet(s) de remplissage sous le terrain, jusqu'a %.2f m"
			% [buried, worst_dip])
		failures += 1

	# La REQUETE doit dire la meme chose que le MAILLAGE.
	#
	# Deux facons de connaitre l'altitude de l'eau cohabitent : les triangles
	# qu'on voit, et `water_level_at` qui decide si un oeil est immerge. Rien
	# n'oblige les deux a rester d'accord, et un desaccord ne se verrait pas —
	# l'ecran montrerait de l'eau la ou le joueur respire, ou l'inverse.
	var mismatched := 0
	var silent := 0
	for v in vertices:
		# Les QUATRE colonnes qui encadrent le sommet, et non la plus proche.
		#
		# Un sommet de maillage tombe entre les colonnes ; son altitude est
		# interpolee entre celles de ses voisines. Le confronter a une seule
		# d'entre elles reprochait a la requete un ecart qui n'est que celui de
		# l'interpolation — et au droit d'une cascade, ou la nappe descend d'un
		# metre par colonne, cet ecart depasse n'importe quelle tolerance.
		var low := INF
		var high := -INF
		var dry := false
		for cz in [floori(v.z), ceili(v.z)]:
			for cx in [floori(v.x), ceili(v.x)]:
				var answered := splines.water_level_at(cx, cz)
				if answered == -INF:
					dry = true
					continue
				low = minf(low, answered)
				high = maxf(high, answered)
		# Un sommet de BORD est encadre par au moins une colonne seche, et son
		# altitude est alors interpolee avec une valeur que la requete ne rend
		# pas — les deux different par construction, pas par erreur. C'est
		# l'interieur qui doit concorder.
		if dry or low == INF:
			silent += 1
			continue
		var height := v.y - RiverSplines.FILL_HOVER
		if height < low - 0.25 or height > high + 0.25:
			mismatched += 1
	print("  requete d'immersion : %d sommet(s) de bord ecartes, %d en desaccord"
		% [silent, mismatched])
	# Si presque tout le maillage etait « de bord », c'est que la requete aurait
	# cesse de repondre pour l'interieur, et le controle ne verifierait plus rien.
	if float(silent) / float(vertices.size()) > 0.75:
		printerr("  la requete d'immersion ne repond plus pour l'interieur de la nappe")
		failures += 1
	if mismatched > 0:
		printerr("  la requete d'immersion ne dit pas la meme altitude que la nappe")
		failures += 1
	return failures


func _control_points(paths: Array[Node]) -> int:
	var total := 0
	for node in paths:
		var curve: Curve3D = (node as Path3D).curve
		if curve != null:
			total += curve.point_count
	return total


# Altitude du sol interpolee bilineairement, le terrain etant un champ continu.
func _ground_f(map: WorldMap, x: float, z: float) -> float:
	var x0 := floori(x)
	var z0 := floori(z)
	var tx := x - float(x0)
	var tz := z - float(z0)
	return lerpf(
		lerpf(map.terrain_height_f(x0, z0), map.terrain_height_f(x0 + 1, z0), tx),
		lerpf(map.terrain_height_f(x0, z0 + 1), map.terrain_height_f(x0 + 1, z0 + 1), tx),
		tz)


# Marge autour d'une bouche d'entree, en colonnes. Un peu plus large que
# ENTRANCE_RADIUS : la galerie s'evase en debouchant.
# Demi-cote du voisinage ou l'on cherche le fond du chenal, en colonnes. Un
# chenal fait un a quatre metres de large et le contour longe sa berge : six
# colonnes suffisent a atteindre le lit depuis la crete, sans aller chercher
# celui de la riviere d'a cote.
const BED_LOOKUP := 6

# Enfoncement tolere pour un sommet de remplissage, en metres. La membrane
# rejoint le terrain sur tout son bord : quelques centimetres d'ecart y sont le
# pas de la grille, pas un defaut.
const FILL_TOLERANCE := 0.10

# Ecart au sol tolere pour un point de contour, en metres. La demande est qu'ils
# TOUCHENT la berge : deux centimetres, soit la precision de la recherche de
# crete, pas un degagement.
const OUTLINE_CONTACT := 0.02

# Marge autour d'une bouche d'entree, en colonnes. Un peu plus large que
# ENTRANCE_RADIUS : la galerie s'evase en debouchant.
const ENTRANCE_MARGIN := 7


func _near_entrance(map: WorldMap, x: int, z: int) -> bool:
	for mouth in map.cave_entrances():
		if absi(mouth.x - x) <= ENTRANCE_MARGIN and absi(mouth.z - z) <= ENTRANCE_MARGIN:
			return true
	return false


# Le reseau de rivieres doit etre un CHENAL, pas une etiquette.
#
# C'est exactement ce qu'il n'etait pas jusqu'ici : une colonne au-dessus d'un
# quantile de debit, baissee d'un voxel et peinte en gravier. Rien ne le
# signalait, parce que tout ce qui se verifiait — le biome existe, il a une
# matiere — etait vrai. Ce qui manquait ne se voyait qu'a l'oeil, en jeu.
#
# Les quatre controles ci-dessous sont donc ceux qui auraient attrape ce cas :
# le lit a-t-il une largeur, une profondeur, une issue, et la matiere du fond
# survit-elle au fondu de dix metres du generateur.
func _check_rivers(map: WorldMap) -> int:
	print("\n--- reseau de rivieres ---")
	var network := map.rivers
	var points := network.point_count()
	if network.path_count() == 0 or points == 0:
		printerr("  aucun chenal trace : l'ile n'a pas de riviere")
		return 1

	var beds := 0
	var land := 0
	for z in map.size_xz:
		for x in map.size_xz:
			if map.terrain_height(x, z) <= WorldMap.SEA_LEVEL:
				continue
			land += 1
			if map.biome_at(x, z) == WorldMap.Biome.RIVER:
				beds += 1
	print("  %d chemins, %d points, %d colonnes de lit (%.2f %% des terres)"
		% [network.path_count(), points, beds,
			100.0 * float(beds) / float(maxi(land, 1))])

	var failures := 0

	# 1. LARGEUR. C'est la demande meme : entre un et quatre metres.
	# 2. ISSUE. Un chemin se termine a la mer ou sur un autre chemin ; s'il
	#    s'arrete au milieu d'un pre, le percement des cuvettes a lache.
	# 3. PROFONDEUR. Mesuree sur la carte FINALE, en comparant le fond au
	#    terrain juste au-dela de la berge — donc sur le resultat du
	#    creusement, pas sur l'intention du trace.
	var occupied := {}
	for index in network.path_count():
		var path := network.path(index)
		@warning_ignore("integer_division")
		var count: int = path.size() / 4
		for k in count:
			var cell := int(path[k * 4 + 1]) * map.size_xz + int(path[k * 4])
			occupied[cell] = occupied.get(cell, 0) + 1

	var width_errors := 0
	var stranded := 0
	var depth_total := 0.0
	var depth_samples := 0
	var shallow := 0
	var above_ground := 0

	for index in network.path_count():
		var path := network.path(index)
		@warning_ignore("integer_division")
		var count: int = path.size() / 4
		for k in count:
			var x := int(path[k * 4])
			var z := int(path[k * 4 + 1])
			var bed := path[k * 4 + 2]
			var half_width := path[k * 4 + 3]

			var width := half_width * 2.0
			if width < RiverNetwork.WIDTH_MIN - 0.01 \
					or width > RiverNetwork.WIDTH_MAX + 0.01:
				width_errors += 1

			# Le fond doit reellement etre descendu a l'altitude visee : si la
			# carte est plus haute que le trace, le tampon n'a pas pris.
			if map.terrain_height_f(x, z) > bed + 0.01:
				above_ground += 1

			# Profondeur reelle : le point haut des berges, juste au-dela de la
			# portee du tampon, moins le fond.
			var reach := ceili(half_width + RiverNetwork.BANK) + 1
			var rim := -INF
			for d in [Vector2i(reach, 0), Vector2i(-reach, 0),
					Vector2i(0, reach), Vector2i(0, -reach)]:
				var h := map.terrain_height_f(x + d.x, z + d.y)
				if h > rim:
					rim = h
			if rim > -INF:
				var drop := rim - map.terrain_height_f(x, z)
				depth_total += drop
				depth_samples += 1
				if drop < 0.4:
					shallow += 1

		if count == 0:
			continue
		var last_z := int(path[(count - 1) * 4 + 1])
		var last_x := int(path[(count - 1) * 4])
		var last_cell := last_z * map.size_xz + last_x
		var at_sea := map.terrain_height(last_x, last_z) <= WorldMap.SEA_LEVEL
		# Une confluence se reconnait a un point partage par deux chemins : le
		# tributaire pose son dernier point sur le tronc.
		var joins: int = occupied.get(last_cell, 0)
		if not at_sea and joins < 2:
			stranded += 1

	if width_errors > 0:
		printerr("  %d point(s) hors de la largeur annoncee (%.1f - %.1f m)"
			% [width_errors, RiverNetwork.WIDTH_MIN, RiverNetwork.WIDTH_MAX])
		failures += 1
	if above_ground > 0:
		printerr("  %d point(s) dont le lit n'a pas ete creuse" % above_ground)
		failures += 1
	if stranded > 0:
		printerr("  %d chemin(s) s'arretent sans rejoindre ni la mer ni un autre"
			% stranded)
		failures += 1

	if depth_samples > 0:
		var mean := depth_total / float(depth_samples)
		print("  profondeur moyenne sous les berges : %.2f m (%d points a moins de 0,4 m)"
			% [mean, shallow])
		# Le seuil est volontairement bas : une bonne part du reseau traverse
		# des plaines ou les berges ne depassent pas la profondeur minimale, et
		# exiger la moyenne des deux bornes reviendrait a exiger du relief.
		if mean < RiverNetwork.DEPTH_MIN * 0.6:
			printerr("  le lit n'est pas un chenal : trop peu creuse en moyenne")
			failures += 1

	failures += _check_river_material(map)
	return failures


# 4. LA MATIERE DU FOND, mesuree dans le maillage reel.
#
# C'est le controle qui compte le plus, parce que c'est celui qui echouait sans
# le dire. Le noyau de fondu du generateur porte a dix metres : un ruban de
# gravier de deux metres y pesait moins de la moitie du melange, et le fond du
# chenal se lisait comme de l'herbe un peu grise. Le creusement etait juste, et
# invisible.
#
# FOND ET TALUS SONT MESURES SEPAREMENT, et c'est ce qui rend le chiffre
# lisible. Le biome RIVER couvre tout le creusement, berges comprises ; exiger
# que le gravier domine jusqu'au bord reviendrait a exiger qu'il n'y ait pas de
# transition, alors que la transition est precisement ce qu'on veut la. On
# demande donc au FOND de dominer, et au talus de simplement porter la matiere
# — ce qui suffit au pinceau du shader pour l'y faire surgir par plaques.
func _check_river_material(map: WorldMap) -> int:
	var generator := TerrainGenerator.new()
	generator.map = map

	# Le fond, c'est-a-dire les colonnes a moins d'une demi-largeur de l'axe.
	# Rasterise depuis le trace, la seule source qui connaisse l'axe.
	var floor_cells := {}
	for index in map.rivers.path_count():
		var path := map.rivers.path(index)
		@warning_ignore("integer_division")
		var count: int = path.size() / 4
		for k in count:
			var px := path[k * 4]
			var pz := path[k * 4 + 1]
			var half_width := path[k * 4 + 3]
			var span := ceili(half_width)
			for dz in range(-span, span + 1):
				for dx in range(-span, span + 1):
					if sqrt(float(dx * dx + dz * dz)) > half_width:
						continue
					floor_cells[int(pz + dz) * map.size_xz + int(px + dx)] = true

	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_MIXEL4_S4
	mesher.textures_ignore_air_voxels = true

	var expected: int = generator.layer_for(
		map.surface_block(WorldMap.Biome.RIVER))
	var seen := 0
	var dominant := 0
	var present := 0
	var bank_seen := 0
	var bank_present := 0
	var visited_chunks := {}

	# On echantillonne les chunks QUI CONTIENNENT du lit, plutot qu'une grille
	# reguliere : a deux pour cent des terres, une grille les manquerait
	# presque toujours.
	for z in range(0, map.size_xz, 3):
		for x in range(0, map.size_xz, 3):
			if visited_chunks.size() >= 12:
				break
			if map.biome_at(x, z) != WorldMap.Biome.RIVER:
				continue
			@warning_ignore("integer_division")
			var key := Vector3i(x / CHUNK, map.terrain_height(x, z) / CHUNK,
				z / CHUNK)
			if visited_chunks.has(key):
				continue
			visited_chunks[key] = true

			var origin := key * CHUNK
			var buffer := VoxelBuffer.new()
			buffer.create(CHUNK, CHUNK, CHUNK)
			generator._generate_block(buffer, origin, 0)
			var mesh: ArrayMesh = mesher.build_mesh(buffer, [], {})
			if mesh == null or mesh.get_surface_count() == 0:
				continue
			var arrays := mesh.surface_get_arrays(0)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var custom1: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM1]
			@warning_ignore("integer_division")
			var stride: int = custom1.size() / maxi(vertices.size(), 1)
			if stride < 2:
				continue

			for i in vertices.size():
				var world := Vector3(origin) + vertices[i]
				var col_x := floori(world.x)
				var col_z := floori(world.z)
				if map.biome_at(col_x, col_z) != WorldMap.Biome.RIVER:
					continue
				if absf(world.y - float(map.terrain_height(col_x, col_z))) > 1.5:
					continue
				var carries := _has_layer(
					custom1[i * stride], custom1[i * stride + 1], expected)
				if not floor_cells.has(col_z * map.size_xz + col_x):
					bank_seen += 1
					if carries:
						bank_present += 1
					continue
				seen += 1
				if carries:
					present += 1
				if _dominant_layer(custom1[i * stride],
						custom1[i * stride + 1]) == expected:
					dominant += 1

	if seen == 0:
		printerr("  aucun sommet de fond dans les chunks echantillonnes")
		return 1

	var share := 100.0 * float(dominant) / float(seen)
	print("  fond  : %.1f %% des sommets en gravier dominant, %.1f %% le portent (%d sommets)"
		% [share, 100.0 * float(present) / float(seen), seen])
	if bank_seen > 0:
		print("  talus : %.1f %% portent le gravier (%d sommets)"
			% [100.0 * float(bank_present) / float(bank_seen), bank_seen])

	var failures := 0
	# Le fond doit etre franchement graveleux : c'est la seule preuve que le
	# noyau etroit tient face au fondu de dix metres.
	if share < 70.0:
		printerr("  le gravier du fond est noye par le fondu de surface")
		failures += 1
	# Le talus n'a pas a etre domine, mais il doit PORTER le gravier : sans lui
	# parmi les quatre emplacements, le pinceau du shader n'a rien a delayer et
	# la berge redevient un bord net.
	if bank_seen > 0 and float(bank_present) / float(bank_seen) < 0.9:
		printerr("  le talus ne porte pas le gravier : la berge sera un bord net")
		failures += 1
	return failures


# Le reseau de grottes doit etre ACCESSIBLE, connexe, et sec.
#
# Les trois se verifient parce que les trois ont deja manque. Le systeme
# precedent — un bruit 3D — produisait des cavites correctes et parfaitement
# inutiles : la marge qui l'empechait d'ouvrir des trous beants lui interdisait
# toute entree, si bien qu'aucune n'etait atteignable. Rien ne le signalait.
#
# L'ouverture est controlee EN PASSANT PAR LE GENERATEUR, pas en relisant le
# reseau : c'est le seul moyen de savoir que le trou existe vraiment dans les
# voxels, et pas seulement dans la geometrie qui a servi a les calculer.
func _check_caves(map: WorldMap) -> int:
	print("\n--- reseau de grottes ---")
	var rooms := map.cave_rooms()
	var entrances := map.cave_entrances()
	print("  %d salles, %d galeries elementaires, %d entrees"
		% [rooms.size(), map.cave_capsule_count(), entrances.size()])

	var failures := 0
	if rooms.size() < 4 or entrances.is_empty():
		printerr("  reseau trop pauvre pour etre explorable")
		return 1

	var lost := map.caves.unreachable_rooms()
	if lost > 0:
		printerr("  %d salle(s) qu'aucune entree n'atteint" % lost)
		failures += 1
	else:
		print("  toutes les salles sont reliees a une entree")

	# Aucune galerie ne doit passer sous la mer : on n'y simule aucun
	# ecoulement, donc une breche noierait le reseau sans que rien ne le dise.
	var flooded := 0
	for room in rooms:
		if map.terrain_height(int(room.x), int(room.z)) <= WorldMap.SEA_LEVEL:
			flooded += 1
	if flooded > 0:
		printerr("  %d salle(s) sous le niveau de la mer" % flooded)
		failures += 1

	# Ouverture reelle, mesuree dans les voxels produits par le generateur.
	var generator := TerrainGenerator.new()
	generator.map = map
	var opened := 0
	for entrance in entrances:
		if map.terrain_height(entrance.x, entrance.z) <= WorldMap.SEA_LEVEL:
			printerr("  une entree debouche sous la mer en %v" % entrance)
			failures += 1
			continue
		# Un vide dans les quelques voxels sous la bouche suffit : c'est ce que
		# le joueur franchit.
		var origin := Vector3i(entrance.x - 8, entrance.y - 12, entrance.z - 8)
		var buffer := VoxelBuffer.new()
		buffer.create(16, 16, 16)
		generator._generate_block(buffer, origin, 0)
		for y in 16:
			if buffer.get_voxel_f(8, y, 8, VoxelBuffer.CHANNEL_SDF) > 0.0 \
					and origin.y + y < map.terrain_height(entrance.x, entrance.z):
				opened += 1
				break

	print("  %d entrees sur %d ouvrent reellement un vide" % [opened, entrances.size()])
	if opened == 0:
		printerr("  aucune entree n'est praticable : les grottes sont introuvables")
		failures += 1
	return failures
