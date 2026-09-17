class_name ItemPickup
extends Area3D

# Objet ramassable au sol - UN SEUL script generique pour tout ramassable
# (meme idee que `Collectible.unlock_method` dans l'ancien prototype), pas un
# script par objet : le sac a dos utilise exactement cette meme scene avec un
# `item_id` different.
#
# Ramassage par CONTACT (marcher dessus), pas par clic. `_edit()` vise avec
# `voxel_tool.raycast`, un raycast VOXEL UNIQUEMENT qui ne detecte jamais
# d'`Area3D`/`Body3D`. Ajouter un second raycast physique sur chaque clic de
# creusement (tres frequent) pour servir un ramassage tres rare serait
# disproportionne ; le contact colle mieux a "trouve en explorant."

signal picked_up(item_id: int)
signal pickup_refused(reason: String)

@export var item_id: int = ItemCatalog.Id.ROCK

var _collected := false


func _ready() -> void:
	var shape := SphereShape3D.new()
	shape.radius = 0.6
	var collision := CollisionShape3D.new()
	collision.shape = shape
	add_child(collision)

	# Placeholder en aplat de couleur, meme niveau de finition que la
	# silhouette provisoire du joueur (`VoxelDebugPlayer._build_body_mesh`).
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.35, 0.35, 0.35)
	mesh_instance.mesh = box
	var material := StandardMaterial3D.new()
	material.albedo_color = ItemCatalog.color(item_id)
	material.roughness = 0.8
	mesh_instance.material_override = material
	mesh_instance.position = Vector3(0, 0.2, 0)
	add_child(mesh_instance)

	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if _collected or not body.is_in_group("players"):
		return
	if not ("inventory" in body):
		return

	var inventory: Inventory = body.inventory
	if not inventory.has_room(item_id):
		pickup_refused.emit("Inventaire plein.")
		return

	inventory.add(item_id, 1)
	_collected = true
	picked_up.emit(item_id)
	queue_free()
