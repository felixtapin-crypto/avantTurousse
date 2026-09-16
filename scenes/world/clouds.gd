class_name Clouds
extends Node3D

# Nuages places au hasard, en amas de sprites billboard (une texture generee
# au demarrage, pas d'image externe), qui derivent lentement puis
# reapparaissent de l'autre cote une fois sortis de la zone. Purement
# decoratif, independant chez chaque joueur - pas besoin que les nuages
# soient identiques d'un joueur a l'autre.

@export var cloud_count: int = 18
@export var area_size: float = 500.0
@export var altitude: float = 90.0
@export var altitude_variation: float = 15.0
@export var wind_speed: float = 1.5

var _velocities: Array[Vector3] = []


func _ready() -> void:
	var texture := _make_cloud_texture()
	for i in cloud_count:
		var cluster := _build_cluster(texture)
		cluster.position = Vector3(
			randf_range(-area_size / 2.0, area_size / 2.0),
			altitude + randf_range(-altitude_variation, altitude_variation),
			randf_range(-area_size / 2.0, area_size / 2.0)
		)
		add_child(cluster)
		_velocities.append(Vector3(wind_speed * randf_range(0.6, 1.0), 0.0, wind_speed * randf_range(-0.2, 0.2)))


func _process(delta: float) -> void:
	for i in get_child_count():
		var cloud := get_child(i)
		cloud.position += _velocities[i] * delta
		var half := area_size / 2.0
		if cloud.position.x > half:
			cloud.position.x = -half
		elif cloud.position.x < -half:
			cloud.position.x = half
		if cloud.position.z > half:
			cloud.position.z = -half
		elif cloud.position.z < -half:
			cloud.position.z = half


func _build_cluster(texture: ImageTexture) -> Node3D:
	var cluster := Node3D.new()
	var puff_count := randi_range(3, 5)
	for i in puff_count:
		var puff := Sprite3D.new()
		puff.texture = texture
		puff.pixel_size = 0.4
		puff.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		puff.shaded = false
		puff.modulate = Color(1, 1, 1, 0.85)
		puff.position = Vector3(randf_range(-8.0, 8.0), randf_range(-2.0, 2.0), randf_range(-8.0, 8.0))
		puff.scale = Vector3.ONE * randf_range(0.8, 1.6)
		cluster.add_child(puff)
	return cluster


func _make_cloud_texture() -> ImageTexture:
	var size := 64
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size / 2.0, size / 2.0)
	var max_dist := size / 2.0
	for y in size:
		for x in size:
			var dist := Vector2(x, y).distance_to(center) / max_dist
			var alpha := clampf(1.0 - dist, 0.0, 1.0)
			alpha = alpha * alpha
			image.set_pixel(x, y, Color(1, 1, 1, alpha))
	return ImageTexture.create_from_image(image)
