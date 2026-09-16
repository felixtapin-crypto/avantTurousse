class_name VoxelMesher
extends RefCounted

# Maillage d'un chunk : on n'emet une face que si le voisin dans cette
# direction ne la cache pas. C'est ce qui rend le terrain voxel abordable.
#
# Ordre de grandeur, pour situer : instancier les vrais blocs KayKit comme
# voxels couterait ~1 080 triangles par bloc, soit des dizaines de millions
# de triangles pour la seule surface de l'ile. Ici une face = 2 triangles, et
# seules les faces exposees sont emises (voir issue #30).
#
# Le chunk produit DEUX maillages separes :
#
# - le solide, opaque, qui sert aussi de forme de collision ;
# - l'eau, translucide et SANS collision, pour qu'on ne puisse pas marcher
#   dessus.
#
# Les regles d'occultation different entre les deux. Une face solide est
# emise face a de l'air comme face a de l'eau (sinon le fond marin
# disparaitrait des qu'on le regarde a travers la mer), tandis qu'une face
# d'eau n'est emise que face a de l'air : sans ca chaque voxel d'eau
# dessinerait ses faces internes contre ses voisins, et la mer deviendrait
# une soupe de quads translucides superposes.

const FACE_NORMALS: Array[Vector3i] = [
	Vector3i(0, 1, 0),
	Vector3i(0, -1, 0),
	Vector3i(1, 0, 0),
	Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1),
	Vector3i(0, 0, -1),
]

# Les 4 coins de chaque face, dans l'ordre horaire vu de l'exterieur du bloc.
# Godot considere l'enroulement HORAIRE comme la face avant : se tromper de
# sens rend le terrain invisible depuis le dessus et non-collisionnant, ce
# qui est exactement le bug rencontre deux fois sur platform.gd. L'ordre
# ci-dessous est verifie par scripts/verify_voxel_rules.gd, qui compare la
# normale geometrique deduite de l'enroulement a la normale sortante
# attendue, pour les 6 faces.
const FACE_CORNERS: Array = [
	[Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)], # +Y
	[Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 0)], # -Y
	[Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)], # +X
	[Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(0, 0, 1)], # -X
	[Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 0, 1)], # +Z
	[Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)], # -Z
]

# La surface de la mer est abaissee d'un cheveu sous le haut du voxel : sans
# ca elle est exactement coplanaire avec le bord des blocs de plage qui la
# bordent, et les deux se disputent le meme plan de profondeur (z-fighting).
const WATER_SURFACE_DROP := 0.12

# Cote du cache local : le chunk plus un voxel de bordure de chaque cote.
# Cette bordure evite de retourner interroger la grille globale pour les
# voisins situes dans le chunk d'a cote.
const BORDER := VoxelData.CHUNK_SIZE + 2

# Decalages d'index dans le cache pour chacune des 6 directions, dans le meme
# ordre que FACE_NORMALS. L'index vaut (y * BORDER + z) * BORDER + x, donc
# avancer d'un voxel en Y vaut BORDER^2, en Z vaut BORDER, en X vaut 1.
const FACE_OFFSETS: Array[int] = [
	BORDER * BORDER,
	-BORDER * BORDER,
	1,
	-1,
	BORDER,
	-BORDER,
]


# Construit les maillages d'un chunk, en coordonnees LOCALES (le noeud qui
# les porte est place a l'origine du chunk). Retourne un dictionnaire
# {"solid": ArrayMesh|null, "water": ArrayMesh|null} ; une entree vaut null
# quand le chunk n'a aucune face de ce type, ce qui est le cas courant (un
# chunk enterre n'a rien de visible, un chunk de pleine mer n'a pas de
# solide).
static func build_chunk(data: VoxelData, key: Vector3i) -> Dictionary:
	var solid := _new_buffers()
	var water := _new_buffers()

	var origin := key * VoxelData.CHUNK_SIZE
	var cache := _load_cache(data, origin)

	for ly in VoxelData.CHUNK_SIZE:
		for lz in VoxelData.CHUNK_SIZE:
			# Index du premier voxel de la rangee dans le cache, bordure
			# comprise (d'ou les +1).
			var row := ((ly + 1) * BORDER + (lz + 1)) * BORDER + 1
			for lx in VoxelData.CHUNK_SIZE:
				var index := row + lx
				var type := cache[index]
				if type == BlockLibrary.Type.AIR:
					continue

				var liquid := BlockLibrary.is_liquid(type)
				var buffers: Dictionary = water if liquid else solid
				var uv := BlockLibrary.uv_for(type)
				var local := Vector3(lx, ly, lz)

				for f in 6:
					var neighbour := cache[index + FACE_OFFSETS[f]]

					if liquid:
						# L'eau ne se dessine que contre l'air.
						if neighbour != BlockLibrary.Type.AIR:
							continue
					else:
						# Le solide se dessine contre l'air et contre l'eau.
						if not BlockLibrary.is_transparent(neighbour):
							continue

					var drop := 0.0
					if liquid and f == 0: # face du dessus
						drop = WATER_SURFACE_DROP
					_add_face(buffers, local, f, uv, drop)

	return {
		"solid": _commit(solid),
		"water": _commit(water),
	}


# Recopie le chunk et sa bordure dans un tampon plat.
#
# Sans ce cache, le mailleur fait 6 appels a get_voxel par voxel, soit une
# vingtaine de millions d'appels de fonction pour une carte de 300 — et en
# GDScript c'est l'appel lui-meme qui coute, pas le calcul. Avec, les voisins
# se lisent par simple indexation, et le remplissage se fait par rangees
# contigues en memoire.
static func _load_cache(data: VoxelData, origin: Vector3i) -> PackedByteArray:
	var cache := PackedByteArray()
	for cy in BORDER:
		for cz in BORDER:
			cache.append_array(data.copy_row(
				origin.y + cy - 1,
				origin.z + cz - 1,
				origin.x - 1,
				BORDER))
	return cache


# Les tampons d'accumulation sont des Array ordinaires, PAS des Packed*Array,
# et ce n'est pas un detail : les Packed*Array sont des types VALEUR en
# copie-sur-ecriture. Les ranger dans un dictionnaire puis les reassigner
# apres chaque face recopierait l'integralite du tampon a chaque quad, donc
# un cout quadratique en nombre de faces. Un Array est une reference : on le
# remplit en place, et la conversion en Packed*Array n'a lieu qu'une fois,
# au moment de produire le maillage.
static func _new_buffers() -> Dictionary:
	return {
		"vertices": [],
		"normals": [],
		"uvs": [],
		"indices": [],
	}


static func _add_face(buffers: Dictionary, local: Vector3, face: int, uv: Vector2, drop: float) -> void:
	var vertices: Array = buffers["vertices"]
	var normals: Array = buffers["normals"]
	var uvs: Array = buffers["uvs"]
	var indices: Array = buffers["indices"]

	var base := vertices.size()
	var normal := Vector3(FACE_NORMALS[face])

	for corner in FACE_CORNERS[face]:
		var vertex: Vector3 = local + corner
		vertex.y -= drop
		vertices.append(vertex)
		normals.append(normal)
		# Les 4 coins partagent la meme UV : la palette KayKit est un
		# nuancier, pas une matiere a repeter, donc le quad ressort en aplat
		# de couleur (voir BlockLibrary).
		uvs.append(uv)

	indices.append(base)
	indices.append(base + 1)
	indices.append(base + 2)
	indices.append(base)
	indices.append(base + 2)
	indices.append(base + 3)


static func _commit(buffers: Dictionary) -> ArrayMesh:
	var indices: Array = buffers["indices"]
	if indices.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(buffers["vertices"])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(buffers["normals"])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(buffers["uvs"])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(indices)

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
