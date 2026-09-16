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

const BOTTOM_Y := -15.0 # jusqu'ou descendent les parois de falaise sur le pourtour

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
	# Une marge minime suffit : le joueur n'est plus "lache" en chute libre
	# ici, sa position finale est fixee explicitement par la cinematique
	# d'arrivee (voir Player._play_arrival_sequence). Une vraie marge de
	# chute n'est plus necessaire et risquait de causer un chevauchement
	# initial avec le sol avant que la physique ne "rattrape" le joueur.
	return Vector3(cx, get_height_at(cx, cz) + 0.05, cz)


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


func _quad_valid(x: int, z: int) -> bool:
	if x < 0 or z < 0 or x >= size - 1 or z >= size - 1:
		return false
	return heights[z * size + x] >= 0.0 \
		and heights[z * size + x + 1] >= 0.0 \
		and heights[(z + 1) * size + x] >= 0.0 \
		and heights[(z + 1) * size + x + 1] >= 0.0


func _add_quad(surface: SurfaceTool, p00: Vector3, p01: Vector3, p10: Vector3, p11: Vector3) -> void:
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


# Paroi verticale entre deux points du bord (haut) et le meme point ramene a
# BOTTOM_Y (bas). Donne du volume a la plateforme la ou elle borde le vide,
# au lieu d'un simple feuillet sans epaisseur.
func _add_wall(surface: SurfaceTool, top_a: Vector3, top_b: Vector3) -> void:
	var bottom_a := Vector3(top_a.x, BOTTOM_Y, top_a.z)
	var bottom_b := Vector3(top_b.x, BOTTOM_Y, top_b.z)

	surface.set_uv(Vector2(0, 0))
	surface.add_vertex(top_a)
	surface.set_uv(Vector2(1, 0))
	surface.add_vertex(top_b)
	surface.set_uv(Vector2(0, 1))
	surface.add_vertex(bottom_a)

	surface.set_uv(Vector2(1, 0))
	surface.add_vertex(top_b)
	surface.set_uv(Vector2(1, 1))
	surface.add_vertex(bottom_b)
	surface.set_uv(Vector2(0, 1))
	surface.add_vertex(bottom_a)


func _build_mesh() -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	for z in range(size - 1):
		for x in range(size - 1):
			if not _quad_valid(x, z):
				continue

			var p00 := Vector3(x, heights[z * size + x], z)
			var p10 := Vector3(x + 1, heights[z * size + x + 1], z)
			var p01 := Vector3(x, heights[(z + 1) * size + x], z + 1)
			var p11 := Vector3(x + 1, heights[(z + 1) * size + x + 1], z + 1)

			_add_quad(surface, p00, p01, p10, p11)

			# paroi de falaise partout ou le voisin est hors-plateforme
			if not _quad_valid(x - 1, z):
				_add_wall(surface, p00, p01)
			if not _quad_valid(x + 1, z):
				_add_wall(surface, p10, p11)
			if not _quad_valid(x, z - 1):
				_add_wall(surface, p00, p10)
			if not _quad_valid(x, z + 1):
				_add_wall(surface, p01, p11)

	surface.generate_normals()
	var array_mesh := surface.commit()

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.35, 0.55, 0.25)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = array_mesh
	mesh_instance.material_override = material
	add_child(mesh_instance)

	# backface_collision=true : la collision fonctionne des les deux faces du
	# maillage, independamment du sens de rotation des triangles. Sans ca, un
	# maillage genere avec le mauvais sens de rotation ne bloque rien quand on
	# marche dessus depuis le dessus - exactement le bug "on passe au travers"
	# rencontre en jeu.
	var trimesh_shape := array_mesh.create_trimesh_shape() as ConcavePolygonShape3D
	trimesh_shape.backface_collision = true

	var collision_shape := CollisionShape3D.new()
	collision_shape.shape = trimesh_shape
	add_child(collision_shape)
