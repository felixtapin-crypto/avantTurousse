class_name VoxelTerrain
extends Node3D

# Porte la grille de voxels et materialise un noeud par chunk non vide.
#
# C'est ici que se joue la reponse a l'issue #3 : creuser ne reconstruit QUE
# le chunk touche (et ses voisins immediats si le voxel etait sur une
# frontiere), la ou `platform.gd` reconstruit aujourd'hui les ~90 000
# colonnes de toute l'ile a chaque coup de pioche.
#
# Chaque chunk porte deux maillages : le solide, qui fournit aussi la forme
# de collision, et l'eau, qui n'en a volontairement AUCUNE. C'est ce qui
# fait qu'on ne peut pas marcher sur la mer — on la traverse et on coule
# jusqu'au fond, ou la collision du fond marin reprend la main.

signal generation_progress(done: int, total: int)
signal generation_finished()

@export var size_xz: int = 600
@export var size_y: int = 64
# Le maillage initial est etale sur plusieurs frames : mailler un millier de
# chunks d'un bloc figerait la fenetre plusieurs secondes sans rien afficher.
@export var chunks_per_frame: int = 6

var data: VoxelData

var _material: StandardMaterial3D
var _water_material: StandardMaterial3D
var _chunk_nodes: Dictionary = {}
var _pending: Array = []
var _total_chunks: int = 0
var _building := false


func _ready() -> void:
	_ensure_materials()


func generate(seed_value: int) -> void:
	_ensure_materials()

	for node in _chunk_nodes.values():
		node.queue_free()
	_chunk_nodes.clear()

	data = VoxelData.new(size_xz, size_y)
	data.generate(seed_value)

	_pending = data.used_chunk_keys()
	_total_chunks = _pending.size()
	_building = _total_chunks > 0
	if not _building:
		generation_finished.emit()


func _process(_delta: float) -> void:
	if not _building:
		return
	var budget := chunks_per_frame
	while budget > 0 and not _pending.is_empty():
		_build_chunk_node(_pending.pop_back())
		budget -= 1
	generation_progress.emit(_total_chunks - _pending.size(), _total_chunks)
	if _pending.is_empty():
		_building = false
		generation_finished.emit()


func is_building() -> bool:
	return _building


# Pose ou retire un voxel, puis remaille uniquement ce qui est concerne.
# Un voxel sur une frontiere de chunk influe sur le maillage du chunk voisin
# (une face n'est emise que si le voisin ne la cache pas), d'ou le passage
# par les 6 voisins pour collecter les chunks a reconstruire.
#
# Retourne false si la modification est refusee. C'est ICI que les regles
# sont appliquees, et pas dans le controleur du joueur : cette fonction est
# le passage oblige de toute modification du terrain, et deviendra l'RPC
# reseau. Une regle posee dans le controleur serait contournable par
# n'importe quel autre appelant, y compris un pair distant.
func edit_voxel(x: int, y: int, z: int, type: int) -> bool:
	if data == null or not data.is_inside(x, y, z):
		return false

	var current := data.get_voxel(x, y, z)
	if type == BlockLibrary.Type.AIR:
		# Creuser : ni la bedrock du fond de la carte ni l'eau ne se retirent.
		if not BlockLibrary.is_breakable(current):
			return false
	elif current != BlockLibrary.Type.AIR:
		return false # on ne pose pas un bloc dans un bloc, ni dans l'eau

	data.set_voxel(x, y, z, type)

	var dirty := {data.chunk_of(x, y, z): true}
	for n in VoxelMesher.FACE_NORMALS:
		var nx := x + n.x
		var ny := y + n.y
		var nz := z + n.z
		if data.is_inside(nx, ny, nz):
			dirty[data.chunk_of(nx, ny, nz)] = true

	for key in dirty.keys():
		_build_chunk_node(key)
	return true


func get_voxel(x: int, y: int, z: int) -> int:
	if data == null:
		return BlockLibrary.Type.AIR
	return data.get_voxel(x, y, z)


# Point de depart : la terre ferme la plus proche du centre. On ne peut pas
# simplement prendre le centre de la carte, parce que rien ne garantit qu'il
# soit emerge une fois le relief tire au hasard — et apparaitre au fond de
# la mer serait une premiere impression mediocre.
func spawn_position() -> Vector3:
	if data == null:
		return Vector3(float(size_xz) / 2.0, float(size_y), float(size_xz) / 2.0)

	var center := int(float(size_xz) / 2.0)
	for radius in range(0, size_xz / 2, 2):
		for angle_step in 16:
			var angle := TAU * float(angle_step) / 16.0
			var x := center + int(round(cos(angle) * float(radius)))
			var z := center + int(round(sin(angle) * float(radius)))
			var h := data.terrain_height(x, z)
			if h > VoxelData.SEA_LEVEL:
				# +1 pour se tenir SUR le bloc de surface, pas dedans.
				return Vector3(float(x) + 0.5, float(h) + 1.0, float(z) + 0.5)

	return Vector3(float(center) + 0.5, float(VoxelData.SEA_LEVEL) + 2.0, float(center) + 0.5)


func _ensure_materials() -> void:
	if _material == null:
		_material = BlockLibrary.build_material()
	if _water_material == null:
		_water_material = BlockLibrary.build_water_material()


func _build_chunk_node(key: Vector3i) -> void:
	var meshes := VoxelMesher.build_chunk(data, key)
	var solid_mesh: ArrayMesh = meshes["solid"]
	var water_mesh: ArrayMesh = meshes["water"]

	var body: StaticBody3D = _chunk_nodes.get(key)

	if solid_mesh == null and water_mesh == null:
		# Le chunk n'a plus aucune face visible (entierement creuse, ou
		# entierement enterre) : autant le retirer de l'arbre de scene.
		if body != null:
			body.queue_free()
			_chunk_nodes.erase(key)
		return

	if body == null:
		body = StaticBody3D.new()
		body.name = "Chunk_%d_%d_%d" % [key.x, key.y, key.z]
		body.position = Vector3(key * VoxelData.CHUNK_SIZE)

		var solid_node := MeshInstance3D.new()
		solid_node.name = "Solid"
		solid_node.material_override = _material
		body.add_child(solid_node)

		var water_node := MeshInstance3D.new()
		water_node.name = "Water"
		water_node.material_override = _water_material
		# La mer ne projette pas d'ombre : une surface translucide qui
		# assombrit tout le fond marin sous elle serait a la fois faux et
		# couteux.
		water_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.add_child(water_node)

		body.add_child(CollisionShape3D.new())
		add_child(body)
		_chunk_nodes[key] = body

	var solid_instance: MeshInstance3D = body.get_node("Solid")
	var water_instance: MeshInstance3D = body.get_node("Water")
	solid_instance.mesh = solid_mesh
	water_instance.mesh = water_mesh

	# Collision construite a partir du SEUL maillage solide : l'eau reste
	# traversable. L'enroulement des faces etant correct (verifie par
	# scripts/verify_voxel_rules.gd), la collision trimesh fonctionne du
	# bon cote sans avoir besoin de backface_collision — contrairement au
	# contournement qu'il a fallu mettre dans platform.gd.
	var collision: CollisionShape3D = body.get_child(2)
	collision.shape = solid_mesh.create_trimesh_shape() if solid_mesh != null else null
