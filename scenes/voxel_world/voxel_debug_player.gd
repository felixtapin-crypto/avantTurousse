class_name VoxelDebugPlayer
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
# LA SOURIS EST CAPTUREE EN PERMANENCE PENDANT LE JEU
# ===========================================================================
#
# Choix initial (curseur libre, capture seulement bouton droit enfonce,
# inspire de terrain-3d) inverse sur demande : viser en permanence sans
# maintenir de bouton, comme un FPS/3e personne classique (Minecraft,
# Valheim...). Le curseur redevient visible uniquement pendant le menu de
# pause (voir `SmoothVoxelWorld._open_pause`/`_close_pause`), qui est le seul
# endroit ou on a encore besoin de cliquer une UI pendant que cette scene
# tourne.

const WALK_SPEED := 6.0
const SPRINT_MULTIPLIER := 2.0
const FLY_SPEED := 32.0
const JUMP_VELOCITY := 5.5

# Portee du pinceau AUTOUR DU PERSONNAGE, et non depuis l'objectif : en vue
# d'epaule la camera recule jusqu'a huit metres, et compter depuis elle ferait
# varier la portee avec le zoom.
const REACH := 8.0

# Marge ajoutee au rayon du pinceau pour refuser un depot trop proche du
# corps (capsule de rayon 0.4, hauteur 1.8 — voir `_edit`). Genereuse plutot
# que calculee au plus juste sur la capsule exacte : le but est d'etre
# largement en dehors de tout chevauchement, pas de raser la limite.
const BUILD_SAFETY_MARGIN := 1.0

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

# Un creusement REUSSI vaut UNE unite portee, et un depot EN COUTE une : le
# pinceau (`brush_radius`) est deja l'unite de matiere que `_edit` manipule a
# chaque coup, compter par coup plutot que tenter d'estimer un volume de SDF
# reellement retire donne directement le meme repere des deux cotes.
#
# Faible au depart pour que la contrainte se sente (revenir deverser avant de
# pouvoir recreuser) — une capacite qui grandit avec un outil trouve est une
# suite naturelle, pas encore faite.
const CARRY_CAPACITY := 8
var carried := 0

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
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
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


# Le bouton droit ne pilote plus la camera (elle tourne en permanence, voir
# la souris capturee en tete de fichier) : il est libre pour un futur usage.
# Creuser et batir restent tous les deux sur le bouton GAUCHE, separes par
# Maj — deux gestes de la meme famille sur la meme touche, ce qui se retient
# mieux que deux boutons aux roles opposes.
func _on_mouse_button(event: InputEventMouseButton) -> void:
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
# La bedrock n'est pas protegee ici, et ne peut pas l'etre bloc par bloc : le
# pinceau en couvre plusieurs a la fois. En terrain lisse, la bonne facon de
# la rendre increusable est de borner la distance signee dans le generateur —
# pas encore fait (voir issue #34). Idem pour la synchro reseau : la regle
# devra vivre cote serveur, sinon un pair pourra la contourner.
func _edit(remove: bool) -> void:
	if voxel_tool == null:
		return

	# Vise le CENTRE DE L'ECRAN (voir `Crosshair`), pas la position OS de la
	# souris : celle-ci ne bouge plus une fois capturee en permanence, elle
	# resterait figee au point ou elle a ete capturee au lieu de suivre le
	# regard.
	var screen_center := get_viewport().get_visible_rect().size / 2.0
	var from := camera.project_ray_origin(screen_center)
	var direction := camera.project_ray_normal(screen_center)
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

	if remove and carried >= CARRY_CAPACITY:
		edit_refused.emit("Inventaire plein — direction un depot.")
		return
	if not remove and carried <= 0:
		edit_refused.emit("Rien a deverser.")
		return

	# UN DEPOT NE PEUT PAS CHEVAUCHER LE PERSONNAGE.
	#
	# Materialiser une sphere solide a l'interieur de la capsule de collision
	# force le moteur physique a l'en ejecter d'un coup, assez fort pour
	# traverser le reste du terrain et tomber hors de la carte (constate en
	# jeu). Creuser sous ses pieds ne pose pas ce probleme — enlever de la
	# matiere ne pousse rien, ca laisse juste tomber normalement.
	if not remove:
		var body_center := global_position + Vector3.UP * 0.9
		if center.distance_to(body_center) < brush_radius + BUILD_SAFETY_MARGIN:
			edit_refused.emit("Trop pres de vous.")
			return

	voxel_tool.mode = VoxelTool.MODE_REMOVE if remove else VoxelTool.MODE_ADD
	voxel_tool.do_sphere(center, brush_radius)
	carried += 1 if remove else -1

	# UN DEPOT SORT DE TERRE, PAS D'HERBE.
	#
	# `do_sphere` en MODE_ADD ne touche que le canal SDF (la geometrie) : la
	# matiere des voxels nouvellement solides reste a sa valeur par defaut, qui
	# se trouve etre GRASS (index 0). On la force a DIRT juste apres le
	# sculptage. Creuser n'a pas besoin de cette etape : la coupe expose la
	# stratification deja posee par `TerrainGenerator` (terre puis roche en
	# profondeur).
	#
	# MODE_TEXTURE_PAINT (le mode dedie, texture_index/texture_opacity) ne
	# produisait aucun changement visible a l'essai — plutot que d'insister sur
	# une API non documentee, `_paint_single_material` ecrit DIRECTEMENT les
	# canaux INDICES/WEIGHTS avec le meme encodage que celui deja utilise, et
	# deja verifie a l'ecran, par `TerrainGenerator._single_material`.
	if not remove:
		_paint_single_material(center, brush_radius, TerrainGenerator.Layer.DIRT)
		_regrow_grass(center, brush_radius)


# Repousse de l'herbe sur un depot laisse a l'air libre, avec le temps.
#
# Duree a calibrer en playtest (voir `FarmPlot.GROWTH_DURATION` pour le meme
# genre de reglage sur l'ancien prototype). Repeindre en herbe un depot qui
# a ete recreuse entretemps ne fait rien de visible : sans matiere solide la,
# la peinture ne colore aucune surface.
const GRASS_REGROWTH_SECONDS := 60.0


func _regrow_grass(center: Vector3, radius: float) -> void:
	await get_tree().create_timer(GRASS_REGROWTH_SECONDS).timeout
	if voxel_tool == null:
		return
	_paint_single_material(center, radius, TerrainGenerator.Layer.GRASS)


# Peint une sphere d'une SEULE matiere, avec le meme encodage que
# `TerrainGenerator._single_material` : quatre index CONSECUTIFS a partir de
# 0 (l'ordre depend seulement de `layer`, jamais de ce qu'il y avait avant),
# et tout le poids sur celui qui correspond a `layer`. Ne marche que pour
# `layer` < 4 (vrai pour GRASS et DIRT, les deux seuls cas d'usage ici) — au
# dela l'ordre des quatre index consecutifs changerait la position du poids.
func _paint_single_material(center: Vector3, radius: float, layer: int) -> void:
	var indices := VoxelTool.vec4i_to_u16_indices(Vector4i(0, 1, 2, 3))
	var weights := [0.0, 0.0, 0.0, 0.0]
	weights[layer] = 1.0
	var packed_weights := VoxelTool.color_to_u16_weights(
		Color(weights[0], weights[1], weights[2], weights[3]))

	voxel_tool.channel = VoxelBuffer.CHANNEL_INDICES
	voxel_tool.mode = VoxelTool.MODE_SET
	voxel_tool.value = indices
	voxel_tool.do_sphere(center, radius)

	voxel_tool.channel = VoxelBuffer.CHANNEL_WEIGHTS
	voxel_tool.value = packed_weights
	voxel_tool.do_sphere(center, radius)

	# Le reste de `_edit` (et le raycast) suppose le canal SDF actif.
	voxel_tool.channel = VoxelBuffer.CHANNEL_SDF


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
