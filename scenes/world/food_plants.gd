class_name FoodPlants
extends Node3D

# Buissons a baies disperses sur la plateforme (nourriture). Genere de facon
# deterministe (meme seed -> meme disposition chez tous les joueurs), comme
# Vegetation, en evitant l'eau et le bord de la plateforme.

@export var plant_count: int = 40
@export var min_spacing: float = 4.0
@export var edge_margin: float = 6.0

var platform: Platform
var water: Water


func generate(seed_value: int, platform_ref: Platform, water_ref: Water) -> void:
	platform = platform_ref
	water = water_ref
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var placed: Array[Vector2] = []
	var attempts := 0
	while placed.size() < plant_count and attempts < plant_count * 25:
		attempts += 1
		var x := rng.randf_range(edge_margin, float(platform.size) - edge_margin)
		var z := rng.randf_range(edge_margin, float(platform.size) - edge_margin)
		if not platform.is_land(x, z) or water.is_water_at(x, z):
			continue
		var too_close := false
		for p in placed:
			if p.distance_to(Vector2(x, z)) < min_spacing:
				too_close = true
				break
		if too_close:
			continue

		placed.append(Vector2(x, z))
		var plant := _build_plant(rng)
		plant.position = Vector3(x, platform.get_height_at(x, z), z)
		add_child(plant)


func _build_plant(rng: RandomNumberGenerator) -> Area3D:
	var plant := Area3D.new()
	plant.set_script(load("res://scenes/world/food_plant.gd"))

	var leaf_material := StandardMaterial3D.new()
	leaf_material.albedo_color = Color(0.25, 0.42, 0.16)

	var berry_material := StandardMaterial3D.new()
	berry_material.albedo_color = Color(0.75, 0.12, 0.18)

	var bush := MeshInstance3D.new()
	var bush_mesh := SphereMesh.new()
	bush_mesh.radius = 0.35
	bush_mesh.height = 0.6
	bush.mesh = bush_mesh
	bush.material_override = leaf_material
	bush.position = Vector3(0, 0.3, 0)
	plant.add_child(bush)

	for i in 4:
		var berry := MeshInstance3D.new()
		var berry_mesh := SphereMesh.new()
		berry_mesh.radius = 0.06
		berry_mesh.height = 0.12
		berry.mesh = berry_mesh
		berry.material_override = berry_material
		berry.position = Vector3(
			rng.randf_range(-0.22, 0.22),
			0.4 + rng.randf_range(-0.05, 0.1),
			rng.randf_range(-0.22, 0.22)
		)
		plant.add_child(berry)

	var collision := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.4
	collision.shape = shape
	plant.add_child(collision)

	return plant
