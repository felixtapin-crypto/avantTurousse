class_name Platform
extends StaticBody3D

# Prototype de terrain : une hauteur (heightmap) par colonne, pas encore un
# vrai voxel editable. Suffisant pour "marcher sur une plateforme generee et
# tomber dans le vide sur les bords" ; la vraie grille de voxels (creuser,
# poser des blocs) arrivera a l'etape "Interaction" de la feuille de route
# dans DESIGN.md, et remplacera probablement ce générateur.

@export var size: int = 300          # cote de la plateforme, en metres (1 voxel = 1 m)
@export var base_height: float = 6.0
@export var height_variation: float = 5.0
@export var edge_ratio: float = 0.85 # fraction de size/2 ou commence le rivage

# -1.0 dans ce tableau = pas de terrain a cette colonne (vide, on peut y tomber)
var heights: PackedFloat32Array


func generate(seed_value: int) -> void:
	_build_heightmap(seed_value)
	_build_mesh()


func get_height_at(x: float, z: float) -> float:
	var xi := clampi(int(round(x)), 0, size - 1)
	var zi := clampi(int(round(z)), 0, size - 1)
	return max(heights[zi * size + xi], 0.0)


func get_spawn_position(offset: Vector2 = Vector2.ZERO) -> Vector3:
	var cx := float(size) / 2.0 + offset.x
	var cz := float(size) / 2.0 + offset.y
	return Vector3(cx, get_height_at(cx, cz) + 1.0, cz)


func _build_heightmap(seed_value: int) -> void:
	var height_noise := FastNoiseLite.new()
	height_noise.seed = seed_value
	height_noise.frequency = 0.015
	height_noise.fractal_octaves = 4

	var edge_noise := FastNoiseLite.new()
	edge_noise.seed = seed_value + 1

	heights = PackedFloat32Array()
	heights.resize(size * size)

	var center := float(size) / 2.0
	var base_radius := center * edge_ratio

	for z in size:
		for x in size:
			var dx := float(x) - center
			var dz := float(z) - center
			var dist := sqrt(dx * dx + dz * dz)
			var angle := atan2(dz, dx)
			# fait varier le rayon selon l'angle -> un contour irregulier
			# plutot qu'un disque parfait
			var local_radius := base_radius + edge_noise.get_noise_1d(angle * 12.0) * center * 0.15

			var index := z * size + x
			if dist > local_radius:
				heights[index] = -1.0
				continue

			var raw_height := base_height + height_noise.get_noise_2d(float(x), float(z)) * height_variation
			# rapproche la hauteur de 0 pres du bord -> effet de falaise/rivage
			var edge_falloff := clampf((local_radius - dist) / 6.0, 0.0, 1.0)
			heights[index] = raw_height * edge_falloff


func _build_mesh() -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	for z in range(size - 1):
		for x in range(size - 1):
			var h00 := heights[z * size + x]
			var h10 := heights[z * size + x + 1]
			var h01 := heights[(z + 1) * size + x]
			var h11 := heights[(z + 1) * size + x + 1]
			# si un des 4 coins est hors-plateforme, on ne pose pas de sol ici
			if h00 < 0.0 or h10 < 0.0 or h01 < 0.0 or h11 < 0.0:
				continue

			var p00 := Vector3(x, h00, z)
			var p10 := Vector3(x + 1, h10, z)
			var p01 := Vector3(x, h01, z + 1)
			var p11 := Vector3(x + 1, h11, z + 1)

			surface.set_uv(Vector2(0, 0))
			surface.add_vertex(p00)
			surface.set_uv(Vector2(0, 1))
			surface.add_vertex(p01)
			surface.set_uv(Vector2(1, 0))
			surface.add_vertex(p10)

			surface.set_uv(Vector2(1, 0))
			surface.add_vertex(p10)
			surface.set_uv(Vector2(0, 1))
			surface.add_vertex(p01)
			surface.set_uv(Vector2(1, 1))
			surface.add_vertex(p11)

	surface.generate_normals()
	var array_mesh := surface.commit()

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.35, 0.55, 0.25)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = array_mesh
	mesh_instance.material_override = material
	add_child(mesh_instance)

	var collision_shape := CollisionShape3D.new()
	collision_shape.shape = array_mesh.create_trimesh_shape()
	add_child(collision_shape)
