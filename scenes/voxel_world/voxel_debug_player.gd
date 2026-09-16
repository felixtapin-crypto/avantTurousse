extends CharacterBody3D

# Controleur de TEST pour la scene voxel, volontairement separe du vrai
# joueur (`scenes/player/player.gd`).
#
# Deux raisons de ne pas reutiliser player.gd ici :
# - il attend un `Platform` (la heightmap) et un `World`, donc le brancher
#   sur le voxel demanderait de le modifier ;
# - il est justement en cours de modification par la PR #29 (eau, faim/soif,
#   plantes), et `TASKS.md` demande de ne pas toucher a un systeme deja pris.
#
# Le vrai joueur sera porte sur le terrain voxel une fois #29 mergee. D'ici
# la, ce controleur sert a inspecter l'ile et a verifier que creuser/poser
# ne remaille bien que le chunk touche.

const WALK_SPEED := 6.0
const SPRINT_MULTIPLIER := 2.0
const FLY_SPEED := 24.0
const JUMP_VELOCITY := 5.5
const MOUSE_SENSITIVITY := 0.003
const REACH := 8.0

signal edit_refused(reason: String)

@onready var camera: Camera3D = $Camera3D

var terrain: VoxelTerrain
var flying := true

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _held_block: int = BlockLibrary.Type.STONE


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		camera.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		camera.rotation.x = clampf(camera.rotation.x, -1.5, 1.5)

	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F:
			flying = not flying
			velocity = Vector3.ZERO

	if event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_edit(true)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_edit(false)


func _physics_process(delta: float) -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	if flying:
		var speed := FLY_SPEED
		# En vol on suit le regard : sinon impossible de monter voir l'ile
		# d'en haut ou de descendre inspecter la quille.
		var forward := -camera.global_transform.basis.z
		var right := camera.global_transform.basis.x
		var direction := (right * input_dir.x + forward * -input_dir.y).normalized()
		if Input.is_action_pressed("jump"):
			direction += Vector3.UP
		if Input.is_key_pressed(KEY_SHIFT):
			direction += Vector3.DOWN
		velocity = direction.normalized() * speed
		move_and_slide()
		return

	if not is_on_floor():
		velocity.y -= _gravity * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var speed_walk := WALK_SPEED
	if Input.is_key_pressed(KEY_SHIFT):
		speed_walk *= SPRINT_MULTIPLIER

	if wish:
		velocity.x = wish.x * speed_walk
		velocity.z = wish.z * speed_walk
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed_walk)
		velocity.z = move_toward(velocity.z, 0.0, speed_walk)

	move_and_slide()


# Creuser (remove=true) ou poser (remove=false) un voxel. Le point d'impact
# est sur la FACE du bloc, donc on decale d'un demi-voxel le long de la
# normale pour tomber a l'interieur du bloc vise (creuser) ou dans le vide
# juste devant (poser).
func _edit(remove: bool) -> void:
	if terrain == null:
		return
	var space := get_world_3d().direct_space_state
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * REACH
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [self]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return

	var position: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var target := position + (normal * (0.5 if not remove else -0.5))
	var cell := Vector3i(floori(target.x), floori(target.y), floori(target.z))

	var before := terrain.get_voxel(cell.x, cell.y, cell.z)
	var applied := terrain.edit_voxel(cell.x, cell.y, cell.z,
		BlockLibrary.Type.AIR if remove else _held_block)

	# Un clic qui ne fait rien ne doit pas se confondre avec un bug — c'est
	# deja la raison d'etre du viseur dans le jeu actuel. On dit donc
	# pourquoi le coup n'a pas porte.
	if not applied and remove and not BlockLibrary.is_breakable(before):
		edit_refused.emit("Roche indestructible : le fond de l'ile ne se creuse pas.")
