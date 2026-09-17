class_name PlayerCamera
extends RefCounted

# Camera d'epaule en ORBITE LIBRE : la souris tourne la camera AUTOUR du
# personnage sans le tourner. C'est toute la difference avec la vue subjective
# d'avant, ou le lacet vivait sur le corps — ici on peut regarder derriere soi
# tout en marchant droit devant.
#
# PORTE DEPUIS `terrain-3d` (`world/player_camera.gd`), sur indication de
# l'auteur du projet : le rig y est deja eprouve, et le refaire n'aurait produit
# qu'une version moins finie de la meme chose. Les constantes sont reprises
# telles quelles, a l'exception de `PIVOT_Y` — nos deux capsules n'ont pas leur
# origine au meme endroit, voir plus bas.
#
# LA CAMERA RESTE UN ENFANT DIRECT DU JOUEUR, NOMMEE `Camera3D`. Ce n'est pas
# une preference de rangement, c'est une contrainte : `smooth_voxel_world.gd`
# la resout par `find_children("*", "Camera3D")` pour piloter l'immersion, et
# `scripts/capture.gd` l'attrape par le meme chemin pour cadrer ses photos.
#
# D'ou `top_level = true` plutot qu'un `SpringArm3D` : la camera reste au bon
# endroit de l'arbre mais ignore la transformee du corps. Ce choix repond aussi
# a l'issue #2, qui demandait un SpringArm3D pour empecher la camera de
# traverser le terrain — la sonde spherique de `_free_length` fait le meme
# travail, et mieux : un simple rayon se faufile entre deux reliefs et laisse
# l'objectif se planter dans la roche.

# Hauteur du pivot au-dessus de l'origine du joueur, en metres.
#
# ECART ASSUME AVEC TERRAIN-3D, qui met 0,55. Sa capsule a son origine au
# CENTRE ; la notre l'a aux PIEDS (`CollisionShape3D` decalee de +0,9 dans
# `smooth_voxel_world.tscn`). Les deux valeurs designent donc la meme epaule,
# a un metre et demi du sol — et 1,5 est aussi la ou se tenait l'ancienne
# camera subjective, a 1,6 pres.
const PIVOT_Y := 1.5

# Distance de recul, en metres.
const DIST_MIN := 1.5
const DIST_MAX := 8.0
const DIST_DEFAULT := 4.0
const DIST_STEP := 0.6

# Vitesse de rattrapage de la distance voulue (m/s). Le rabattement sur
# obstacle, lui, est INSTANTANE : on ne veut jamais voir a travers la roche,
# meme une image.
const DIST_SMOOTHING := 12.0

# Retour apres un obstacle : plus lent que le zoom, sinon la camera fait le
# yoyo en longeant une paroi.
const RETURN_SMOOTHING := 6.0

# Debattement vertical. Asymetrique a dessein : on veut pouvoir regarder son
# personnage de dessus (-75 degres), pas passer sous ses pieds (+32).
const PITCH_MIN := -1.30
const PITCH_MAX := 0.55

# Rayon de la sonde de rabattement.
const PROBE_RADIUS := 0.22

var yaw := 0.0
var pitch := -0.25
var wanted_distance := DIST_DEFAULT

var _distance := DIST_DEFAULT
var _probe: SphereShape3D


func _init() -> void:
	_probe = SphereShape3D.new()
	_probe.radius = PROBE_RADIUS


# Applique le rig. `body` porte la position, `camera` est repositionnee en
# coordonnees MONDE.
#
# `water_y` est l'altitude de la surface d'eau sous le joueur, ou -INF s'il n'y
# en a pas. Voir la note sur le mouillage plus bas.
func update(delta: float, body: CharacterBody3D, camera: Camera3D,
		water_y: float) -> void:
	var pivot := body.global_position + Vector3.UP * PIVOT_Y
	var basis := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	# L'ARRIERE de la camera : le bras d'orbite part du pivot et recule.
	var direction := basis * Vector3(0.0, 0.0, 1.0)

	var free_length := _free_length(body, pivot, direction)
	if free_length < _distance:
		_distance = free_length
	else:
		_distance = move_toward(_distance, minf(free_length, wanted_distance),
			RETURN_SMOOTHING * delta)
	_distance = move_toward(_distance, minf(free_length, wanted_distance),
		DIST_SMOOTHING * delta)

	var position := pivot + direction * _distance
	# LA CAMERA NE SE MOUILLE PAS TOUTE SEULE.
	#
	# Quand le personnage est au sec, on maintient l'objectif au-dessus de la
	# surface : sinon, reculer d'un pas au bord d'un chenal declenche le voile
	# bleu plein ecran alors qu'on a les pieds sur la berge. Nos chenaux font
	# entre un et quatre metres de large et le bras en fait quatre — le cas
	# n'est pas theorique, il se produit des qu'on longe une riviere.
	#
	# Consequence heureuse : `_update_immersion` reste branche sur la seule
	# camera, sans une ligne de changement, et ne se declenche plus qu'a la
	# plongee reelle.
	if is_finite(water_y):
		position.y = maxf(position.y, water_y + 0.15)
	camera.global_position = position
	camera.global_basis = basis


# Recolle la camera sur le personnage, sans lissage.
#
# Indispensable apres un DEPLACEMENT IMPOSE : avec `top_level`, la camera ne
# suit pas un saut de position. Le monde en pose un juste apres avoir cree le
# joueur (`_spawn_position`), et `scripts/capture.gd` en pose un autre.
func snap(body: CharacterBody3D, camera: Camera3D) -> void:
	_distance = wanted_distance
	var pivot := body.global_position + Vector3.UP * PIVOT_Y
	var basis := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	camera.global_position = pivot + basis * Vector3(0.0, 0.0, 1.0) * _distance
	camera.global_basis = basis


func zoom(step: float) -> void:
	wanted_distance = clampf(
		wanted_distance + step * DIST_STEP, DIST_MIN, DIST_MAX)


# Avant du REGARD, aplati. C'est le repere des commandes de deplacement : en
# orbite libre, avancer veut dire « vers ou je regarde », pas « vers ou le
# corps pointe ».
func forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func right() -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


# Longueur de bras disponible avant obstacle.
func _free_length(body: CharacterBody3D, pivot: Vector3,
		direction: Vector3) -> float:
	var space := body.get_world_3d().direct_space_state
	if space == null:
		return wanted_distance
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _probe
	query.transform = Transform3D(Basis(), pivot)
	query.motion = direction * wanted_distance
	query.collision_mask = 1
	query.exclude = [body.get_rid()]
	var hit := space.cast_motion(query)
	# `cast_motion` rend [t_sur, t_impact] dans [0,1] ; un tableau vide vaut
	# « rien touche ». Le terrain voxel n'a pas toujours sa collision prete —
	# en streaming, un bloc peut n'etre pas encore la — et le cas se confond
	# alors avec « rien touche », ce qui est le bon comportement : mieux vaut
	# un bras entier qu'un bras rabattu sur un vide qui va se remplir.
	return wanted_distance if hit.is_empty() else wanted_distance * float(hit[0])
