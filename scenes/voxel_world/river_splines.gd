class_name RiverSplines
extends Node3D

# Emprise des rivieres : le bord du creusement en splines fermees, et la
# surface qu'elles delimitent.
#
# C'EST DE LA QUE SORT LE PLAN D'EAU.
#
# Une nappe d'eau calculee separement a existe ici, avec son propre champ de
# niveau et son propre bord. Elle a ete retiree parce que ce bord etait une
# approximation de celui-ci : elle deduisait son contour d'un niveau d'eau
# confronte au terrain, la ou ces splines SONT la frontiere exacte du
# creusement — celle du bord de la reunion des disques tamponnes par
# `RiverNetwork`. Le plan d'eau se tenant a la crete des berges, et ces splines
# etant precisement posees sur cette crete, la surface qu'elles delimitent est
# deja le plan d'eau : il n'y a plus d'altitude a calculer.
#
# Chaque boucle est un vrai `Path3D` et non seulement un trait. Ce n'est pas de
# la ceremonie : une `Curve3D` sait rendre un point et une tangente a une
# distance donnee, ce dont aura besoin tout ce qui voudra SUIVRE une rive.
#


# --- Contour du creusement -------------------------------------------------
#
# LE CONTOUR N'APPARTIENT A AUCUNE RIVIERE EN PARTICULIER.
#
# Il a d'abord ete construit par riviere : deux lignes de berge sondees de part
# et d'autre de l'axe, refermees en boucle. Ca ne pouvait pas marcher a une
# confluence, et pour une raison de fond plutot que de reglage — deux boucles
# distinctes ne se rejoignent pas, elles se croisent. Le tributaire refermait la
# sienne en travers du tronc, et le tronc traversait celle du tributaire.
#
# Ce qu'on veut n'est pas la reunion de deux contours mais LE CONTOUR DE LA
# REUNION. On construit donc un champ — la profondeur dans le creusement,
# `portee - distance a l'axe`, prise au maximum sur tous les points de tous les
# traces — et on en suit le niveau zero. Deux rivieres qui se rejoignent ne
# forment alors qu'une seule region, donc un seul bord, et le probleme ne se
# pose plus.
#
# Le champ est aussi PLUS JUSTE que le sondage qu'il remplace. Le creusement
# tamponne un disque par point de trace : sa frontiere est le bord de la reunion
# de ces disques, ce que le maximum capture exactement. Sonder la crete
# perpendiculairement a l'axe, lui, retombait dans le chenal des que deux
# disques se recouvraient — dans un coude, ou justement a une confluence.
#
# Le nombre de splines n'est donc plus celui des rivieres mais celui des
# COMPOSANTES du reseau creuse : une par morceau d'ile, une de plus par ilot
# cerne de branches.

# Marge de tampon au-dela du creusement. Le champ doit etre NEGATIF quelque part
# autour, sinon son niveau zero n'a nulle part ou passer.
const FIELD_MARGIN := 2.0

# Elevation du remplissage au-dessus du sol. Quelques centimetres suffisent a
# lui eviter de se disputer le tampon de profondeur avec le terrain qu'il
# recouvre exactement.
const FILL_HOVER := 0.06

# Demi-largeur de la bande qui sert de bord impose a la membrane, en metres.
# Elle straddle le contour : ces colonnes SONT la crete des berges.
const BOUNDARY_BAND := 0.5

# Passes de relaxation de la membrane. Le chenal ne fait que quelques colonnes
# de large, donc l'information traverse vite ; soixante-quatre passes laissent
# de la marge aux confluences, ou la region s'elargit.
const LEVEL_RELAX_PASSES := 64


# Le champ de niveau SURVIT a la construction du maillage, et c'est delibere.
#
# Un maillage ne repond a aucune question : savoir si un oeil est sous l'eau
# demande une altitude a une colonne donnee, pas des triangles. La mer s'en
# passe puisqu'elle tient a une seule altitude ; une riviere descend de
# quarante metres, donc il faut pouvoir l'interroger.
#
# Un flottant par colonne, soit 2,5 Mo sur une carte de 800. C'est le prix a
# payer pour que l'immersion, la nage, la soif et la peche puissent un jour
# demander « quelle est l'altitude de l'eau ici ».
var _level := PackedFloat32Array()
# Colonnes REELLEMENT sous l'eau, c'est-a-dire a l'interieur du contour.
#
# Un masque a part parce que `_level` porte une altitude sur toutes les
# colonnes tamponnees, y compris celles du dehors : le decoupage du maillage
# interpole entre un coin dedans et un coin dehors, et ce dernier doit porter
# une altitude sensee. Sans ce masque, interroger une colonne de berge
# repondrait « il y a de l'eau, a la hauteur du sol ».
var _wet := PackedByteArray()
var _size := 0


# Altitude du plan d'eau a cette colonne, ou -INF s'il n'y a pas d'eau.
func water_level_at(x: int, z: int) -> float:
	if _size == 0 or x < 0 or z < 0 or x >= _size or z >= _size:
		return -INF
	var i := z * _size + x
	return _level[i] if _wet[i] != 0 else -INF


func setup(map: WorldMap) -> void:
	# Le champ du creusement sert DEUX FOIS : son niveau zero donne le contour,
	# son interieur donne la surface a remplir. Le calculer une seule fois n'est
	# pas qu'une economie — c'est ce qui garantit que le bord de l'eau tombe
	# exactement sur la rive tracee plutot qu'a cote.
	_size = map.size_xz
	var size := _size
	var field := PackedFloat32Array()
	field.resize(size * size)
	field.fill(-INF)
	var cells := PackedInt32Array()
	_build_field(map, field, cells, size)

	var loops := _outlines(map, field, cells, size)
	for index in loops.size():
		_add_spline("Berges%d" % index, loops[index])

	_level = _build_level(map, field, size)
	_wet = PackedByteArray()
	_wet.resize(size * size)
	for i in field.size():
		if field[i] >= 0.0:
			_wet[i] = 1
	_add_fill(map, field, _level, cells, size)


# Altitude de la surface : une membrane TENDUE SUR LE CONTOUR.
#
# La surface epousait le terrain, donc elle plongeait au fond du lit. Ce n'est
# pas ce qu'on veut d'un plan d'eau : l'eau se tient a une altitude, elle ne
# suit pas les creux.
#
# Le contour est pose sur la crete des berges, et le plan d'eau affleure cette
# crete. La surface cherchee est donc exactement celle qui s'appuie sur le
# contour et qui, entre deux rives, ne fait rien d'autre que les relier — la
# membrane minimale, c'est-a-dire la solution de Laplace a bord impose.
#
# On la calcule par relaxation : les colonnes de la BANDE qui straddle le
# contour sont fixees a l'altitude du terrain (elles SONT la crete), et les
# colonnes interieures prennent la moyenne de leurs voisines jusqu'a
# convergence. Le chenal ne faisant que quelques colonnes de large,
# l'information traverse vite et une soixantaine de passes suffisent.
func _build_level(map: WorldMap, field: PackedFloat32Array,
		size: int) -> PackedFloat32Array:
	var level := PackedFloat32Array()
	level.resize(size * size)
	# 0 hors de la surface, 1 sur la bande du bord, 2 a l'interieur.
	var member := PackedByteArray()
	member.resize(size * size)
	var interior := PackedInt32Array()

	for i in field.size():
		var depth := field[i]
		if depth == -INF:
			continue
		var x := i % size
		@warning_ignore("integer_division")
		var z: int = i / size
		# L'altitude est renseignee pour TOUTE colonne tamponnee, y compris
		# celles qui ne participent pas a la relaxation : une cellule a cheval
		# sur le contour interpole entre un coin dedans et un coin dehors, et ce
		# dernier doit porter une altitude sensee.
		level[i] = map.terrain_height_f(x, z)
		if depth > BOUNDARY_BAND:
			member[i] = 2
			interior.append(i)
		elif depth >= -BOUNDARY_BAND:
			# La bande du bord est la crete elle-meme : c'est le bord impose.
			member[i] = 1

	var offsets := [-size, size, -1, 1]
	for _pass in LEVEL_RELAX_PASSES:
		var next := level.duplicate()
		for i in interior:
			var sum := 0.0
			var taken := 0
			for d in offsets:
				var j: int = i + d
				# Seules les colonnes de la surface comptent : au-dela du bord,
				# le terrain remonte le long du versant et tirerait la membrane
				# avec lui.
				if j < 0 or j >= level.size() or member[j] == 0:
					continue
				sum += level[j]
				taken += 1
			if taken > 0:
				next[i] = sum / float(taken)
		level = next
	return level


# --- Contour du creusement -------------------------------------------------

# Profondeur dans le creusement, colonne par colonne, pour tout le reseau.
func _build_field(map: WorldMap, field: PackedFloat32Array,
		cells: PackedInt32Array, size: int) -> void:
	var marked := PackedByteArray()
	marked.resize(size * size)
	for index in map.rivers.path_count():
		var path := map.rivers.path(index)
		@warning_ignore("integer_division")
		for k in path.size() / 4:
			_stamp_depth(field, marked, cells, size, path[k * 4], path[k * 4 + 1],
				path[k * 4 + 3] + RiverNetwork.BANK)


# Toutes les boucles de bord du reseau creuse, dans l'ordre ou on les trouve.
func _outlines(map: WorldMap, field: PackedFloat32Array, cells: PackedInt32Array,
		size: int) -> Array[PackedVector3Array]:
	var out: Array[PackedVector3Array] = []
	for loop in _trace_contours(field, cells, size):
		if loop.size() < 4:
			continue
		var points := PackedVector3Array()
		for flat in loop:
			points.append(Vector3(flat.x, _floor_at(map, flat.x, flat.y), flat.y))
		out.append(points)
	return out


# Profondeur dans le creusement autour d'un point de trace, gardee au MAXIMUM :
# une colonne appartient au creusement des qu'UN point l'atteint.
func _stamp_depth(field: PackedFloat32Array, marked: PackedByteArray,
		cells: PackedInt32Array, size: int, px: float, pz: float,
		reach: float) -> void:
	var radius := reach + FIELD_MARGIN
	var x0 := maxi(floori(px - radius), 0)
	var x1 := mini(ceili(px + radius), size - 1)
	var z0 := maxi(floori(pz - radius), 0)
	var z1 := mini(ceili(pz + radius), size - 1)

	for z in range(z0, z1 + 1):
		var dz := float(z) - pz
		for x in range(x0, x1 + 1):
			var dx := float(x) - px
			var distance := sqrt(dx * dx + dz * dz)
			if distance > radius:
				continue
			var i := z * size + x
			field[i] = maxf(field[i], reach - distance)
			# Les quatre cellules dont cette colonne est un coin.
			for cz in [z - 1, z]:
				if cz < 0 or cz >= size - 1:
					continue
				for cx in [x - 1, x]:
					if cx < 0 or cx >= size - 1:
						continue
					var c: int = cz * size + cx
					if marked[c] == 0:
						marked[c] = 1
						cells.append(c)


# Remplit la surface que les contours delimitent.
#
# Elle porte l'altitude du PLAN D'EAU, pas celle du sol : voir `_build_level`.
#
# Deux triangles par cellule, clippes contre `champ >= 0`. Le bord tombe donc
# exactement sur la rive tracee, qui suit le meme zero — et comme la membrane y
# vaut l'altitude du terrain, les deux se rejoignent aussi en altitude.
func _add_fill(map: WorldMap, field: PackedFloat32Array, level: PackedFloat32Array,
		cells: PackedInt32Array, size: int) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles := 0

	for c in cells:
		var cx := c % size
		@warning_ignore("integer_division")
		var cz: int = c / size
		var xs := [cx, cx + 1, cx + 1, cx]
		var zs := [cz, cz, cz + 1, cz + 1]
		var corners := []
		var any := false
		for n in 4:
			var i: int = zs[n] * size + xs[n]
			var depth := field[i]
			if depth >= 0.0:
				any = true
			corners.append([Vector2(float(xs[n]), float(zs[n])), depth, level[i]])
		if not any:
			continue
		triangles += _fill_triangle(surface, [corners[0], corners[1], corners[2]])
		triangles += _fill_triangle(surface, [corners[0], corners[2], corners[3]])

	if triangles == 0:
		return
	var instance := MeshInstance3D.new()
	instance.name = "Surface"
	instance.mesh = surface.commit()
	instance.material_override = _fill_material()
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


# Un sommet est (position XZ, profondeur dans le creusement, altitude du plan
# d'eau). L'altitude est interpolee avec les memes poids que la position : le
# bord du remplissage retombe ainsi sur l'altitude du terrain, puisque la
# membrane y est fixee a elle.
func _fill_triangle(surface: SurfaceTool, triangle: Array) -> int:
	var kept := []
	for i in triangle.size():
		var a: Array = triangle[i]
		var b: Array = triangle[(i + 1) % triangle.size()]
		var a_in: bool = a[1] >= 0.0
		var b_in: bool = b[1] >= 0.0
		if a_in:
			kept.append([a[0], a[2]])
		if a_in != b_in:
			var span: float = b[1] - a[1]
			var t := clampf(0.0 if absf(span) < 0.000001 else -a[1] / span, 0.0, 1.0)
			kept.append([(a[0] as Vector2).lerp(b[0], t), lerpf(a[2], b[2], t)])

	if kept.size() < 3:
		return 0
	for i in range(1, kept.size() - 1):
		for vertex in [kept[0], kept[i], kept[i + 1]]:
			var point: Vector2 = vertex[0]
			surface.set_normal(Vector3.UP)
			# Tangente posee a la main, le long de X.
			#
			# Le shader d'eau fait defiler trois couches de normales, et une
			# normal map n'a de sens que dans un repere tangent. Un maillage bati
			# au `SurfaceTool` n'en porte aucun par defaut — la mer n'avait pas le
			# probleme, son `PlaneMesh` en fournit un. Comme la nappe est
			# horizontale et que le shader tire ses UV de `world_pos.xz`, le
			# repere du monde EST le bon repere tangent.
			surface.set_tangent(Plane(Vector3(1.0, 0.0, 0.0), 1.0))
			surface.add_vertex(Vector3(point.x, vertex[1] + FILL_HOVER, point.y))
	return kept.size() - 2


# La matiere de la mer, dont on ne rehausse que ce qui se mesure EN METRES
# D'EAU.
#
# Partir de celle de la mer garde une eau cohérente d'un bout du monde a
# l'autre : teintes, vaguelettes, rugosite, refraction. Mer et riviere se
# touchent a chaque embouchure, et deux materiaux qui divergeraient au fil des
# retouches s'y verraient en trait de coupe.
#
# Mais trois de ses reglages sont des PROFONDEURS, calibrees sur une mer de six
# a douze metres. Reprises telles quelles, elles donnaient une riviere
# integralement blanche : l'ecume apparait sous 1,8 m d'eau, ce qui borde une
# plage d'un lisere et noie un chenal qui n'en fait que deux. Il faut donc les
# ramener a l'echelle du corps d'eau, et ces trois-la seulement.
const RIVER_FOAM_DEPTH := 0.35
const RIVER_BEER_DEPTH := 2.5
const RIVER_DEPTH_FADE := 3.0


func _fill_material() -> ShaderMaterial:
	var material := Sea.build_material()
	material.set_shader_parameter("foam_depth", RIVER_FOAM_DEPTH)
	material.set_shader_parameter("beer_depth", RIVER_BEER_DEPTH)
	material.set_shader_parameter("depth_fade", RIVER_DEPTH_FADE)
	return material


# Suit le niveau zero du champ et rend des boucles fermees.
#
# Marching squares, mais en TRACANT et non en remplissant : le remplissage ne
# demande que des triangles, une spline demande des points ORDONNES. Chaque
# cellule traversee produit un ou deux segments dont les extremites tombent sur
# ses aretes ; comme une arete est partagee par exactement deux cellules, chaque
# extremite appartient a exactement deux segments, et les suivre de proche en
# proche referme forcement une boucle.
func _trace_contours(field: PackedFloat32Array, cells: PackedInt32Array,
		size: int) -> Array[PackedVector2Array]:
	# arete -> les deux extremites de segment qui s'y rattachent.
	var links := {}
	var positions := {}

	for c in cells:
		var cx := c % size
		@warning_ignore("integer_division")
		var cz: int = c / size
		var corners := [
			field[cz * size + cx], field[cz * size + cx + 1],
			field[(cz + 1) * size + cx + 1], field[(cz + 1) * size + cx]]
		var mask := 0
		for n in 4:
			if corners[n] > 0.0:
				mask |= 1 << n
		if mask == 0 or mask == 15:
			continue

		# Aretes de la cellule, dans l'ordre bas, droite, haut, gauche. Leur
		# identifiant est PARTAGE avec la cellule voisine, ce qui est tout
		# l'interet : le chainage se fait sur des entiers, jamais sur une
		# comparaison de flottants.
		var edges := [
			_edge_id(size, cx, cz, true), _edge_id(size, cx + 1, cz, false),
			_edge_id(size, cx, cz + 1, true), _edge_id(size, cx, cz, false)]
		var ends := [
			Vector2(_cross(corners[0], corners[1], cx), float(cz)),
			Vector2(float(cx + 1), _cross(corners[1], corners[2], cz)),
			Vector2(_cross(corners[3], corners[2], cx), float(cz + 1)),
			Vector2(float(cx), _cross(corners[0], corners[3], cz))]

		for pair in _SEGMENTS[mask]:
			var a: int = edges[pair[0]]
			var b: int = edges[pair[1]]
			positions[a] = ends[pair[0]]
			positions[b] = ends[pair[1]]
			_link(links, a, b)
			_link(links, b, a)

	var loops: Array[PackedVector2Array] = []
	var seen := {}
	for start in links:
		if seen.has(start):
			continue
		var loop := PackedVector2Array()
		var current: int = start
		var previous := -1
		while not seen.has(current):
			seen[current] = true
			loop.append(positions[current])
			var next := -1
			for candidate in links[current]:
				if candidate != previous:
					next = candidate
					break
			if next < 0 or not links.has(next):
				break
			previous = current
			current = next
		if loop.size() >= 4:
			# Le premier point repete referme la boucle.
			loop.append(loop[0])
			loops.append(loop)
	return loops


# Table des segments par configuration de coins. Les deux cas en selle — deux
# coins opposes dedans — sont tranches dans le meme sens partout, faute de quoi
# deux cellules voisines relieraient leurs aretes differemment et la boucle se
# briserait.
const _SEGMENTS := [
	[], [[3, 0]], [[0, 1]], [[3, 1]],
	[[1, 2]], [[3, 2], [0, 1]], [[0, 2]], [[3, 2]],
	[[2, 3]], [[2, 0]], [[2, 1], [0, 3]], [[2, 1]],
	[[1, 3]], [[1, 0]], [[0, 3]], [],
]


func _edge_id(size: int, x: int, z: int, horizontal: bool) -> int:
	return (z * size + x) * 2 + (0 if horizontal else 1)


# Position du passage par zero sur une arete, entre deux coins voisins.
func _cross(a: float, b: float, origin: int) -> float:
	var span := b - a
	if absf(span) < 0.000001:
		return float(origin) + 0.5
	return float(origin) + clampf(-a / span, 0.0, 1.0)


func _link(links: Dictionary, from_edge: int, to_edge: int) -> void:
	if not links.has(from_edge):
		links[from_edge] = []
	links[from_edge].append(to_edge)


# Le contour est CALCULE ET CONSERVE, mais plus dessine.
#
# Son trait magenta a servi a mettre au point l'emprise et n'a plus lieu
# d'etre : la nappe d'eau qui s'appuie dessus dit desormais la meme chose, en
# mieux. La geometrie reste parce qu'elle n'est pas du decor — c'est la rive
# exacte de chaque riviere, en `Curve3D` interrogeable par point et par
# tangente, et c'est ce dont aura besoin tout ce qui voudra la longer.
#
# Pour la revoir a l'oeil, il suffit d'accrocher un `MeshInstance3D` a ces
# `Path3D` : la courbe, elle, est deja la.
func _add_spline(spline_name: String, points: PackedVector3Array) -> void:
	if points.size() < 2:
		return
	var path := Path3D.new()
	path.name = spline_name
	path.curve = _curve(points)
	add_child(path)



func _floor_at(map: WorldMap, x: float, z: float) -> float:
	var x0 := floori(x)
	var z0 := floori(z)
	var tx := x - float(x0)
	var tz := z - float(z0)
	return lerpf(
		lerpf(map.terrain_height_f(x0, z0), map.terrain_height_f(x0 + 1, z0), tx),
		lerpf(map.terrain_height_f(x0, z0 + 1), map.terrain_height_f(x0 + 1, z0 + 1), tx),
		tz)


# Courbe lisse passant par tous les points, facon Catmull-Rom, mais MONOTONE EN
# ALTITUDE.
#
# Sans poignees, une `Curve3D` relie ses points par des segments et n'est pas
# une spline. La tangente en un point est prise sur ses deux voisins et les
# poignees valent le tiers de la demi-tangente : c'est la conversion classique
# de Catmull-Rom vers Bezier, celle qui fait passer la courbe exactement par
# les points tout en restant continue en tangente.
#
# Telle quelle, elle DEPASSE. Une tangente calculee sur les voisins ignore
# l'intervalle qu'elle traverse : la ou le fond descend puis s'aplatit, la
# courbe garde son elan et plonge sous le sol entre deux points de controle. On
# ne le voyait pas venir parce qu'un depassement de spline est invisible a la
# lecture — il faut soit le calculer, soit le regarder en jeu.
#
# On borne donc chaque poignee EN Y a l'intervalle des deux points qu'elle
# relie. Le polygone de controle de chaque segment reste alors dans cet
# intervalle, et une courbe de Bezier ne sort jamais de l'enveloppe convexe de
# son polygone : l'altitude de la courbe est ainsi comprise entre celles de ses
# deux points, par construction et non par reglage. En XZ les poignees restent
# libres, donc le trace garde sa douceur.
func _curve(points: PackedVector3Array) -> Curve3D:
	var curve := Curve3D.new()
	for i in points.size():
		var previous := points[maxi(i - 1, 0)]
		var next := points[mini(i + 1, points.size() - 1)]
		var handle := (next - previous) / 6.0
		var out_handle := handle
		var in_handle := -handle
		out_handle.y = _clamp_to_span(handle.y, points[i].y, next.y)
		in_handle.y = _clamp_to_span(-handle.y, points[i].y, previous.y)
		curve.add_point(points[i], in_handle, out_handle)
	return curve


# Borne un decalage vertical de poignee pour que `origine + decalage` reste
# entre `origine` et `voisin`.
func _clamp_to_span(offset: float, origin: float, neighbour: float) -> float:
	return clampf(origin + offset, minf(origin, neighbour), maxf(origin, neighbour)) - origin
