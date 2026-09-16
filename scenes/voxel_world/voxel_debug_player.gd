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

const WALK_SPEED := 6.0
const SPRINT_MULTIPLIER := 2.0
const FLY_SPEED := 32.0
const JUMP_VELOCITY := 5.5
const MOUSE_SENSITIVITY := 0.003
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

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


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

	if flying:
		# En vol on suit le regard : sinon impossible de monter voir l'ile
		# d'en haut ou de descendre inspecter le fond marin.
		var forward := -camera.global_transform.basis.z
		var right := camera.global_transform.basis.x
		var direction := (right * input_dir.x + forward * -input_dir.y).normalized()
		if Input.is_action_pressed("jump"):
			direction += Vector3.UP
		if Input.is_key_pressed(KEY_SHIFT):
			direction += Vector3.DOWN
		velocity = direction.normalized() * FLY_SPEED
		move_and_slide()
		return

	if not is_on_floor():
		velocity.y -= _gravity * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var speed := WALK_SPEED
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= SPRINT_MULTIPLIER

	var wish := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
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

	var from := camera.global_position
	var direction := -camera.global_transform.basis.z
	var hit := voxel_tool.raycast(from, direction, REACH)
	if hit == null:
		return

	var center: Vector3 = hit.position
	# Avec le streaming, un chunk peut ne pas etre charge : sculpter dedans
	# serait perdu au chargement.
	var box := AABB(center - Vector3.ONE * brush_radius, Vector3.ONE * brush_radius * 2.0)
	if not voxel_tool.is_area_editable(box):
		edit_refused.emit("Zone pas encore chargee.")
		return

	voxel_tool.mode = VoxelTool.MODE_REMOVE if remove else VoxelTool.MODE_ADD
	voxel_tool.do_sphere(center, brush_radius)
