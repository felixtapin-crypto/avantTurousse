class_name VoxelMesher
extends RefCounted

# Maillage d'un chunk : on n'emet une face que si le voisin dans cette
# direction est de l'air. C'est ce qui rend le terrain voxel abordable.
#
# Ordre de grandeur, pour situer : instancier les vrais blocs KayKit comme
# voxels couterait ~1 080 triangles par bloc, soit ~55 millions de triangles
# rien que pour la surface de l'ile. Ici une face = 2 triangles, et seules
# les faces exposees sont emises : le meme terrain sort autour de 150 a 300
# mille triangles (voir issue #30).
#
# Les faces interieures ne sont jamais generees du tout, donc la profondeur
# de l'ile (la quille) ne coute rien tant qu'on ne creuse pas dedans.

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
# ci-dessous est verifie par scripts/verify_voxel_winding.gd, qui compare la
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


# Construit le maillage d'un chunk en coordonnees LOCALES (le noeud qui le
# porte est place a l'origine du chunk). Retourne null si le chunk n'a aucune
# face visible — c'est le cas de tout chunk entierement plein ou entierement
# vide, qu'il ne sert alors a rien de materialiser dans l'arbre de scene.
static func build_chunk(data: VoxelData, key: Vector3i) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	var origin := key * VoxelData.CHUNK_SIZE

	for ly in VoxelData.CHUNK_SIZE:
		var y := origin.y + ly
		if y >= data.size_y:
			break
		for lz in VoxelData.CHUNK_SIZE:
			var z := origin.z + lz
			if z >= data.size_xz:
				break
			for lx in VoxelData.CHUNK_SIZE:
				var x := origin.x + lx
				if x >= data.size_xz:
					break

				var type := data.get_voxel(x, y, z)
				if type == BlockLibrary.Type.AIR:
					continue

				var uv := BlockLibrary.uv_for(type)
				var local := Vector3(lx, ly, lz)

				for f in 6:
					var n: Vector3i = FACE_NORMALS[f]
					if BlockLibrary.is_solid(data.get_voxel(x + n.x, y + n.y, z + n.z)):
						continue

					var base := vertices.size()
					var normal := Vector3(n)
					for corner in FACE_CORNERS[f]:
						vertices.append(local + corner)
						normals.append(normal)
						# Les 4 coins partagent la meme UV : la palette KayKit
						# est un nuancier, pas une matiere a repeter, donc le
						# quad ressort en aplat de couleur (voir BlockLibrary).
						uvs.append(uv)

					indices.append(base)
					indices.append(base + 1)
					indices.append(base + 2)
					indices.append(base)
					indices.append(base + 2)
					indices.append(base + 3)

	if indices.is_empty():
		return null

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
