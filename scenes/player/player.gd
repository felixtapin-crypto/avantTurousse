extends CharacterBody3D

const SPEED := 5.0
const JUMP_VELOCITY := 4.5
const MOUSE_SENSITIVITY := 0.003

const FIRST_PERSON_CAMERA_POS := Vector3(0, 1.6, 0)
const ARRIVAL_HEIGHT := 45.0
const ARRIVAL_APPROACH := Vector3(-20.0, 0.0, -20.0)
const ARRIVAL_DURATION := 3.2

@onready var camera: Camera3D = $Camera3D
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var sync: MultiplayerSynchronizer = $MultiplayerSynchronizer

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

# Tant que false, ni les deplacements ni la camera FPS ne sont actifs : le
# joueur regarde son personnage s'ecraser en engin volant avant de reprendre
# la main. Voir _play_arrival_sequence().
var arrived := false

var _arrival_start: Vector3
var _arrival_target: Vector3
var _glider: Node3D = null


func _ready() -> void:
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
		camera.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		camera.rotation.x = clampf(camera.rotation.x, -1.3, 1.3)

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	if event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


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
	_glider = _build_glider()
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
	camera.position = FIRST_PERSON_CAMERA_POS
	camera.rotation = Vector3.ZERO

	arrived = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _arrival_step(t: float) -> void:
	position = _arrival_start.lerp(_arrival_target, t)
	camera.look_at(_arrival_target + Vector3(0, 1.0, 0), Vector3.UP)


func _shake_camera() -> Tween:
	var tween := create_tween()
	for i in range(5):
		var offset := Vector2(randf_range(-0.08, 0.08), randf_range(-0.05, 0.05))
		tween.tween_property(camera, "h_offset", offset.x, 0.04)
		tween.parallel().tween_property(camera, "v_offset", offset.y, 0.04)
	tween.tween_property(camera, "h_offset", 0.0, 0.05)
	tween.parallel().tween_property(camera, "v_offset", 0.0, 0.05)
	return tween


func _build_glider() -> Node3D:
	var rig := Node3D.new()

	var wood_material := StandardMaterial3D.new()
	wood_material.albedo_color = Color(0.4, 0.26, 0.14)

	var brass_material := StandardMaterial3D.new()
	brass_material.albedo_color = Color(0.72, 0.53, 0.18)
	brass_material.metallic = 0.6
	brass_material.roughness = 0.35

	var gondola := MeshInstance3D.new()
	var gondola_mesh := BoxMesh.new()
	gondola_mesh.size = Vector3(1.0, 0.8, 1.6)
	gondola.mesh = gondola_mesh
	gondola.material_override = wood_material
	gondola.position = Vector3(0, -0.6, 0)
	rig.add_child(gondola)

	var wing := MeshInstance3D.new()
	var wing_mesh := BoxMesh.new()
	wing_mesh.size = Vector3(3.6, 0.1, 1.0)
	wing.mesh = wing_mesh
	wing.material_override = brass_material
	wing.position = Vector3(0, 0.1, 0)
	rig.add_child(wing)

	var tail := MeshInstance3D.new()
	var tail_mesh := BoxMesh.new()
	tail_mesh.size = Vector3(0.15, 0.6, 0.15)
	tail.mesh = tail_mesh
	tail.material_override = brass_material
	tail.position = Vector3(0, 0.1, 1.1)
	rig.add_child(tail)

	var propeller := MeshInstance3D.new()
	var propeller_mesh := BoxMesh.new()
	propeller_mesh.size = Vector3(0.08, 1.3, 0.12)
	propeller.mesh = propeller_mesh
	propeller.material_override = brass_material
	propeller.position = Vector3(0, 0.1, -1.0)
	rig.add_child(propeller)

	return rig
