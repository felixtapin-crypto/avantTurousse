extends CharacterBody3D

const SPEED := 5.0
const JUMP_VELOCITY := 4.5
const MOUSE_SENSITIVITY := 0.003
const INTERACTION_RANGE := 8.0
const CROSSHAIR_IDLE_COLOR := Color(1, 1, 1, 0.8)
const CROSSHAIR_TARGET_COLOR := Color(1, 0.85, 0.2, 1.0)

const THIRD_PERSON_CAMERA_POS := Vector3(0, 1.2, 4.0)
const ARRIVAL_HEIGHT := 45.0
const ARRIVAL_APPROACH := Vector3(-20.0, 0.0, -20.0)
const ARRIVAL_DURATION := 3.2

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var sync: MultiplayerSynchronizer = $MultiplayerSynchronizer
@onready var hud: CanvasLayer = $Hud
@onready var block_label: Label = $Hud/BlockLabel
@onready var crosshair_h: ColorRect = $Hud/Crosshair/Horizontal
@onready var crosshair_v: ColorRect = $Hud/Crosshair/Vertical
@onready var clock_label: Label = $Hud/ClockLabel

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# Injectes par World._spawn_player() a la creation de ce joueur.
var world_platform: Platform
var world # reference generique vers le noeud World (pas de class_name dessus)

# Tant que false, ni les deplacements ni le controle de la camera ne sont
# actifs : le joueur regarde son personnage s'ecraser en engin volant avant
# de reprendre la main. Voir _play_arrival_sequence().
var arrived := false

# Inventaire minimal : un seul type de "bloc" pour l'instant. Creuser en
# donne, construire en consomme. Voir Platform.request_edit pour la logique
# de sculpte du terrain elle-meme.
var block_count := 5

# Debloque par Collectible.pick_up() une fois l'horloge trouvee par
# n'importe quel joueur de l'equipe (voir DESIGN.md, gabarit "L'horloge").
var has_clock := false

var _arrival_start: Vector3
var _arrival_target: Vector3
var _glider: Node3D = null
var _rain: GPUParticles3D
var _was_raining := false


func _ready() -> void:
	add_to_group("players")

	# The node's name is set to the peer id by World._spawn_player(), so this
	# grants movement authority to whichever peer this instance represents.
	set_multiplayer_authority(name.to_int())

	var config := SceneReplicationConfig.new()
	config.add_property(NodePath(".:position"))
	config.add_property(NodePath(".:rotation"))
	config.property_set_replication_mode(NodePath(".:position"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	config.property_set_replication_mode(NodePath(".:rotation"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = config

	camera.current = is_multiplayer_authority()
	hud.visible = is_multiplayer_authority()
	_update_hud()
	clock_label.visible = has_clock
	_rain = _build_rain()

	if is_multiplayer_authority():
		_play_arrival_sequence()
	else:
		# Les autres joueurs ne rejouent pas la cinematique localement ; ils
		# verront simplement cette instance suivre sa position repliquee
		# (donc descendre puis se poser, sans l'engin volant visible).
		arrived = true


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority() or not arrived:
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		camera_pivot.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		camera_pivot.rotation.x = clampf(camera_pivot.rotation.x, -1.3, 1.3)

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	if event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_dig()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_build()


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority() or not arrived:
		return

	if not is_on_floor():
		velocity.y -= gravity * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)

	move_and_slide()


# Le viseur passe en couleur vive des qu'une cible valide (a portee,
# reellement touchee par le rayon) est dans le champ, pour qu'on sache tout
# de suite si un clic va faire quelque chose ou non. On en profite pour
# activer/desactiver la pluie locale selon la meteo partagee (World.is_raining,
# calculee independamment par chaque pair mais identique au meme instant).
func _process(_delta: float) -> void:
	if not is_multiplayer_authority() or not arrived:
		return

	var has_target := not _raycast().is_empty()
	var color := CROSSHAIR_TARGET_COLOR if has_target else CROSSHAIR_IDLE_COLOR
	crosshair_h.color = color
	crosshair_v.color = color

	var raining: bool = world.is_raining()
	if raining != _was_raining:
		_rain.emitting = raining
		_was_raining = raining

	if has_clock:
		clock_label.text = _format_time(world.get_time_of_day())


# Creuse la colonne visee (baisse sa hauteur de 1m) et recupere un bloc -
# sauf si on vise plutot un objet ramassable (Collectible), auquel cas on le
# recupere a la place.
func _dig() -> void:
	var hit := _raycast()
	if hit.is_empty():
		return

	var collider = hit.get("collider")
	if collider is Collectible:
		collider.pick_up.rpc()
		return

	var column := _hit_to_column(hit)
	world_platform.request_edit.rpc(column.x, column.y, -1)
	block_count += 1
	_update_hud()


# Appele par Collectible.pick_up() sur l'instance locale faisant autorite
# (voir la boucle sur le groupe "players") des qu'un joueur de l'equipe
# trouve l'horloge - profite a tout le monde, pas seulement a qui l'a
# trouvee, conformement a la quete partagee.
func unlock_clock() -> void:
	has_clock = true
	clock_label.visible = true


# Construit sur la colonne visee (monte sa hauteur de 1m), si on a un bloc.
func _build() -> void:
	if block_count <= 0:
		return
	var hit := _raycast()
	if hit.is_empty():
		return
	var column := _hit_to_column(hit)
	world_platform.request_edit.rpc(column.x, column.y, 1)
	block_count -= 1
	_update_hud()


func _raycast() -> Dictionary:
	var space_state := get_world_3d().direct_space_state
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * INTERACTION_RANGE
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [self]
	query.collide_with_areas = true
	return space_state.intersect_ray(query)


func _hit_to_column(hit: Dictionary) -> Vector2i:
	var pos: Vector3 = hit["position"]
	return Vector2i(int(round(pos.x)), int(round(pos.z)))


func _update_hud() -> void:
	block_label.text = "Blocs : %d" % block_count


func _format_time(time_of_day: float) -> String:
	var total_minutes := int(time_of_day * 24.0 * 60.0)
	return "%02d:%02d" % [total_minutes / 60, total_minutes % 60]


# Fait apparaitre le joueur tres haut au-dessus de son point d'atterrissage a
# bord d'un engin volant (placeholder steampunk : nacelle + aile + helice en
# primitives, en attendant un vrai modele), puis l'amene au sol par un tween
# plutot que de compter sur la gravite/collision pour "l'attraper" en chute
# libre. Corrige au passage le bug ou le joueur pouvait se retrouver sous la
# plateforme : on ne depend plus d'un atterrissage physique approximatif, la
# position finale est fixee exactement a la hauteur du terrain.
func _play_arrival_sequence() -> void:
	var landing_position := position

	mesh.visible = false
	_glider = GliderBuilder.build()
	add_child(_glider)

	_arrival_start = landing_position + ARRIVAL_APPROACH + Vector3(0, ARRIVAL_HEIGHT, 0)
	_arrival_target = landing_position
	position = _arrival_start

	camera.position = Vector3(0, 3.0, 6.0)
	camera.look_at(_arrival_target + Vector3(0, 1.0, 0), Vector3.UP)

	var tween := create_tween()
	tween.tween_method(_arrival_step, 0.0, 1.0, ARRIVAL_DURATION) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await tween.finished

	await _shake_camera().finished

	_glider.queue_free()
	_glider = null
	mesh.visible = true
	camera.position = THIRD_PERSON_CAMERA_POS
	camera.rotation = Vector3.ZERO

	# Garde une trace de l'atterrissage : une epave identique est construite
	# chez chaque joueur connecte (voir World.spawn_wreck), plutot que de
	# faire disparaitre l'engin qui nous a amenes ici.
	world.spawn_wreck.rpc(landing_position, rotation.y)

	arrived = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _arrival_step(t: float) -> void:
	position = _arrival_start.lerp(_arrival_target, t)
	camera.look_at(_arrival_target + Vector3(0, 1.0, 0), Vector3.UP)


# Pluie locale qui suit le joueur (emetteur enfant du personnage), pour
# donner l'impression qu'il pleut partout sur la plateforme sans avoir a
# couvrir toute sa surface d'un seul systeme de particules. Le booleen
# "pleut-il" vient de World.is_raining() ; l'effet visuel lui-meme n'est pas
# reseau - chaque joueur affiche sa propre pluie autour de lui.
func _build_rain() -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.amount = 200
	particles.lifetime = 1.5
	particles.emitting = false
	particles.visibility_aabb = AABB(Vector3(-12, -14, -12), Vector3(24, 24, 24))

	var material := ParticleProcessMaterial.new()
	material.direction = Vector3(0, -1, 0)
	material.spread = 5.0
	material.initial_velocity_min = 12.0
	material.initial_velocity_max = 16.0
	material.gravity = Vector3.ZERO
	material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	material.emission_box_extents = Vector3(10.0, 0.5, 10.0)
	particles.process_material = material

	var quad := QuadMesh.new()
	quad.size = Vector2(0.03, 0.4)
	particles.draw_pass_1 = quad

	particles.position = Vector3(0, 10, 0)
	add_child(particles)
	return particles


func _shake_camera() -> Tween:
	var tween := create_tween()
	for i in range(5):
		var offset := Vector2(randf_range(-0.08, 0.08), randf_range(-0.05, 0.05))
		tween.tween_property(camera, "h_offset", offset.x, 0.04)
		tween.parallel().tween_property(camera, "v_offset", offset.y, 0.04)
	tween.tween_property(camera, "h_offset", 0.0, 0.05)
	tween.parallel().tween_property(camera, "v_offset", 0.0, 0.05)
	return tween
