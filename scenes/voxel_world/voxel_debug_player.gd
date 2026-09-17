extends CharacterBody3D

# Controleur de TEST, volontairement separe du vrai joueur
# (`scenes/player/player.gd`).
#
# Deux raisons de ne pas reutiliser player.gd ici :
# - il attend un `Platform` (la heightmap) et un `World`, donc le brancher
#   sur le voxel demanderait de le modifier ;
# - il est en cours de modification par la PR #29 (eau, faim/soif, plantes),
#   et `TASKS.md` demande de ne pas toucher a un systeme deja pris.
#
# Le vrai joueur sera porte sur le terrain voxel une fois #29 mergee.
#
# ===========================================================================
# LA SOURIS RESTE LIBRE
# ===========================================================================
#
# Le curseur n'est JAMAIS capture en permanence. C'est ce qui permet d'ouvrir
# le menu de pause, de designer un point du terrain, et de garder la main sur
# le bureau.
#
# Mais un curseur libre ne peut pas piloter un regard : il buterait sur les
# bords de l'ecran au bout d'un quart de tour. On capture donc PENDANT LE
# GLISSE, bouton droit enfonce, et on rend le curseur au relachement — Godot
# le repose exactement la ou il etait. C'est le geste de terrain-3d, d'ou
# vient aussi le rig de camera.

const WALK_SPEED := 6.0
const SPRINT_MULTIPLIER := 2.0
const FLY_SPEED := 32.0
const JUMP_VELOCITY := 5.5

# Portee du pinceau AUTOUR DU PERSONNAGE, et non depuis l'objectif : en vue
# d'epaule la camera recule jusqu'a huit metres, et compter depuis elle ferait
# varier la portee avec le zoom.
const REACH := 8.0

signal edit_refused(reason: String)

@onready var camera: Camera3D = $Camera3D

# Outil d'edition fourni par le terrain godot_voxel. Son raycast travaille
# directement sur la grille de voxels : il rend la position exacte du voxel
# vise ET celle du vide juste devant, ce qui evite le decalage d'un demi-bloc
# le long de la normale qu'imposait un raycast physique.
var voxel_tool: VoxelTool

# Le terrain etant lisse, il n'y a pas de bloc a retirer : on sculpte une
# distance signee a la sphere. C'est une difference de GAMEPLAY et pas
# seulement de rendu — `DESIGN.md` demande de poser des blocs pour batir un
# abri, ce qui est nettement moins naturel au pinceau spherique, et reste a
# retrancher (voir issue #34).
var brush_radius := 2.5

var flying := true

# Altitude de la surface d'eau sous le joueur, -INF s'il n'y en a pas. Ecrite
# a chaque image par le monde, seul a savoir ou passent la mer et les
# rivieres. Voir `PlayerCamera.update`.
var water_surface_y := -INF

# Le rig pilote-t-il la camera ?
#
# `scripts/capture.gd` ecrit la transformee globale de l'objectif pour cadrer
# une photo, joueur fige. Avec `top_level`, le rig la reposerait derriere la
# nuque du personnage a l'image suivante et toutes les captures montreraient
# le meme dos.
var camera_rig_active := true

var _rig := PlayerCamera.new()
# Provisoire : voir la section SILHOUETTE en bas de fichier.
var _body_mesh: MeshInstance3D

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# La camera ignore la transformee du corps : c'est le rig qui la place, en
	# coordonnees monde. Voir l'avertissement en tete de `player_camera.gd`.
	camera.top_level = true
	_rig.yaw = rotation.y
	_rig.snap(self, camera)
	_build_body_mesh()


# Recolle la camera apres un deplacement impose (apparition, capture d'ecran).
func snap_camera() -> void:
	_rig.snap(self, camera)


# Rend la camera a `scripts/capture.gd`, qui cadre ses photos en ecrivant la
# transformee globale de l'objectif, joueur fige.
#
# On debranche le rig, sans quoi il reprendrait l'objectif a l'image suivante ;
# et on ramene le bras a ZERO, donc l'objectif sur le pivot. Une photo cadree
# depuis quatre metres derriere la nuque ne montre pas ce qu'on voulait montrer,
# et surtout pas depuis l'interieur d'une grotte. Le site est remis a plat pour
# la meme raison : l'outil documente qu'une capture sans argument regarde
# l'horizon.
func freeze_camera_for_capture() -> void:
	_rig.wanted_distance = 0.0
	_rig.pitch = 0.0
	_rig.snap(self, camera)
	camera_rig_active = false


func _process(delta: float) -> void:
	if not camera_rig_active:
		return
	_rig.update(delta, self, camera, water_surface_y)
	# PROVISOIRE : cf. la section SILHOUETTE.
	if _body_mesh != null:
		var pivot := global_position + Vector3.UP * PlayerCamera.PIVOT_Y
		_body_mesh.visible = (camera.global_position.distance_to(pivot)
			> BODY_HIDE_DISTANCE)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
		var motion := event as InputEventMouseMotion
		_rig.yaw = wrapf(
			_rig.yaw - motion.relative.x * GameSettings.mouse_sensitivity,
			-PI, PI)
		_rig.pitch = clampf(
			_rig.pitch - motion.relative.y * GameSettings.mouse_sensitivity,
			PlayerCamera.PITCH_MIN, PlayerCamera.PITCH_MAX)
		return

	if event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
		return

	# Par l'ACTION et non par la touche : c'est ce qui la rend reaffectable
	# depuis l'ecran des parametres. Voir `autoload/input_setup.gd`.
	if event.is_action_pressed("toggle_fly") and not event.is_echo():
		flying = not flying
		velocity = Vector3.ZERO


# BOUTON DROIT MAINTENU = ON TOURNE LA CAMERA.
#
# Le bouton droit ajoutait de la matiere ; il a fallu lui trouver une autre
# place des lors que le curseur reste libre, parce que l'orbite doit tenir sur
# un bouton qu'on peut maintenir sans rien declencher. Creuser et batir vivent
# donc tous les deux sur le bouton GAUCHE, separes par Maj — deux gestes de la
# meme famille sur la meme touche, ce qui se retient mieux que deux boutons
# aux roles opposes.
func _on_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = (Input.MOUSE_MODE_CAPTURED if event.pressed
			else Input.MOUSE_MODE_VISIBLE)
		return

	if not event.pressed:
		return

	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			_rig.zoom(-1.0)
		MOUSE_BUTTON_WHEEL_DOWN:
			_rig.zoom(1.0)
		MOUSE_BUTTON_LEFT:
			# Maj enfonce ajoute de la matiere, sinon on creuse.
			_edit(not event.shift_pressed)


func _physics_process(delta: float) -> void:
	var input_dir := Input.get_vector(
		"move_left", "move_right", "move_forward", "move_back")

	if flying:
		# En vol on suit le regard COMPLET, site compris : sinon impossible de
		# monter voir l'ile d'en haut ou de descendre inspecter le fond marin.
		# C'est le seul endroit ou le site de la camera entre dans le
		# deplacement — a pied, il ne ferait que pousser le joueur dans le sol.
		var eye_forward := -camera.global_basis.z
		var eye_right := camera.global_basis.x
		var direction := (eye_right * input_dir.x
			+ eye_forward * -input_dir.y).normalized()
		if Input.is_action_pressed("jump"):
			direction += Vector3.UP
		if Input.is_action_pressed("sprint"):
			direction += Vector3.DOWN
		velocity = direction.normalized() * FLY_SPEED
		move_and_slide()
		return

	if not is_on_floor():
		velocity.y -= _gravity * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var speed := WALK_SPEED
	if Input.is_action_pressed("sprint"):
		speed *= SPRINT_MULTIPLIER

	# A PIED, LE REPERE EST LE REGARD ET NON LE CORPS.
	#
	# En vue subjective les deux se confondaient, le lacet vivant sur le corps.
	# En orbite libre le corps ne tourne plus : lire `transform.basis` ferait
	# avancer le joueur vers le meme cap pour toujours, quelle que soit la
	# camera.
	var wish := (_rig.right() * input_dir.x
		+ _rig.forward() * -input_dir.y).normalized()
	if wish:
		velocity.x = wish.x * speed
		velocity.z = wish.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	move_and_slide()


# Sculptage : on n'enleve pas un bloc, on retire ou ajoute de la matiere dans
# une sphere, et le mailleur replace la surface la ou la distance signee
# change de signe.
#
# LE RAYON PART DU CURSEUR, et non de l'axe de l'objectif. En vue subjective
# les deux se confondaient — le centre de l'ecran etait le regard. En vue
# d'epaule, l'axe de l'objectif passe par la nuque du personnage et vise, a
# quatre metres de la, un point sans rapport avec ce qu'on montre. Le curseur
# etant libre, autant s'en servir pour designer.
#
# La bedrock n'est pas protegee ici, et ne peut pas l'etre bloc par bloc : le
# pinceau en couvre plusieurs a la fois. En terrain lisse, la bonne facon de
# la rendre increusable est de borner la distance signee dans le generateur —
# pas encore fait (voir issue #34). Idem pour la synchro reseau : la regle
# devra vivre cote serveur, sinon un pair pourra la contourner.
func _edit(remove: bool) -> void:
	if voxel_tool == null:
		return

	var cursor := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(cursor)
	var direction := camera.project_ray_normal(cursor)
	# La portee est comptee depuis le PERSONNAGE : on ajoute le bras de la
	# camera pour que zoomer n'etende pas le pinceau.
	var arm := from.distance_to(global_position)
	var hit := voxel_tool.raycast(from, direction, REACH + arm)
	if hit == null:
		return

	var center: Vector3 = hit.position
	if center.distance_to(global_position) > REACH + PlayerCamera.PIVOT_Y:
		edit_refused.emit("Trop loin.")
		return

	# Avec le streaming, un chunk peut ne pas etre charge : sculpter dedans
	# serait perdu au chargement.
	var box := AABB(
		center - Vector3.ONE * brush_radius, Vector3.ONE * brush_radius * 2.0)
	if not voxel_tool.is_area_editable(box):
		edit_refused.emit("Zone pas encore chargee.")
		return

	voxel_tool.mode = VoxelTool.MODE_REMOVE if remove else VoxelTool.MODE_ADD
	voxel_tool.do_sphere(center, brush_radius)


# ===========================================================================
# SILHOUETTE — PROVISOIRE, A SUPPRIMER
# ===========================================================================
#
# UNE VUE A LA TROISIEME PERSONNE REGARDE QUELQU'UN, et il n'y avait personne :
# le monde voxel n'a jamais eu de corps visible, la vue subjective n'en
# demandait pas. Sans rien au centre, l'orbite se lit comme une camera libre et
# le zoom comme un recul dans le vide — la vue serait en place sans etre
# lisible.
#
# Cette capsule est un ECHAFAUDAGE, au meme titre que la lampe de grotte de
# `smooth_voxel_world.gd` : la forme exacte de la collision, une couleur unie,
# ni texture ni animation, aucune justification dans la fiction. Elle disparait
# le jour ou le vrai joueur sera porte sur le terrain voxel (voir la note en
# tete de fichier).
#
# Ce qu'il faudra retirer : cette section, l'appel dans `_ready`, le bloc dans
# `_process`, et la variable `_body_mesh`.
#
# Elle s'efface quand l'objectif est trop pres pour la voir entiere — ce qui
# n'arrive qu'en butant contre une paroi, le bras minimal du rig etant plus
# long que ce seuil. Sans cela, on se retrouve dans la capsule et la vue est
# bouchee par sa face interne.
const BODY_HIDE_DISTANCE := 1.4
const BODY_COLOR := Color(0.78, 0.66, 0.52)


func _build_body_mesh() -> void:
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.8

	var material := StandardMaterial3D.new()
	material.albedo_color = BODY_COLOR
	material.roughness = 0.9
	capsule.material = material

	_body_mesh = MeshInstance3D.new()
	_body_mesh.name = "SilhouetteProvisoire"
	_body_mesh.mesh = capsule
	# L'origine du corps est aux PIEDS, celle de la capsule en son milieu.
	_body_mesh.position = Vector3(0.0, 0.9, 0.0)
	add_child(_body_mesh)
