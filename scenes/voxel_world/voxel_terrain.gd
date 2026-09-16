class_name VoxelTerrain
extends Node3D

# Porte la grille de voxels et materialise un noeud par chunk non vide
# (maillage + collision). C'est ici que se joue la reponse a l'issue #3 :
# creuser ne reconstruit QUE le chunk touche (et ses voisins immediats si le
# voxel etait sur une frontiere), la ou `platform.gd` reconstruit aujourd'hui
# les ~90 000 colonnes de toute l'ile a chaque coup de pioche.

signal generation_progress(done: int, total: int)
signal generation_finished()

@export var size_xz: int = 256
@export var size_y: int = 64
# Le maillage initial est etale sur plusieurs frames : mailler un millier de
# chunks d'un bloc figerait la fenetre plusieurs secondes sans rien afficher.
@export var chunks_per_frame: int = 12

var data: VoxelData

var _material: StandardMaterial3D
var _chunk_nodes: Dictionary = {}
var _pending: Array = []
var _total_chunks: int = 0
var _building := false


func _ready() -> void:
	_material = BlockLibrary.build_material()


func generate(seed_value: int) -> void:
	if _material == null:
		_material = BlockLibrary.build_material()

	for node in _chunk_nodes.values():
		node.queue_free()
	_chunk_nodes.clear()

	data = VoxelData.new(size_xz, size_y)
	data.generate(seed_value)

	_pending = data.solid_chunk_keys()
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
# (une face n'est emise que si le voisin est de l'air), d'ou le passage par
# les 6 voisins pour collecter les chunks a reconstruire.
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
		# Creuser : la bedrock du fond de l'ile ne se retire pas.
		if not BlockLibrary.is_breakable(current):
			return false
	elif BlockLibrary.is_solid(current):
		return false # on ne pose pas un bloc dans un bloc

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


# Point de depart sur le sol, au centre de l'ile. Cherche la surface reelle
# plutot que de supposer une altitude : avec des grottes et un relief, la
# hauteur du sol n'est pas connue d'avance.
func spawn_position(offset: Vector2 = Vector2.ZERO) -> Vector3:
	if data == null:
		return Vector3(float(size_xz) / 2.0, float(size_y), float(size_xz) / 2.0)
	var cx := int(float(size_xz) / 2.0 + offset.x)
	var cz := int(float(size_xz) / 2.0 + offset.y)
	var sy := data.surface_y(cx, cz)
	if sy < 0:
		sy = size_y - 1
	# +1 pour se tenir SUR le bloc de surface, pas dedans.
	return Vector3(float(cx) + 0.5, float(sy) + 1.0, float(cz) + 0.5)


func _build_chunk_node(key: Vector3i) -> void:
	var mesh := VoxelMesher.build_chunk(data, key)

	var existing: Node = _chunk_nodes.get(key)
	if mesh == null:
		# Le chunk n'a plus aucune face visible (entierement creuse, ou
		# entierement enterre) : autant le retirer de l'arbre de scene.
		if existing != null:
			existing.queue_free()
			_chunk_nodes.erase(key)
		return

	var body: StaticBody3D
	if existing != null:
		body = existing
	else:
		body = StaticBody3D.new()
		body.name = "Chunk_%d_%d_%d" % [key.x, key.y, key.z]
		body.position = Vector3(key * VoxelData.CHUNK_SIZE)
		body.add_child(MeshInstance3D.new())
		body.add_child(CollisionShape3D.new())
		add_child(body)
		_chunk_nodes[key] = body

	var mesh_instance: MeshInstance3D = body.get_child(0)
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _material

	# L'enroulement des faces etant correct (verifie par
	# scripts/verify_voxel_winding.gd), la collision trimesh fonctionne du
	# bon cote sans avoir besoin de backface_collision — contrairement au
	# contournement qu'il a fallu mettre dans platform.gd.
	var collision: CollisionShape3D = body.get_child(1)
	collision.shape = mesh.create_trimesh_shape()
