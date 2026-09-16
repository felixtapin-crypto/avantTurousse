class_name FarmPlot
extends Area3D

# Parcelle de sol prepare (houe), qui passe par 4 etats : vide -> plantee ->
# en pousse -> prete a recolter. Cree par World.till_soil (voir la meme
# logique que spawn_wreck : un RPC any_peer/call_local construit une copie
# identique chez chaque pair a partir de la position, pas besoin de
# repliquer un noeud existant).

enum State { EMPTY, PLANTED, GROWING, READY }

# A calibrer en playtest (voir DESIGN.md, "Jardinage").
const GROWTH_DURATION := 90.0

var state: State = State.EMPTY

var _sprout: MeshInstance3D
var _grown: MeshInstance3D
var _fruit: MeshInstance3D


func _ready() -> void:
	var soil_material := StandardMaterial3D.new()
	soil_material.albedo_color = Color(0.32, 0.22, 0.12)

	var soil := MeshInstance3D.new()
	var soil_mesh := CylinderMesh.new()
	soil_mesh.top_radius = 0.45
	soil_mesh.bottom_radius = 0.45
	soil_mesh.height = 0.12
	soil.mesh = soil_mesh
	soil.material_override = soil_material
	soil.position = Vector3(0, 0.06, 0)
	add_child(soil)

	var stem_material := StandardMaterial3D.new()
	stem_material.albedo_color = Color(0.3, 0.5, 0.2)

	_sprout = MeshInstance3D.new()
	var sprout_mesh := CylinderMesh.new()
	sprout_mesh.top_radius = 0.02
	sprout_mesh.bottom_radius = 0.04
	sprout_mesh.height = 0.15
	_sprout.mesh = sprout_mesh
	_sprout.material_override = stem_material
	_sprout.position = Vector3(0, 0.2, 0)
	add_child(_sprout)

	_grown = MeshInstance3D.new()
	var grown_mesh := CylinderMesh.new()
	grown_mesh.top_radius = 0.05
	grown_mesh.bottom_radius = 0.07
	grown_mesh.height = 0.5
	_grown.mesh = grown_mesh
	_grown.material_override = stem_material
	_grown.position = Vector3(0, 0.37, 0)
	add_child(_grown)

	var fruit_material := StandardMaterial3D.new()
	fruit_material.albedo_color = Color(0.8, 0.15, 0.15)

	_fruit = MeshInstance3D.new()
	var fruit_mesh := SphereMesh.new()
	fruit_mesh.radius = 0.1
	fruit_mesh.height = 0.2
	_fruit.mesh = fruit_mesh
	_fruit.material_override = fruit_material
	_fruit.position = Vector3(0, 0.65, 0)
	add_child(_fruit)

	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.45
	shape.height = 0.5
	collision.shape = shape
	collision.position = Vector3(0, 0.25, 0)
	add_child(collision)

	_update_visual()


func _update_visual() -> void:
	_sprout.visible = state == State.PLANTED
	_grown.visible = state == State.GROWING or state == State.READY
	_fruit.visible = state == State.READY


@rpc("any_peer", "call_local", "reliable")
func plant() -> void:
	if state != State.EMPTY:
		return
	state = State.PLANTED
	_update_visual()


@rpc("any_peer", "call_local", "reliable")
func water() -> void:
	if state != State.PLANTED:
		return
	state = State.GROWING
	_update_visual()
	await get_tree().create_timer(GROWTH_DURATION).timeout
	if state == State.GROWING:
		state = State.READY
		_update_visual()


@rpc("any_peer", "call_local", "reliable")
func harvest() -> void:
	if state != State.READY:
		return
	queue_free()
