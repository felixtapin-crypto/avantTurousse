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

# ===========================================================================
# UN OBJET NE SE RAMASSE PLUS TOUT SEUL
# ===========================================================================
#
# Il le faisait : le contact creditait l'inventaire sur place et l'objet
# disparaissait. Dans une partie a deux, les objets sont tires de la GRAINE,
# donc les deux joueurs voient les memes cailloux aux memes endroits — et tous
# deux pouvaient ramasser LE MEME. Chacun en obtenait un, et il ne disparaissait
# que pour celui qui l'avait touche. Un monde partage ou les objets se dupliquent.
#
# Le contact ne fait donc plus que DEMANDER. C'est l'hote qui tranche, et sa
# reponse va a tout le monde — meme forme que pour le creusement, voir
# `smooth_voxel_world.request_pickup`.
signal pickup_requested(index: int)

@export var item_id: int = ItemCatalog.Id.ROCK

# Rang de cet objet dans la distribution, identique chez tous les pairs : elle
# se rejoue a partir de la graine et de la meme carte, donc le meme rang designe
# partout le meme objet. C'est ce qui permet a l'hote de dire « le troisieme est
# pris » sans avoir a decrire une position.
var index := -1


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


# Le groupe « players » ne contient QUE le corps qu'on pilote (voir
# `VoxelDebugPlayer._ready`) : l'avatar du compagnon peut donc traverser un
# objet sans rien declencher chez nous, ce qui est bien — c'est a lui de le
# demander depuis sa propre machine.
func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("players"):
		return
	pickup_requested.emit(index)
