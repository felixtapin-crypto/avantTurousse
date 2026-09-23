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

# Vitesse a laquelle le corps pivote vers sa direction de marche, en rad/s.
const TURN_SPEED := 10.0

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
# Le joueur ne sait pas construire/detruire l'ecran d'inventaire (qui vit
# dans le monde, voir `SmoothVoxelWorld._build_inventory_screen`) : il se
# contente de signaler la demande, meme principe que `edit_refused`.
signal inventory_toggle_requested

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
var inventory := Inventory.new()

# Purement local, comme `inventory` : voir `SurvivalGauges`.
var survival := SurvivalGauges.new()

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

# Le monde, qui porte l'outil de creusement ET l'appel reseau qui le partage.
# Renseigne par `smooth_voxel_world._attach_player`.
var world: Node3D

@onready var sync: MultiplayerSynchronizer = $MultiplayerSynchronizer

var _rig := PlayerCamera.new()
# Provisoire : voir la section SILHOUETTE en bas de fichier.
var _body_mesh: MeshInstance3D

# Ce corps est-il CELUI QU'ON PILOTE, ou l'avatar de quelqu'un d'autre ?
var _local := true

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


# ===========================================================================
# UN CORPS PAR JOUEUR, UN SEUL PILOTE
# ===========================================================================
#
# Le meme script sert au joueur local et aux avatars distants, et c'est
# l'AUTORITE qui les separe. Le nom du noeud est l'identifiant du pair (pose
# par `smooth_voxel_world._add_player`), donc chacun sait en entrant dans
# l'arbre s'il se pilote ou s'il est pilote d'ailleurs.
#
# Un avatar distant ne lit pas les touches, ne calcule pas sa physique et
# n'aiguille pas de camera : sa position et son cap lui arrivent par le
# synchroniseur. Le laisser tourner sa propre physique le ferait tomber et
# glisser en meme temps qu'il est repositionne — les deux se battraient.
func _ready() -> void:
	set_multiplayer_authority(name.to_int())
	_local = is_multiplayer_authority()

	_configure_replication()
	_build_body_mesh()

	# La camera ignore la transformee du corps : c'est le rig qui la place, en
	# coordonnees monde. Voir l'avertissement en tete de `player_camera.gd`.
	camera.top_level = true
	camera.current = _local

	if not _local:
		set_process(false)
		set_physics_process(false)
		set_process_unhandled_input(false)
		return

	# LA CAPTURE NE VAUT QUE POUR LE CORPS QU ON PILOTE. C est un reglage de la
	# FENETRE et non du personnage : l avatar du compagnon la reclamerait aussi,
	# et le dernier arrive gagnerait.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# LE GROUPE NE PREND QUE LE CORPS QU ON PILOTE, pour la meme raison.
	#
	# `ItemPickup` ramasse dans l'inventaire du premier corps du groupe qui le
	# touche. L'avatar du compagnon y passerait aussi : l'objet serait credite
	# a un inventaire qui n'est qu'une copie locale, marque ramasse chez nous,
	# et son proprietaire ne verrait jamais rien arriver.
	add_to_group("players")
	_rig.yaw = rotation.y
	_rig.snap(self, camera)


# CE QUI TRAVERSE LE FIL : la position et le cap, rien d'autre.
#
# Le cap ne sert qu'a voir de quel cote regarde le compagnon — le corps
# s'oriente vers sa marche (voir `_face_movement`). La camera, elle, ne se
# replique pas : chacun regarde ou il veut.
#
# La configuration est batie EN CODE et non dans la scene : elle doit etre
# identique chez tous les pairs, et une ressource partagee par plusieurs
# instances de joueur serait modifiee par la derniere qui la touche.
func _configure_replication() -> void:
	var config := SceneReplicationConfig.new()
	for path in [NodePath(".:position"), NodePath(".:rotation")]:
		config.add_property(path)
		config.property_set_replication_mode(
			path, SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config
	sync.set_multiplayer_authority(name.to_int())
	# VISIBILITE DECLAREE PAIR PAR PAIR, et c'est indispensable.
	#
	# Un synchroniseur public s'annonce aux pairs CONNECTES au moment ou il
	# entre dans l'arbre. Le corps de l'hote entre dans le sien avant que le
	# client n'ait ouvert son monde : l'annonce arrive chez un pair qui n'a
	# encore nulle part ou la ranger, elle est jetee, et les mises a jour qui
	# suivent ne se rattachent plus a rien. Mesure a l'appui, le banc a montre
	# le corps de l'hote fige a son point d'apparition chez le client pendant
	# que le corps du client, lui, bougeait bien chez l'hote — la replication ne
	# marchait que dans le sens ou l'ordre d'arrivee lui etait favorable.
	#
	# En visibilite declaree, c'est le monde qui l'ouvre a chaque pair quand il
	# le sait PRESENT (voir `smooth_voxel_world._set_roster`), et l'annonce part
	# a ce moment-la.
	sync.public_visibility = false


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
	survival.update(delta)
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
		return

	if event.is_action_pressed("toggle_inventory") and not event.is_echo():
		inventory_toggle_requested.emit()
		return

	if event.is_action_pressed("consume") and not event.is_echo():
		_consume()
		return

	# Selection de case LUE EN DUR (comme la molette pour le zoom camera, voir
	# `_on_mouse_button`) : ce ne sont pas des commandes de deplacement, juste
	# un raccourci de position sur le clavier, pas encore reaffectable.
	if event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).physical_keycode
		if key >= KEY_1 and key <= KEY_9:
			inventory.select(key - KEY_1)


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
	_face_movement(delta)


# LE CORPS SE TOURNE VERS SA MARCHE.
#
# Invisible pour soi-meme — en vue d'epaule on regarde son dos, et il tourne
# sous nos yeux sans qu'on ait a le suivre. Mais c'est ce que LE COMPAGNON
# regarde : sans cela son avatar glisse en crabe, fige vers le meme cap, et
# l'on ne sait jamais de quel cote il va. C'est aussi ce qui donne un sens a la
# rotation repliquee.
#
# Le corps ne commande PLUS le deplacement depuis le passage en orbite libre
# (le repere est le regard), donc le tourner ici ne peut rien deregler.
func _face_movement(delta: float) -> void:
	var flat := Vector2(velocity.x, velocity.z)
	if flat.length_squared() < 0.25:
		return
	# Un corps regarde son -Z : le cap qui pointe le long de (x, z) est donc
	# `atan2(-x, -z)`.
	var wanted := atan2(-flat.x, -flat.y)
	rotation.y = lerp_angle(
		rotation.y, wanted, clampf(TURN_SPEED * delta, 0.0, 1.0))


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

	if remove and not inventory.has_room(ItemCatalog.Id.DIRT):
		edit_refused.emit("Inventaire plein — direction un depot.")
		return
	if not remove and inventory.count(ItemCatalog.Id.DIRT) <= 0:
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

	# LE TERRAIN N'EST PAS MODIFIE ICI, IL EST DEMANDE AU MONDE.
	#
	# Creuser et deposer sont les seuls gestes qui changent l'ile, donc les
	# seuls qui doivent traverser le fil : sans cela chacun creuserait dans sa
	# copie et les deux iles divergeraient en silence, sans qu'aucun des deux
	# joueurs ne puisse s'en apercevoir autrement qu'en tombant dans un trou que
	# l'autre ne voit pas.
	#
	# LA PEINTURE DU DEPOT PART AVEC, et ce n'est pas un detail de rangement.
	# L'hote renvoie des BLOCS ENTIERS, tous canaux confondus : s'il posait la
	# sphere sans la peindre, sa version — en herbe par defaut — reviendrait
	# ecraser la terre que le creuseur vient de peindre chez lui. Le depot
	# redeviendrait vert chez tout le monde, et le correctif du commit 0754904
	# serait defait par le reseau. Geometrie et matiere se decident donc au meme
	# endroit : voir `smooth_voxel_world.request_terrain_edit`.
	if world == null:
		return
	world.request_terrain_edit(center, brush_radius, remove)

	if remove:
		inventory.add(ItemCatalog.Id.DIRT, 1)
	else:
		inventory.remove(ItemCatalog.Id.DIRT, 1)


# Boire ou manger, sur une seule touche ("consume") : L'EAU PASSE D'ABORD.
#
# Se tenir dans l'eau prime sur la case active, parce que c'est une
# circonstance (on y est ou on n'y est pas), la ou l'objet en main est un
# choix qui reste vrai un peu partout. Quelqu'un qui patauge en tenant une
# baie veut presque toujours boire, pas la manger — et peut toujours viser
# la baie apres etre sorti de l'eau.
func _consume() -> void:
	if world != null and world.water_surface_at(global_position) > global_position.y:
		survival.drink()
		return

	var slot = inventory.get_slot(inventory.active_slot)
	if slot == null or not ItemCatalog.is_food(slot["item"]):
		edit_refused.emit("Rien a boire ou manger ici.")
		return

	var item_id: int = slot["item"]
	inventory.remove(item_id, 1)
	survival.eat(item_id)


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
