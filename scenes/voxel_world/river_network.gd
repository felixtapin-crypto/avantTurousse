class_name RiverNetwork
extends RefCounted

# Reseau de rivieres : des chenaux reellement CREUSES dans la carte de
# hauteurs, la ou l'hydrologie dit que l'eau passe.
#
# Ce qu'il remplace : jusqu'ici une riviere n'etait qu'une ETIQUETTE. Une
# colonne dont le debit depassait un quantile etait classee `Biome.RIVER`,
# baissee d'UN voxel, et peinte en gravier. Trois raisons pour lesquelles on
# ne voyait rien en jeu :
#
# - le lit faisait une colonne de large, parce que c'est la trace D8 du
#   ruissellement et pas un chenal ;
# - un voxel de creusement se noie dans le lissage du terrain ;
# - le ruban de gravier etait dilue par le noyau de fondu de dix metres du
#   generateur, qui le ramenait sous la moitie du melange.
#
# CE RESEAU EST TAMPONNE, PAS EVALUE — L'INVERSE DES GROTTES.
#
# `cave_network.gd` est evalue voxel par voxel parce qu'une grotte est un
# volume 3D, rare, et souterrain : la filtrer par cases coute moins cher que
# de la stocker. Une riviere est exactement le contraire — une feature de
# SURFACE, sur des colonnes que le generateur parcourt de toute facon. On
# l'ecrit donc une fois dans la carte de hauteurs, a la generation.
#
# Le generateur de voxels n'a alors rien a changer : la distance signee suit
# deja `terrain_height_f()`, donc le lit apparait gratuitement, il part au
# cache avec la carte, et il fonctionne a tous les niveaux de detail. Une SDF
# de riviere couterait au contraire une evaluation par voxel sur toute la
# bande de surface, c'est-a-dire precisement ce que le filtrage en deux temps
# des grottes sert a eviter.
#
# Contrepartie assumee : pas de berge en surplomb. Un chenal n'en a pas.

# --- Geometrie du chenal ---------------------------------------------------

# Largeur TOTALE du lit, en metres, de la tete de bassin au collecteur. Un peu
# moins qu'une galerie (`CaveNetwork.TUNNEL_RADIUS` = 2,6, soit 5,2 m de large).
const WIDTH_MIN := 1.0
const WIDTH_MAX := 4.0

# Profondeur sous les berges. Proportionnelle a la largeur : un ruisseau de
# tete reste enjambable la ou le fleuve ne l'est pas.
const DEPTH_MIN := 0.8
const DEPTH_MAX := 2.5

# Largeur de la berge, au-dela du lit : la distance sur laquelle le terrain
# remonte a son altitude d'origine.
const BANK := 1.6

# PLAFOND DE CREUSEMENT, et c'est lui qui fabrique les cascades.
#
# Le profil en long est d'abord force non-croissant, pour qu'aucune marche ne
# remonte a l'interieur du lit. Sur un versant raide, cette seule regle
# taillerait une gorge sans fond : le fond herite de l'altitude atteinte en
# haut de la pente et la traine sur tout le reste du parcours.
#
# Le plafond dit que le lit ne descend jamais a plus de trois metres sous le
# terrain. La ou la montagne tombe plus vite que ca, il relache le fond, qui
# decroche avec elle — une cascade. Et la ou le versant debouche sur un
# replat, il remonte le lit au lieu de le laisser filer en tranchee : la
# remontee fait une cuvette, ce qui est exactement la forme d'une vasque de
# pied de chute.
const MAX_CARVE := 3.0

# Pas de percement au maximum par chemin, quand l'ecoulement tombe dans une
# cuvette. Voir `_trace_from`.
const BREACH_MAX := 64

# Garde-fou de boucle : un chemin plus long que ca revient forcement d'une
# erreur de recepteur, et on prefere un lit tronque a un gel.
const PATH_MAX_STEPS := 8192

# --- Etat ------------------------------------------------------------------

# Points des chenaux, quatre flottants chacun : x, z, altitude du fond,
# demi-largeur. C'est le seul etat qui survit a la generation — il part au
# cache, parce que les hauteurs mises en cache sont DEJA creusees et que
# retracer dessus suivrait le chenal au lieu de le reproduire.
var _points := PackedFloat32Array()
# Indice du premier point de chaque chemin, dans `_points` comptes en POINTS.
var _path_starts := PackedInt32Array()

var _size := 0
# Masque du chenal, une colonne par octet. Vivant de `build()` a `_classify()`.
#
# Il couvre TOUT LE CREUSEMENT, berges comprises, et pas seulement le fond
# plat. Ce n'est pas un arrondi : un lit de deux metres ne peut pas dominer la
# matiere d'un sommet qu'il partage avec ses deux berges, parce que le mailleur
# prend la matiere d'un sommet sur les voxels pleins de sa cellule. Mesure a
# l'appui — avec le masque restreint au fond, 21,6 % seulement des sommets de
# lit sortaient en gravier, le reste heritant de l'herbe des berges.
#
# La berge d'une riviere est de toute facon graveleuse. Peindre le talus comme
# le fond n'est donc pas une concession au mailleur, c'est la bonne reponse
# qu'il se trouve qu'il exige.
var _bed := PackedByteArray()
# Altitude visee par le creusement, INF hors du reseau. Libere par `carve()` :
# c'est un flottant par colonne, soit 2,5 Mo sur une carte de 800.
var _target := PackedFloat32Array()


# Trace le reseau sur le relief FINAL, sans y toucher encore.
#
# `receivers` vient de `WorldMap._accumulate_flow()`, qui l'a deja calcule pour
# propager les debits : le recalculer ici serait cinq millions d'operations
# pour retrouver le meme tableau, et surtout deux copies d'une meme regle a
# garder d'accord.
func build(height_f: PackedFloat32Array, flow: PackedFloat32Array,
		receivers: PackedInt32Array, size_xz: int, sea_level: int,
		threshold: float) -> void:
	_size = size_xz
	_points = PackedFloat32Array()
	_path_starts = PackedInt32Array()

	var n := size_xz * size_xz
	_bed = PackedByteArray()
	_bed.resize(n)
	_target = PackedFloat32Array()
	_target.resize(n)
	_target.fill(INF)

	if threshold == INF:
		return

	# Bornes de normalisation du debit : le seuil en bas, le plus gros
	# collecteur en haut. En logarithme, comme partout ou ce projet manipule un
	# debit — la distribution est trop etalee pour une echelle lineaire.
	var log_min := log(1.0 + threshold)
	var log_max := log_min
	for i in n:
		if flow[i] < threshold or height_f[i] <= float(sea_level):
			continue
		var l := log(1.0 + flow[i])
		if l > log_max:
			log_max = l
	var log_span := maxf(log_max - log_min, 0.001)

	var visited := PackedByteArray()
	visited.resize(n)

	for i in _sources(height_f, flow, receivers, size_xz, sea_level, threshold):
		_trace_from(i, height_f, flow, receivers, visited, size_xz, sea_level,
			log_min, log_span)

	_rasterise(height_f, size_xz)


# Applique le creusement a la carte de hauteurs et libere le champ de travail.
#
# Le tableau est RENDU et non modifie sur place : les Packed*Array sont des
# types VALEUR en GDScript, une ecriture faite ici serait perdue au retour.
func carve(height_f: PackedFloat32Array) -> PackedFloat32Array:
	for i in mini(height_f.size(), _target.size()):
		if _target[i] < height_f[i]:
			height_f[i] = _target[i]
	_target = PackedFloat32Array()
	return height_f


func is_bed(x: int, z: int) -> bool:
	if x < 0 or z < 0 or x >= _size or z >= _size:
		return false
	return _bed[z * _size + x] != 0


func point_count() -> int:
	@warning_ignore("integer_division")
	return _points.size() / 4


func path_count() -> int:
	return _path_starts.size()


# Points d'un chemin, dans l'ordre amont -> aval, en (x, z, fond, demi-largeur).
func path(index: int) -> PackedFloat32Array:
	if index < 0 or index >= _path_starts.size():
		return PackedFloat32Array()
	var from := _path_starts[index] * 4
	var to := _points.size()
	if index + 1 < _path_starts.size():
		to = _path_starts[index + 1] * 4
	return _points.slice(from, to)


# --- Cache -----------------------------------------------------------------

func capture() -> Dictionary:
	return {"points": _points, "starts": _path_starts}


func restore(data: Dictionary, size_xz: int) -> void:
	_size = size_xz
	_points = data.get("points", PackedFloat32Array())
	_path_starts = data.get("starts", PackedInt32Array())
	# Le masque et le champ de creusement ne sont pas restaures : le premier
	# est deja dans les biomes en cache, le second dans les hauteurs.
	_bed = PackedByteArray()
	_target = PackedFloat32Array()


# --- Trace -----------------------------------------------------------------

# Decalages des 8 voisins, dans le meme ordre que `WorldMap._accumulate_flow()`.
func _neighbour_offsets(size_xz: int) -> PackedInt32Array:
	return PackedInt32Array([
		-size_xz, size_xz, -1, 1,
		-size_xz - 1, -size_xz + 1, size_xz - 1, size_xz + 1])


# Tetes de bassin : une colonne au-dessus du seuil dont aucun voisin amont ne
# depasse le seuil. C'est la que commence un chenal.
func _sources(height_f: PackedFloat32Array, flow: PackedFloat32Array,
		receivers: PackedInt32Array, size_xz: int, sea_level: int,
		threshold: float) -> PackedInt32Array:
	var offsets := _neighbour_offsets(size_xz)
	var out := PackedInt32Array()
	for z in range(1, size_xz - 1):
		for x in range(1, size_xz - 1):
			var i := z * size_xz + x
			if flow[i] < threshold or height_f[i] <= float(sea_level):
				continue
			var head := true
			for d in 8:
				var j: int = i + offsets[d]
				if flow[j] >= threshold and receivers[j] == i:
					head = false
					break
			if head:
				out.append(i)
	return out


# Descend le reseau depuis une tete de bassin et ecrit un chemin.
func _trace_from(start: int, height_f: PackedFloat32Array,
		flow: PackedFloat32Array, receivers: PackedInt32Array,
		visited: PackedByteArray, size_xz: int, sea_level: int,
		log_min: float, log_span: float) -> void:
	if visited[start] != 0:
		return

	var offsets := _neighbour_offsets(size_xz)
	var first := point_count()
	var previous_bed := INF
	var previous_t := 0.0
	var breaches := 0
	var i := start

	for _step in PATH_MAX_STEPS:
		visited[i] = 1

		var t := clampf((log(1.0 + flow[i]) - log_min) / log_span, 0.0, 1.0)
		# UNE RIVIERE NE RETRECIT PAS VERS L'AVAL.
		#
		# Le debit, lui, le peut : un troncon PERCE (voir plus bas) traverse
		# des colonnes qui ne font pas partie du reseau d'ecoulement, ou le
		# debit vaut 1. Sans cette borne, un collecteur de quatre metres se
		# pincait a un metre sur une dizaine de metres avant de se rouvrir —
		# mesure sur le collecteur de la carte temoin, demi-largeur 1,84 puis
		# 0,50 puis 1,31.
		t = maxf(t, previous_t)
		previous_t = t
		# Racine carree et non rampe lineaire : le log du debit est deja tasse,
		# et une rampe droite laisserait presque tout le reseau a la largeur
		# minimale.
		var s := sqrt(t)
		var half_width := lerpf(WIDTH_MIN, WIDTH_MAX, s) * 0.5
		var depth := lerpf(DEPTH_MIN, DEPTH_MAX, s)

		var ground := height_f[i]
		# L'ordre des trois bornes est le coeur du profil en long, voir
		# MAX_CARVE : monotonie d'abord, plafond ensuite (il gagne, et c'est
		# voulu), niveau marin en dernier pour ne pas trancher le fond marin a
		# l'embouchure.
		var bed := minf(previous_bed, ground - depth)
		bed = maxf(bed, ground - MAX_CARVE)
		bed = maxf(bed, float(sea_level) - 1.0)
		previous_bed = bed

		_points.append(float(i % size_xz))
		@warning_ignore("integer_division")
		_points.append(float(i / size_xz))
		_points.append(bed)
		_points.append(half_width)

		if ground <= float(sea_level):
			break

		var next: int = receivers[i]
		if next < 0:
			# Cuvette. Le lissage des hauteurs en fabrique, et un chenal qui
			# s'arreterait au milieu d'un pre n'est pas un chenal : on perce
			# vers le plus bas voisin meme s'il remonte, jusqu'a retrouver une
			# pente.
			if breaches >= BREACH_MAX:
				break
			breaches += 1
			next = _lowest_free_neighbour(i, height_f, visited, offsets, size_xz)
			if next < 0:
				break
		elif visited[next] != 0:
			# Confluence : le tronc est deja trace. On pose un dernier point
			# dessus pour que la jonction soit continue, et on s'arrete — le
			# reparcourir le creuserait deux fois.
			_points.append(float(next % size_xz))
			@warning_ignore("integer_division")
			_points.append(float(next / size_xz))
			_points.append(minf(bed, height_f[next] - DEPTH_MIN))
			_points.append(half_width)
			break
		i = next

	if point_count() > first:
		_path_starts.append(first)


func _lowest_free_neighbour(i: int, height_f: PackedFloat32Array,
		visited: PackedByteArray, offsets: PackedInt32Array,
		size_xz: int) -> int:
	var x := i % size_xz
	@warning_ignore("integer_division")
	var z := i / size_xz
	if x <= 0 or z <= 0 or x >= size_xz - 1 or z >= size_xz - 1:
		return -1
	var best := -1
	var best_height := INF
	for d in 8:
		var j: int = i + offsets[d]
		if visited[j] != 0:
			continue
		if height_f[j] < best_height:
			best_height = height_f[j]
			best = j
	return best


# --- Creusement ------------------------------------------------------------

# Tampon par disques. Les points consecutifs sont a un metre les uns des
# autres, donc les disques se recouvrent largement : inutile de rasteriser
# segment par segment.
#
# La cible de berge est lue sur le terrain D'ORIGINE et non sur le champ en
# cours d'ecriture — sinon un affluent se fondrait vers une altitude deja
# creusee par son tronc, et la berge s'effondrerait de proche en proche.
func _rasterise(height_f: PackedFloat32Array, size_xz: int) -> void:
	for p in point_count():
		var base := p * 4
		var px := _points[base]
		var pz := _points[base + 1]
		var bed := _points[base + 2]
		var half_width := _points[base + 3]
		var reach := half_width + BANK

		var x0 := maxi(floori(px - reach), 0)
		var x1 := mini(ceili(px + reach), size_xz - 1)
		var z0 := maxi(floori(pz - reach), 0)
		var z1 := mini(ceili(pz + reach), size_xz - 1)

		for z in range(z0, z1 + 1):
			var dz := float(z) - pz
			for x in range(x0, x1 + 1):
				var dx := float(x) - px
				var d := sqrt(dx * dx + dz * dz)
				if d > reach:
					continue
				var i := z * size_xz + x
				var target := lerpf(bed, height_f[i],
					smoothstep(half_width, reach, d))
				if target < _target[i]:
					_target[i] = target
				_bed[i] = 1
