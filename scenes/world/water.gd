class_name Water
extends Node3D

# Genere des mares/etangs la ou le terrain descend naturellement sous
# water_level, plutot que de placer des points d'eau a la main : coherent
# avec une plateforme generee differemment a chaque partie. Base uniquement
# sur les hauteurs de base de Platform (pas les modifications des joueurs) -
# creuser un trou assez profond pour former une nouvelle mare est une
# evolution possible, pas geree pour l'instant.

@export var water_level: float = 3.5

var platform: Platform


func generate(platform_ref: Platform) -> void:
	platform = platform_ref
	var size := platform.size

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	var any := false
	for z in range(size - 1):
		for x in range(size - 1):
			if not _quad_underwater(x, z):
				continue
			any = true

			var p00 := Vector3(x, water_level, z)
			var p10 := Vector3(x + 1, water_level, z)
			var p01 := Vector3(x, water_level, z + 1)
			var p11 := Vector3(x + 1, water_level, z + 1)

			surface.set_uv(Vector2(0, 0))
			surface.add_vertex(p00)
			surface.set_uv(Vector2(1, 0))
			surface.add_vertex(p10)
			surface.set_uv(Vector2(0, 1))
			surface.add_vertex(p01)

			surface.set_uv(Vector2(1, 0))
			surface.add_vertex(p10)
			surface.set_uv(Vector2(1, 1))
			surface.add_vertex(p11)
			surface.set_uv(Vector2(0, 1))
			surface.add_vertex(p01)

	if not any:
		return

	surface.generate_normals()
	var mesh := surface.commit()

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.15, 0.4, 0.6, 0.55)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.material_override = material
	add_child(mesh_instance)


# Vrai si (x,z) est au-dessus d'une colonne recouverte d'eau - sert a boire,
# remplir un seau (plus tard), et eviter de planter des arbres/plantes dedans.
func is_water_at(x: float, z: float) -> bool:
	var xi := clampi(int(round(x)), 0, platform.size - 1)
	var zi := clampi(int(round(z)), 0, platform.size - 1)
	if not platform.is_land(xi, zi):
		return false
	return platform.heights[zi * platform.size + xi] < water_level


const _CORNER_OFFSETS: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]


func _quad_underwater(x: int, z: int) -> bool:
	for offset in _CORNER_OFFSETS:
		var cx: int = x + offset.x
		var cz: int = z + offset.y
		if not platform.is_land(cx, cz):
			return false
		if platform.heights[cz * platform.size + cx] >= water_level:
			return false
	return true
