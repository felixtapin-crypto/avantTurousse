class_name Platform
extends StaticBody3D

# Prototype de terrain : une hauteur (heightmap) par colonne, pas encore une
# vraie grille de voxels en 3 dimensions (pas de grottes/surplombs pour
# l'instant). Suffisant pour "marcher sur une plateforme generee, tomber dans
# le vide sur les bords, et creuser/construire en sculptant la hauteur d'une
# colonne" - une vraie grille 3D (grottes naturelles, structures avec un toit
# separe du sol) reste une etape plus tardive de la feuille de route dans
# DESIGN.md ("Construction").

@export var size: int = 300          # cote de la plateforme, en metres (1 voxel = 1 m)
@export var base_height: float = 6.0
@export var height_variation: float = 5.0
@export var edge_ratio: float = 0.85 # fraction de size/2 ou commence le rivage

const BOTTOM_Y := -15.0 # jusqu'ou descendent les parois de falaise sur le pourtour
const MIN_EDITED_HEIGHT := 0.5  # on ne peut pas creuser jusqu'au vide sous la plateforme
const MAX_EDITED_HEIGHT := 40.0 # limite haute pour eviter les tours infinies

# -1.0 dans ce tableau = pas de terrain a cette colonne (vide, on peut y tomber)
var heights: PackedFloat32Array

# Modifications des joueurs : Vector2i(x,z) -> delta de hauteur (creuser = -1,
# construire = +1, cumulable). Sparse : seules les colonnes touchees y sont.
# C'est ce diff, pas le terrain entier, qui devra etre sauvegarde plus tard
# (voir DESIGN.md, section Sauvegarde).
var column_edits: Dictionary = {}

var _mesh_instance: MeshInstance3D
var _collision_shape: CollisionShape3D


func generate(seed_value: int) -> void:
	_build_heightmap(seed_value)
	_build_mesh()


func get_height_at(x: float, z: float) -> float:
	var xi := clampi(int(round(x)), 0, size - 1)
	var zi := clampi(int(round(z)), 0, size - 1)
	return max(_effective_height(xi, zi), 0.0)


func get_spawn_position(offset: Vector2 = Vector2.ZERO) -> Vector3:
	var cx := float(size) / 2.0 + offset.x
	var cz := float(size) / 2.0 + offset.y
	# Une marge minime suffit : le joueur n'est plus "lache" en chute libre
	# ici, sa position finale est fixee explicitement par la cinematique
	# d'arrivee (voir Player._play_arrival_sequence). Une vraie marge de
	# chute n'est plus necessaire et risquait de causer un chevauchement
	# initial avec le sol avant que la physique ne "rattrape" le joueur.
	return Vector3(cx, get_height_at(cx, cz) + 0.05, cz)


# Creuser (delta=-1) ou construire (delta=+1) sur la colonne la plus proche
# de (x,z). any_peer + call_local : n'importe quel joueur peut declencher un
# changement, applique identiquement chez tout le monde (y compris chez
# l'appelant) - suffisant pour une petite partie coop entre amis, sans
# validation d'autorite stricte pour l'instant.
@rpc("any_peer", "call_local", "reliable")
func request_edit(cx: int, cz: int, delta: int) -> void:
	if cx < 0 or cz < 0 or cx >= size or cz >= size:
		return
	if heights[cz * size + cx] < 0.0:
		return # hors de l'ile, rien a editer ici

	var key := Vector2i(cx, cz)
	column_edits[key] = int(column_edits.get(key, 0)) + delta
	_build_mesh()


func _effective_height(x: int, z: int) -> float:
	var base := heights[z * size + x]
	if base < 0.0:
		return -1.0
	var edit: int = column_edits.get(Vector2i(x, z), 0)
	return clampf(base + float(edit), MIN_EDITED_HEIGHT, MAX_EDITED_HEIGHT)


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


func _quad_valid(effective: PackedFloat32Array, x: int, z: int) -> bool:
	if x < 0 or z < 0 or x >= size - 1 or z >= size - 1:
		return false
	return effective[z * size + x] >= 0.0 \
		and effective[z * size + x + 1] >= 0.0 \
		and effective[(z + 1) * size + x] >= 0.0 \
		and effective[(z + 1) * size + x + 1] >= 0.0


func _add_quad(surface: SurfaceTool, p00: Vector3, p01: Vector3, p10: Vector3, p11: Vector3) -> void:
	# Ordre choisi empiriquement : l'ordre "logique" (p00,p01,p10) donnait un
	# maillage dont la face visible/eclairee etait celle du dessous vue d'en
	# haut. Godot considere donc l'autre sens comme face avant ici.
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


# Reconstruit tout le maillage/collision a partir de heights + column_edits.
# Appele une fois au chargement, puis a chaque fois qu'une case est modifiee
# (voir request_edit). Reconstruire toute la plateforme (~90k colonnes) a
# chaque modification est un choix delibere pour rester simple ici ; si ca
# devient sensible en jeu (latence perceptible a chaque coup de pioche), la
# suite logique est de decouper la plateforme en chunks pour ne reconstruire
# que la zone modifiee (note dans TASKS.md).
func _build_mesh() -> void:
	var effective := PackedFloat32Array()
	effective.resize(size * size)
	for z in size:
		for x in size:
			effective[z * size + x] = _effective_height(x, z)

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	for z in range(size - 1):
		for x in range(size - 1):
			if not _quad_valid(effective, x, z):
				continue

			var p00 := Vector3(x, effective[z * size + x], z)
			var p10 := Vector3(x + 1, effective[z * size + x + 1], z)
			var p01 := Vector3(x, effective[(z + 1) * size + x], z + 1)
			var p11 := Vector3(x + 1, effective[(z + 1) * size + x + 1], z + 1)

			_add_quad(surface, p00, p01, p10, p11)

			# paroi de falaise partout ou le voisin est hors-plateforme
			if not _quad_valid(effective, x - 1, z):
				_add_wall(surface, p00, p01)
			if not _quad_valid(effective, x + 1, z):
				_add_wall(surface, p10, p11)
			if not _quad_valid(effective, x, z - 1):
				_add_wall(surface, p00, p10)
			if not _quad_valid(effective, x, z + 1):
				_add_wall(surface, p01, p11)

	surface.generate_normals()
	var array_mesh := surface.commit()

	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.35, 0.55, 0.25)
		# Les parois de falaise n'ont pas toutes le meme sens de rotation (4
		# orientations differentes generees par le meme code) ; plutot que de
		# determiner le bon sens au cas par cas, on desactive le culling pour
		# garantir que tout reste visible quel que soit le sens des triangles.
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mesh_instance.material_override = material
		add_child(_mesh_instance)
	_mesh_instance.mesh = array_mesh

	# backface_collision=true : la collision fonctionne des les deux faces du
	# maillage, independamment du sens de rotation des triangles. Sans ca, un
	# maillage genere avec le mauvais sens de rotation ne bloque rien quand on
	# marche dessus depuis le dessus - exactement le bug "on passe au travers"
	# rencontre en jeu.
	var trimesh_shape := array_mesh.create_trimesh_shape() as ConcavePolygonShape3D
	trimesh_shape.backface_collision = true

	if _collision_shape == null:
		_collision_shape = CollisionShape3D.new()
		add_child(_collision_shape)
	_collision_shape.shape = trimesh_shape
