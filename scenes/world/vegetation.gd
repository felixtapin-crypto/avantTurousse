class_name Vegetation
extends Node3D

# Place des arbres (troncs/feuillage en primitives, pas de modele importe)
# sur les colonnes valides de la plateforme, en evitant le bord. Genere de
# facon deterministe a partir d'une seed : chaque joueur obtient exactement
# la meme foret et choisit le meme arbre pour l'artefact cache, sans le
# moindre echange reseau pour ca (seule la RECOLTE de l'artefact est
# synchronisee, via Collectible.pick_up).

const CollectibleScene := preload("res://scenes/world/collectible.gd")

@export var tree_count: int = 60
@export var min_spacing: float = 6.0
@export var edge_margin: float = 8.0

var platform: Platform


func generate(seed_value: int, platform_ref: Platform) -> void:
	platform = platform_ref
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var placed: Array[Vector2] = []
	var attempts := 0
	while placed.size() < tree_count and attempts < tree_count * 25:
		attempts += 1
		var x := rng.randf_range(edge_margin, float(platform.size) - edge_margin)
		var z := rng.randf_range(edge_margin, float(platform.size) - edge_margin)
		if not _is_good_spot(x, z):
			continue
		var too_close := false
		for p in placed:
			if p.distance_to(Vector2(x, z)) < min_spacing:
				too_close = true
				break
		if too_close:
			continue

		placed.append(Vector2(x, z))
		var tree := _build_tree(rng)
		tree.position = Vector3(x, platform.get_height_at(x, z), z)
		tree.rotation.y = rng.randf_range(0.0, TAU)
		add_child(tree)

	if placed.size() < 2:
		return

	# Meme seed -> memes index choisis -> les memes arbres chez tout le
	# monde. Deux index distincts pour ne pas cacher les deux artefacts au
	# meme endroit.
	var clock_index := rng.randi_range(0, placed.size() - 1)
	var tool_index := rng.randi_range(0, placed.size() - 1)
	while tool_index == clock_index:
		tool_index = rng.randi_range(0, placed.size() - 1)

	_attach_clock(get_child(clock_index))
	_attach_harvest_tool(get_child(tool_index))


func _is_good_spot(x: float, z: float) -> bool:
	if not platform.is_land(x, z):
		return false
	for offset in [Vector2(edge_margin, 0), Vector2(-edge_margin, 0), Vector2(0, edge_margin), Vector2(0, -edge_margin)]:
		if not platform.is_land(x + offset.x, z + offset.y):
			return false
	return true


func _build_tree(rng: RandomNumberGenerator) -> Node3D:
	var tree := StaticBody3D.new()

	var trunk_material := StandardMaterial3D.new()
	trunk_material.albedo_color = Color(0.36, 0.25, 0.16)

	var foliage_material := StandardMaterial3D.new()
	foliage_material.albedo_color = Color(0.2, 0.45, 0.18)

	var trunk_height := rng.randf_range(2.0, 3.2)
	var trunk := MeshInstance3D.new()
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.18
	trunk_mesh.bottom_radius = 0.24
	trunk_mesh.height = trunk_height
	trunk.mesh = trunk_mesh
	trunk.material_override = trunk_material
	trunk.position = Vector3(0, trunk_height / 2.0, 0)
	tree.add_child(trunk)

	var foliage_radius := rng.randf_range(1.1, 1.6)
	var foliage := MeshInstance3D.new()
	var foliage_mesh := SphereMesh.new()
	foliage_mesh.radius = foliage_radius
	foliage_mesh.height = foliage_radius * 2.0
	foliage.mesh = foliage_mesh
	foliage.material_override = foliage_material
	foliage.position = Vector3(0, trunk_height + foliage_radius * 0.6, 0)
	tree.add_child(foliage)

	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.22
	capsule.height = trunk_height
	collision.shape = capsule
	collision.position = Vector3(0, trunk_height / 2.0, 0)
	tree.add_child(collision)

	return tree


# Accroche l'horloge (premier artefact du jeu, voir DESIGN.md) au pied de
# l'arbre choisi : une petite montre a gousset doree, qui tourne doucement
# et brille pour rester reperable dans le feuillage environnant.
func _attach_clock(tree: Node3D) -> Node3D:
	var clock := Area3D.new()
	clock.set_script(CollectibleScene)

	var body_material := StandardMaterial3D.new()
	body_material.albedo_color = Color(0.85, 0.68, 0.25)
	body_material.metallic = 0.7
	body_material.roughness = 0.25
	body_material.emission_enabled = true
	body_material.emission = Color(0.9, 0.7, 0.2)
	body_material.emission_energy_multiplier = 0.6

	var face := MeshInstance3D.new()
	var face_mesh := CylinderMesh.new()
	face_mesh.top_radius = 0.22
	face_mesh.bottom_radius = 0.22
	face_mesh.height = 0.08
	face.mesh = face_mesh
	face.material_override = body_material
	face.rotation_degrees = Vector3(90, 0, 0)
	clock.add_child(face)

	var loop := MeshInstance3D.new()
	var loop_mesh := CylinderMesh.new()
	loop_mesh.top_radius = 0.04
	loop_mesh.bottom_radius = 0.04
	loop_mesh.height = 0.18
	loop.mesh = loop_mesh
	loop.material_override = body_material
	loop.position = Vector3(0, 0.24, 0)
	clock.add_child(loop)

	var area_collision := CollisionShape3D.new()
	var area_shape := SphereShape3D.new()
	area_shape.radius = 0.4
	area_collision.shape = area_shape
	clock.add_child(area_collision)

	clock.position = Vector3(0.5, 0.35, 0.0)
	tree.add_child(clock)
	return clock


# Outil de recolte (voir DESIGN.md, "Flore et faune"/"Jardinage") : une
# petite serpe, manche en bois + lame grise, posee contre le tronc.
func _attach_harvest_tool(tree: Node3D) -> Node3D:
	var tool := Area3D.new()
	tool.set_script(CollectibleScene)
	tool.unlock_method = "unlock_harvest_tool"

	var handle_material := StandardMaterial3D.new()
	handle_material.albedo_color = Color(0.42, 0.28, 0.15)

	var blade_material := StandardMaterial3D.new()
	blade_material.albedo_color = Color(0.75, 0.76, 0.78)
	blade_material.metallic = 0.6
	blade_material.roughness = 0.3

	var handle := MeshInstance3D.new()
	var handle_mesh := CylinderMesh.new()
	handle_mesh.top_radius = 0.03
	handle_mesh.bottom_radius = 0.03
	handle_mesh.height = 0.5
	handle.mesh = handle_mesh
	handle.material_override = handle_material
	handle.rotation_degrees = Vector3(0, 0, 70)
	tool.add_child(handle)

	var blade := MeshInstance3D.new()
	var blade_mesh := BoxMesh.new()
	blade_mesh.size = Vector3(0.28, 0.05, 0.09)
	blade.mesh = blade_mesh
	blade.material_override = blade_material
	blade.position = Vector3(0.22, 0.16, 0.0)
	blade.rotation_degrees = Vector3(0, 0, -30)
	tool.add_child(blade)

	var area_collision := CollisionShape3D.new()
	var area_shape := SphereShape3D.new()
	area_shape.radius = 0.35
	area_collision.shape = area_shape
	tool.add_child(area_collision)

	tool.position = Vector3(-0.45, 0.25, 0.15)
	tree.add_child(tool)
	return tool
