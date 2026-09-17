class_name CaveNetwork
extends RefCounted

# Reseau de grottes : des salles reliees par des galeries, avec des entrees
# depuis la surface.
#
# Il remplace le bruit 3D qui servait jusqu'ici. Le bruit produisait des poches
# rapides et infinies, mais sans structure : aucune garantie que deux cavites
# communiquent, pas de salles distinctes, et surtout aucune entree — la marge
# sous la surface qui empechait les trous beants empechait du meme coup toute
# ouverture. Les grottes existaient donc sans que le joueur puisse jamais en
# trouver une.
#
# CE RESEAU N'EST PAS CREUSE, IL EST EVALUE.
#
# La voie courante avec godot_voxel est de creuser apres coup avec
# `VoxelTool.do_path`. Elle ne convient pas ici, pour trois raisons qui tiennent
# toutes a ce projet-ci :
#
# - `VoxelTool` ne modifie que les blocs CHARGES. Notre ile fait 600 m pour
#   384 m de distance de vue : creuser au demarrage echouerait silencieusement
#   sur toute la moitie non chargee.
# - creuser produit des blocs MODIFIES, qu'il faut alors persister. Le projet
#   n'a aucun `VoxelStream` : le monde est entierement redérive de la graine a
#   chaque lancement, et c'est ce qui le rend gratuit a sauvegarder.
# - le jeu est cooperatif. Un monde derive de la graine est identique sur les
#   deux machines sans rien synchroniser ; des blocs creuses, non.
#
# Evalue comme une distance signee, le reseau garde toutes ces proprietes et se
# branche a la place exacte du bruit. Il est de plus consultable AVANT la
# partie, ce qui permet a l'ecran d'apercu de montrer les entrees et aux
# controles de verifier que le reseau est connexe.

# --- Geometrie du reseau ---

# Une salle pour 30 m de cote : une quinzaine sur une carte de 450.
const ROOMS_PER_SIDE := 1.0 / 30.0
const ROOM_MIN := 6
const ROOM_MAX := 26
const ROOM_SPACING := 18.0
const ROOM_RADIUS_MIN := 4.0
const ROOM_RADIUS_MAX := 8.5

const TUNNEL_RADIUS := 2.6
const ENTRANCE_RADIUS := 3.2
# Longueur de segment apres subdivision. Plus court = galerie plus sinueuse,
# mais plus de capsules a tester par voxel.
const SEGMENT_LENGTH := 5.0

# Epaisseur de roche a laisser SOUS la surface. C'est ce qui empeche une salle
# d'effondrer le sol au-dessus d'elle — et, sous la mer, d'inonder le reseau.
const ROOF := 7
# Marge au-dessus de la bedrock.
const FLOOR_MARGIN := 3

# Une entree ne s'ouvre que bien au-dessus du niveau marin : le projet interdit
# de tomber sur de l'eau en creusant, et une galerie qui deboucherait sur une
# plage se remplirait sans qu'on simule le moindre ecoulement.
const ENTRANCE_MIN_ALTITUDE := 8

# Distance a tenir entre une bouche d'entree et la moindre colonne de riviere.
#
# Elle couvre l'evasement de l'entree et la largeur du plan d'eau, qui monte
# jusqu'au haut des berges. En dessous, une entree ouverte au bord d'un chenal
# debouche sous l'eau.
const RIVER_CLEARANCE := 8
const ENTRANCE_COUNT_MIN := 2
const ENTRANCE_PER_ROOMS := 0.25

# Amplitude de la sinuosite des galeries, en metres.
const WANDER_XZ := 5.0
const WANDER_Y := 2.0

# --- Acceleration spatiale ---
#
# Chaque capsule est inscrite dans les cases XZ que sa boite englobante
# touche. Sans cela il faudrait tester les quelques centaines de capsules du
# reseau pour CHAQUE voxel, ce qui couterait bien plus que le bruit remplace.
const BUCKET := 16

# Capsules : chaque entree est (ax, ay, az, bx, by, bz, rayon).
var _capsules := PackedFloat32Array()
var _buckets := {}
# Bande d altitudes de tout le reseau, pour ecarter d un test un chunk qui
# n en croise aucune partie.
var _lowest := 0
var _highest := -1
# Recopies a la construction plutot que lues sur WorldMap : cette classe est
# utilisee PAR WorldMap, et la nommer ici formerait un cycle que GDScript ne
# sait pas resoudre a l analyse.
var _sea_level := 0
var _bedrock := 0
# Indice de la premiere capsule appartenant a une entree : le parcours de
# connexite part de la.
var _first_entrance_capsule := 0
# Position et rayon des salles, pour l'apercu et les controles.
var rooms: Array[Vector4] = []
# Colonnes ou une galerie perce la surface.
var entrances: Array[Vector3i] = []


# `map` est deja generee : on lit ses hauteurs pour rester sous terre.
func build(map, seed_value: int, sea_level: int, bedrock_depth: int) -> void:
	_sea_level = sea_level
	_bedrock = bedrock_depth
	_capsules = PackedFloat32Array()
	_buckets = {}
	rooms = []
	entrances = []
	_lowest = 0
	_highest = -1
	_first_entrance_capsule = 0

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7919 + 13
	var wander := FastNoiseLite.new()
	wander.seed = seed_value + 5
	wander.frequency = 0.05

	_place_rooms(map, rng)
	if rooms.size() < 2:
		return
	for edge in _connect_rooms(rng):
		_carve_tunnel(map, wander,
			_room_center(edge.x), _room_center(edge.y), TUNNEL_RADIUS)
	_first_entrance_capsule = capsule_count()
	_open_entrances(map, rng, wander)


# --- Interrogation ----------------------------------------------------------

# Les capsules qui concernent VRAIMENT cette colonne.
#
# Le filtrage se fait en deux temps, et les deux comptent. La case de 16 m
# donne un premier tri par acces de dictionnaire ; elle laisse encore des
# dizaines de capsules, et les tester toutes pour chacun des soixante-quatre
# voxels d'une colonne coutait des centaines de milliers de distances par
# chunk — la generation passait de cinq millisecondes a plusieurs secondes.
#
# On projette donc au sol : une capsule ne concerne la colonne que si la
# distance HORIZONTALE a son segment est inferieure a son rayon. Il n'en reste
# alors qu'une poignee, et la boucle par voxel redevient negligeable.
#
# La fonction est PURE, sans etat : elle est appelee depuis les threads de
# streaming, ou tout cache partage serait une course.
func column(x: int, z: int) -> PackedInt32Array:
	@warning_ignore("integer_division")
	var key := Vector2i(x / BUCKET, z / BUCKET)
	var candidates: PackedInt32Array = _buckets.get(key, PackedInt32Array())
	if candidates.is_empty():
		return candidates

	var px := float(x)
	var pz := float(z)
	var kept := PackedInt32Array()

	for i in candidates:
		var o := i * 7
		var ax := _capsules[o]
		var az := _capsules[o + 2]
		var bx := _capsules[o + 3] - ax
		var bz := _capsules[o + 5] - az
		var radius := _capsules[o + 6]

		var length_sq := bx * bx + bz * bz
		var t := 0.0
		if length_sq > 0.0001:
			t = clampf(((px - ax) * bx + (pz - az) * bz) / length_sq, 0.0, 1.0)
		var dx := px - (ax + bx * t)
		var dz := pz - (az + bz * t)
		if dx * dx + dz * dz <= radius * radius:
			kept.append(i)
	return kept


# Bande d'altitudes que ces capsules peuvent toucher. Le generateur s'en sert
# pour ne tester les grottes que sur les quelques voxels concernes, au lieu de
# toute la hauteur du chunk.
func y_bounds(indices: PackedInt32Array) -> Vector2i:
	if indices.is_empty():
		return Vector2i(1, 0)
	var low := INF
	var high := -INF
	for i in indices:
		var o := i * 7
		var radius := _capsules[o + 6]
		low = minf(low, minf(_capsules[o + 1], _capsules[o + 4]) - radius)
		high = maxf(high, maxf(_capsules[o + 1], _capsules[o + 4]) + radius)
	return Vector2i(floori(low), ceili(high))


# Une capsule touche-t-elle ce pave ? Sert au generateur pour remplir d'un bloc
# les chunks souterrains que le reseau ne concerne pas, sans les parcourir.
func touches(min_x: int, min_z: int, max_x: int, max_z: int,
		min_y: int, max_y: int) -> bool:
	if max_y < _lowest or min_y > _highest:
		return false
	for bz in range(floori(float(min_z) / BUCKET), floori(float(max_z) / BUCKET) + 1):
		for bx in range(floori(float(min_x) / BUCKET), floori(float(max_x) / BUCKET) + 1):
			if _buckets.has(Vector2i(bx, bz)):
				return true
	return false


# Distance signee au vide : POSITIVE dans la grotte, negative dans la roche.
# C'est la convention qu'attend le generateur, qui en prend le maximum avec la
# distance au terrain.
func sdf_in(indices: PackedInt32Array, x: int, y: int, z: int) -> float:
	if indices.is_empty():
		return -1000.0

	var px := float(x)
	var py := float(y)
	var pz := float(z)
	var best := -1000.0

	for i in indices:
		var o := i * 7
		var ax := _capsules[o]
		var ay := _capsules[o + 1]
		var az := _capsules[o + 2]
		var bx := _capsules[o + 3] - ax
		var by := _capsules[o + 4] - ay
		var bz := _capsules[o + 5] - az

		# Projection du point sur le segment, bornee a ses extremites.
		var length_sq := bx * bx + by * by + bz * bz
		var t := 0.0
		if length_sq > 0.0001:
			t = clampf(((px - ax) * bx + (py - ay) * by + (pz - az) * bz) / length_sq, 0.0, 1.0)
		var dx := px - (ax + bx * t)
		var dy := py - (ay + by * t)
		var dz := pz - (az + bz * t)

		var value := _capsules[o + 6] - sqrt(dx * dx + dy * dy + dz * dz)
		if value > best:
			best = value
	return best


func sdf(x: int, y: int, z: int) -> float:
	return sdf_in(column(x, z), x, y, z)


func capsule_count() -> int:
	@warning_ignore("integer_division")
	return _capsules.size() / 7


# Salles qu'aucune entree n'atteint.
#
# La connexite n'est pas acquise du seul fait qu'on a construit un arbre
# couvrant : encore faut-il que les galeries soient effectivement creusees
# entre les bonnes salles, et que les entrees rejoignent l'ensemble. Une salle
# isolee est du contenu que le joueur ne verra jamais — exactement le defaut du
# bruit qu'on remplace, en plus discret.
#
# Le parcours se fait par EXTREMITES PARTAGEES, ce qui est exact ici : chaque
# galerie est une chaine de capsules dont chaque maillon reprend le point de la
# precedente, et elle demarre au centre meme d'une salle.
func unreachable_rooms() -> int:
	if rooms.is_empty():
		return 0

	# Extremite -> capsules qui la touchent.
	var at_point := {}
	for i in capsule_count():
		var o := i * 7
		for key in [_key(o), _key(o + 3)]:
			var list: PackedInt32Array = at_point.get(key, PackedInt32Array())
			list.append(i)
			at_point[key] = list

	# Depart : toutes les capsules issues d'une entree. Les entrees sont
	# creusees EN DERNIER, donc ce sont les capsules de queue.
	var seen := {}
	var queue := PackedInt32Array()
	for i in range(_first_entrance_capsule, capsule_count()):
		seen[i] = true
		queue.append(i)

	var head := 0
	while head < queue.size():
		var i := queue[head]
		head += 1
		var o := i * 7
		for key in [_key(o), _key(o + 3)]:
			for j in at_point.get(key, PackedInt32Array()) as PackedInt32Array:
				if not seen.has(j):
					seen[j] = true
					queue.append(j)

	# Les salles occupent les premieres capsules, une chacune.
	var lost := 0
	for i in rooms.size():
		if not seen.has(i):
			lost += 1
	return lost


func _key(offset: int) -> Vector3i:
	return Vector3i(
		roundi(_capsules[offset] * 4.0),
		roundi(_capsules[offset + 1] * 4.0),
		roundi(_capsules[offset + 2] * 4.0))


# --- Construction -----------------------------------------------------------

# Salles dispersees sous les terres emergees, plus grandes en profondeur.
func _place_rooms(map, rng: RandomNumberGenerator) -> void:
	var target := clampi(
		int(float(map.size_xz) * ROOMS_PER_SIDE), ROOM_MIN, ROOM_MAX)

	var attempts := 0
	while rooms.size() < target and attempts < target * 200:
		attempts += 1
		var x := rng.randi_range(0, map.size_xz - 1)
		var z := rng.randi_range(0, map.size_xz - 1)
		var ground: int = map.terrain_height(x, z)
		# Sous la MER on ne creuse pas : le plafond de roche y serait le fond
		# marin, et une salle qui le perce inonde tout le reseau.
		if ground <= _sea_level + ROOF:
			continue

		var ceiling: int = ground - ROOF
		var floor_y := _bedrock + FLOOR_MARGIN
		if ceiling - floor_y < ROOM_RADIUS_MIN * 2.0:
			continue

		var y := rng.randi_range(floor_y, ceiling)
		var position := Vector3(float(x), float(y), float(z))

		var spaced := true
		for room in rooms:
			if Vector3(room.x, room.y, room.z).distance_to(position) < ROOM_SPACING:
				spaced = false
				break
		if not spaced:
			continue

		# Plus on descend, plus la salle est vaste : une fourmiliere a ses
		# grandes chambres au fond.
		var depth_t := inverse_lerp(float(ceiling), float(floor_y), float(y))
		var radius := lerpf(ROOM_RADIUS_MIN, ROOM_RADIUS_MAX, clampf(depth_t, 0.0, 1.0))
		radius *= rng.randf_range(0.85, 1.15)
		# La salle ne doit pas percer son propre plafond.
		radius = minf(radius, float(ground - ROOF - y) + ROOM_RADIUS_MIN)
		radius = maxf(radius, ROOM_RADIUS_MIN)

		rooms.append(Vector4(position.x, position.y, position.z, radius))
		_add_capsule(position, position, radius)


# Arbre couvrant minimal, puis quelques boucles.
#
# L'arbre seul suffirait a garantir que tout communique, mais il ne produit que
# des culs-de-sac : depuis n'importe quelle salle il n'existe qu'un seul chemin
# vers n'importe quelle autre. Les aretes supplementaires font les boucles, et
# c'est ce qui rend un reseau explorable plutot que lineaire.
func _connect_rooms(rng: RandomNumberGenerator) -> Array[Vector2i]:
	var edges: Array[Vector2i] = []
	var joined := PackedInt32Array([0])

	while joined.size() < rooms.size():
		var best := Vector2i(-1, -1)
		var best_distance := INF
		for a in joined:
			for b in rooms.size():
				if joined.has(b):
					continue
				var distance := _room_center(a).distance_to(_room_center(b))
				if distance < best_distance:
					best_distance = distance
					best = Vector2i(a, b)
		if best.x < 0:
			break
		edges.append(best)
		joined.append(best.y)

	# Un quart de liaisons en plus, vers un voisin proche mais pas le plus
	# proche — celui-la est deja relie par l'arbre dans la plupart des cas.
	for _n in maxi(rooms.size() / 4, 1):
		var a := rng.randi_range(0, rooms.size() - 1)
		var b := _second_nearest(a)
		if b >= 0 and not _has_edge(edges, a, b):
			edges.append(Vector2i(a, b))
	return edges


# Une galerie : une suite de capsules qui serpente entre deux points.
#
# Chaque point intermediaire est decale par un bruit, puis RABATTU sous le
# plafond de roche. Sans ce rabattement une galerie qui passe sous une crete
# ressort a flanc de colline, et ouvre un trou beant la ou on n'en voulait pas.
func _carve_tunnel(map, wander: FastNoiseLite,
		from: Vector3, to: Vector3, radius: float) -> void:
	var steps := maxi(2, int(from.distance_to(to) / SEGMENT_LENGTH))
	var previous := from

	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var point := from.lerp(to, t)

		# Seuls les points INTERMEDIAIRES sont deplaces puis rabattus. Le
		# dernier est donne : centre d'une salle, ou bouche d'entree, tous deux
		# deja valides par construction.
		#
		# Le rabattre etait un bug couteux. Il deplacait l'extremite de quelques
		# voxels, si bien que la galerie ne partait plus exactement du centre de
		# la salle visee — six salles sur dix se retrouvaient hors du reseau, et
		# rien ne le montrait puisque les galeries, elles, restaient bien
		# visibles.
		if i < steps:
			point += Vector3(
				wander.get_noise_3dv(point) * WANDER_XZ,
				wander.get_noise_3dv(point + Vector3(100.0, 0.0, 0.0)) * WANDER_Y,
				wander.get_noise_3dv(point + Vector3(0.0, 0.0, 100.0)) * WANDER_XZ)
			point = _clamp_underground(map, point, radius)

		_add_capsule(previous, point, radius)
		previous = point


# Une colonne de riviere se trouve-t-elle a portee ?
#
# `map` est volontairement non typee, comme partout dans ce fichier : le nommer
# `WorldMap` formerait un cycle de classes, puisque c'est lui qui nous utilise.
func _river_within(map, x: int, z: int, reach: int) -> bool:
	for dz in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			if map.is_river(x + dx, z + dz):
				return true
	return false


# Ramene un point sous le plafond de roche et au-dessus de la bedrock.
func _clamp_underground(map, point: Vector3, radius: float) -> Vector3:
	var x := clampi(int(round(point.x)), 0, map.size_xz - 1)
	var z := clampi(int(round(point.z)), 0, map.size_xz - 1)
	var ground: int = map.terrain_height(x, z)

	var lowest := float(_bedrock + FLOOR_MARGIN) + radius
	var highest := float(ground) - float(ROOF) - radius
	if highest < lowest:
		highest = lowest

	point.x = clampf(point.x, 0.0, float(map.size_xz - 1))
	point.z = clampf(point.z, 0.0, float(map.size_xz - 1))
	point.y = clampf(point.y, lowest, highest)
	return point


# Entrees : un point de surface haut et pentu, relie a la salle la plus proche.
#
# On prefere les versants raides — le pied d'une falaise — parce qu'une entree
# sur un terrain plat ressemble a un trou dans le sol, pas a une bouche de
# grotte.
func _open_entrances(map, rng: RandomNumberGenerator,
		wander: FastNoiseLite) -> void:
	var count := maxi(ENTRANCE_COUNT_MIN, int(float(rooms.size()) * ENTRANCE_PER_ROOMS))

	for _n in count:
		var best := Vector3i(-1, -1, -1)
		var best_slope := -1.0
		# Une poignee de candidats, on garde le plus pentu.
		for _try in 40:
			var x := rng.randi_range(2, map.size_xz - 3)
			var z := rng.randi_range(2, map.size_xz - 3)
			var ground: int = map.terrain_height(x, z)
			if ground <= _sea_level + ENTRANCE_MIN_ALTITUDE:
				continue
			# Jamais dans un lit de riviere NI A SON BORD.
			#
			# Le reseau est construit APRES le creusement des chenaux, donc
			# rien n'empeche autrement une entree de s'ouvrir dans l'un d'eux —
			# et la riviere porte maintenant de l'eau, qui noierait la galerie.
			#
			# Tester la seule colonne de la bouche ne suffisait pas : une entree
			# s'evase sur ENTRANCE_RADIUS, et le plan d'eau deborde jusqu'au
			# haut des berges. Une bouche posee A COTE d'un chenal ouvrait donc
			# quand meme sous l'eau — mesure sur la carte de 800, une galerie
			# remontant 4,1 m AU-DESSUS du niveau de la riviere voisine.
			if _river_within(map, x, z, RIVER_CLEARANCE):
				continue
			var slope := maxf(
				absf(float(map.terrain_height(x + 2, z) - map.terrain_height(x - 2, z))),
				absf(float(map.terrain_height(x, z + 2) - map.terrain_height(x, z - 2))))
			if slope > best_slope:
				best_slope = slope
				best = Vector3i(x, ground, z)

		if best.x < 0:
			continue
		var mouth := Vector3(float(best.x), float(best.y), float(best.z))
		var room := _nearest_room(mouth)
		if room < 0:
			continue
		entrances.append(best)
		# Creusee DEPUIS la salle VERS la bouche : le dernier point est celui
		# qu'on autorise a percer, et `_carve_tunnel` ne dispense que celui-la.
		_carve_tunnel(map, wander, _room_center(room), mouth, ENTRANCE_RADIUS)


# --- Utilitaires ------------------------------------------------------------

func _add_capsule(a: Vector3, b: Vector3, radius: float) -> void:
	var index := capsule_count()
	var low := floori(minf(a.y, b.y) - radius)
	var high := ceili(maxf(a.y, b.y) + radius)
	if _highest < _lowest:
		_lowest = low
		_highest = high
	else:
		_lowest = mini(_lowest, low)
		_highest = maxi(_highest, high)

	_capsules.append_array(PackedFloat32Array([a.x, a.y, a.z, b.x, b.y, b.z, radius]))

	# Inscription dans toutes les cases que la boite englobante touche.
	var min_x := minf(a.x, b.x) - radius
	var max_x := maxf(a.x, b.x) + radius
	var min_z := minf(a.z, b.z) - radius
	var max_z := maxf(a.z, b.z) + radius

	for bz in range(floori(min_z / BUCKET), floori(max_z / BUCKET) + 1):
		for bx in range(floori(min_x / BUCKET), floori(max_x / BUCKET) + 1):
			var key := Vector2i(bx, bz)
			var list: PackedInt32Array = _buckets.get(key, PackedInt32Array())
			list.append(index)
			# Reaffectation obligatoire : les Packed*Array sont des types
			# VALEUR, donc `list` est une copie tant qu'on ne la remet pas.
			_buckets[key] = list


func _room_center(index: int) -> Vector3:
	var room := rooms[index]
	return Vector3(room.x, room.y, room.z)


func _nearest_room(point: Vector3, exclude := -1) -> int:
	var best := -1
	var best_distance := INF
	for i in rooms.size():
		if i == exclude:
			continue
		var distance := _room_center(i).distance_to(point)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


func _second_nearest(index: int) -> int:
	var first := _nearest_room(_room_center(index), index)
	if first < 0:
		return -1
	var best := -1
	var best_distance := INF
	for i in rooms.size():
		if i == index or i == first:
			continue
		var distance := _room_center(i).distance_to(_room_center(index))
		if distance < best_distance:
			best_distance = distance
			best = i
	return best if best >= 0 else first


func _has_edge(edges: Array[Vector2i], a: int, b: int) -> bool:
	for edge in edges:
		if (edge.x == a and edge.y == b) or (edge.x == b and edge.y == a):
			return true
	return false
