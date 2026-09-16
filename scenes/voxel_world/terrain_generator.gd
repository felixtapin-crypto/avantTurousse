class_name TerrainGenerator
extends VoxelGeneratorScript

# Generateur pour le terrain LISSE (Transvoxel), a comparer avec le rendu en
# blocs de `kaykit_voxel_generator.gd`. Les deux lisent la meme `WorldMap` :
# c'est le meme monde, seule la facon de le representer change.
#
# Trois differences de fond avec le rendu en blocs :
#
# 1. On n'ecrit plus un TYPE par voxel mais une DISTANCE SIGNEE (canal SDF) :
#    negative dans la matiere, positive dans le vide, et le mailleur place la
#    surface la ou elle vaut zero. C'est ce qui permet une pente continue au
#    lieu d'un escalier.
#
# 2. La matiere n'est plus portee par le voxel mais par deux canaux separes,
#    INDICES et WEIGHTS : jusqu'a 4 matieres melangees par voxel, encodees sur
#    4 bits chacune (donc 16 matieres possibles au maximum). Le shader les
#    echantillonne dans un Texture2DArray en projection triplanaire.
#
# 3. L'eau ne peut plus etre un voxel : un volume translucide n'a pas de place
#    dans une surface d'isovaleur unique. Elle devient un plan a hauteur de
#    mer, pose par la scene.
#
# Consequence de conception a ne pas perdre de vue : en lisse, creuser devient
# du sculptage a la sphere, pas du retrait de bloc. `DESIGN.md` demande de
# "poser des voxels/blocs pour batir une cabane" — c'est nettement moins
# naturel ici.

const SDF_CHANNEL := VoxelBuffer.CHANNEL_SDF
const INDICES_CHANNEL := VoxelBuffer.CHANNEL_INDICES
const WEIGHTS_CHANNEL := VoxelBuffer.CHANNEL_WEIGHTS

# Correspondance matiere -> couche du Texture2DArray. Cet ordre est le contrat
# avec le tableau de textures : changer l'un sans l'autre repeint le monde.
enum Layer {
	GRASS = 0,
	DIRT = 1,
	STONE = 2,
	STONE_DARK = 3,
	SAND = 4,
	SAND_PALE = 5,
	GRAVEL = 6,
	SNOW = 7,
}

const LAYER_COUNT := 8

# Epaisseur, en voxels, de la couche de surface.
#
# En terrain lisse elle ne peut PAS faire un seul voxel, contrairement au
# rendu en blocs. La surface ne tombe pas sur une frontiere de voxel : elle
# traverse une cellule de Transvoxel, et la matiere du sommet est prise sur
# les voxels PLEINS de cette cellule. Avec une surface d'un seul voxel, ce
# sont ceux du dessous qui l'emportent — mesure a l'appui, 61 % seulement des
# sommets portaient la bonne matiere, les prairies sortaient en terre et les
# sommets enneiges en roche.
const SURFACE_SKIN := 2

# Noyau du melange de surface, par triplets (dx, dz, poids) en metres.
#
# Il est en ANNEAUX et non en carre plein, et c'est le resultat de deux
# erreurs successives qu'il vaut mieux ne pas refaire.
#
# Un carre 5x5 au pas de DEUX metres quantifiait la transition : les poids ne
# changeaient que tous les deux metres et la limite ressortait en escalier a
# marches carrees — le defaut qu'on voulait effacer, deplace d'une echelle.
#
# Le meme carre au pas d'UN metre reglait les marches mais ne portait plus qu'a
# deux metres. Or la PORTEE commande tout : le shader ne sait faire divaguer
# une limite que la ou les DEUX matieres figurent parmi les quatre emplacements
# du voxel. Au-dela du noyau une seule y figure, et il n'y a plus rien a
# melanger — c'est pourquoi ajouter du bruit au shader ne changeait presque
# rien.
#
# Les anneaux achetent donc SEPT metres de portee au prix du carre : vingt-cinq
# lectures. Ils echantillonnent grossierement au loin, ce qui reintroduirait
# des marches ; c'est le pinceau du shader qui les dissout, et les deux ne
# valent qu'ensemble.
# Quatre anneaux, jusqu'a DIX metres. Les anneaux lointains sont volontairement
# peu ponderes : une matiere a dix metres ne pese que 8 % environ, ce qui ne
# suffit pas a la faire apparaitre par elle-meme. Elle est juste PRESENTE parmi
# les quatre emplacements, et c'est tout ce dont le pinceau a besoin pour la
# faire surgir par plaques — l'elargissement du fondu se joue la, pas dans les
# poids.
const BLEND_KERNEL := [
	0, 0, 10,

	2, 0, 5,   -2, 0, 5,   0, 2, 5,    0, -2, 5,
	1, 1, 5,   1, -1, 5,   -1, 1, 5,   -1, -1, 5,

	4, 0, 3,   -4, 0, 3,   0, 4, 3,    0, -4, 3,
	3, 3, 3,   3, -3, 3,   -3, 3, 3,   -3, -3, 3,

	7, 0, 2,   -7, 0, 2,   0, 7, 2,    0, -7, 2,
	5, 5, 2,   5, -5, 2,   -5, 5, 2,   -5, -5, 2,

	10, 0, 1,  -10, 0, 1,  0, 10, 1,   0, -10, 1,
	7, 7, 1,   7, -7, 1,   -7, 7, 1,   -7, -7, 1,
]

# Les tables sont construites A L'AFFECTATION de la carte, et surtout pas
# paresseusement au premier bloc.
#
# `_generate_block` tourne sur PLUSIEURS THREADS de streaming a la fois. Une
# initialisation paresseuse y est une course : deux threads trouvent la table
# vide en meme temps et la remplissent tous les deux. Le jeu se fermait alors au
# bout de quelques secondes, sans message, avec le code 127 — un plantage franc
# dont rien n'indiquait la provenance.
#
# Ici le setter est appele par la scene, sur le fil principal, avant que le
# moindre bloc ne soit demande.
var map: WorldMap:
	set(value):
		map = value
		if map != null:
			_build_tables()

# Biome -> couche de surface. Le melange fait vingt-cinq lectures par colonne :
# une table evite d'y refaire a chaque fois deux appels de fonction.
var _biome_layer := PackedInt32Array()
# Matiere unique -> le couple (indices, poids) deja encode.
var _single_material: Array[Vector2i] = []


func _get_used_channels_mask() -> int:
	return (1 << SDF_CHANNEL) | (1 << INDICES_CHANNEL) | (1 << WEIGHTS_CHANNEL)


func _generate_block(buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	if map == null:
		return

	# Les canaux de matiere sont sur 16 bits : 4 indices et 4 poids de 4 bits.
	buffer.set_channel_depth(INDICES_CHANNEL, VoxelBuffer.DEPTH_16_BIT)
	buffer.set_channel_depth(WEIGHTS_CHANNEL, VoxelBuffer.DEPTH_16_BIT)

	var step := 1 << lod
	var bs := buffer.get_size()
	var oy := origin_in_voxels.y
	var block_top := oy + bs.y * step

	var heights := map.height_range()

	# Sorties anticipees. En SDF, "loin au-dessus du relief" vaut 1 (vide
	# franc) et "loin en dessous" vaut -1 (matiere franche) : le mailleur n'y
	# trouve aucune surface et ne produit rien.
	if float(oy) > float(heights.y) + 2.0:
		buffer.fill_f(1.0, SDF_CHANNEL)
		return
	if block_top < heights.x - WorldMap.CAVE_MAX_DEPTH:
		buffer.fill_f(-1.0, SDF_CHANNEL)
		_fill_material(buffer, Layer.STONE)
		return

	for z in bs.z:
		var wz := origin_in_voxels.z + z * step
		for x in bs.x:
			var wx := origin_in_voxels.x + x * step

			var ground := map.terrain_height_f(wx, wz)
			var top := map.terrain_height(wx, wz)
			var biome := map.biome_at(wx, wz)
			var strata := map.sub_surface(biome)
			var sub_layer := layer_for(strata.x)
			var sub_depth: int = strata.y
			# Calcule une fois par COLONNE : le melange ne depend que de x et z.
			var surface_mix := _surface_mix(wx, wz)

			for y in bs.y:
				var wy := oy + y * step
				var depth := top - wy

				# Distance au sol, en voxels. C'est une approximation (la
				# vraie distance a une pente est plus courte), mais c'est
				# l'usage courant pour un terrain issu d'une carte de
				# hauteurs, et le mailleur ne lit que le signe et le
				# voisinage du zero.
				var sdf := float(wy) - ground

				# Bedrock : jamais creusee, meme par une grotte.
				if wy >= WorldMap.BEDROCK_DEPTH:
					sdf = maxf(sdf, map.cave_sdf(wx, wy, wz, depth))

				buffer.set_voxel_f(clampf(sdf / 8.0, -1.0, 1.0), x, y, z, SDF_CHANNEL)

				# La couche de surface est testee AVANT la stratification :
				# sans ca, un biome dont le sous-sol est directement de la
				# roche (la neige, par exemple) n'aurait aucune epaisseur de
				# surface et ressortirait en pierre.
				if wy < WorldMap.BEDROCK_DEPTH:
					_set_material(buffer, x, y, z, Layer.STONE_DARK)
				elif depth <= SURFACE_SKIN:
					# Seule la surface est fondue : c'est la seule qu'on voie
					# sans creuser, et sous terre une limite nette entre deux
					# strates est ce qu'on veut lire.
					_set_material_mix(buffer, x, y, z, surface_mix)
				elif depth <= sub_depth:
					_set_material(buffer, x, y, z, sub_layer)
				else:
					_set_material(buffer, x, y, z, Layer.STONE)

	buffer.compress_uniform_channels()


func _fill_material(buffer: VoxelBuffer, layer: int) -> void:
	var mix := _single_material[layer]
	buffer.fill(mix.x, INDICES_CHANNEL)
	buffer.fill(mix.y, WEIGHTS_CHANNEL)


func _set_material(buffer: VoxelBuffer, x: int, y: int, z: int, layer: int) -> void:
	_set_material_mix(buffer, x, y, z, _single_material[layer])


# Complete un jeu de matieres a QUATRE indices DISTINCTS, les emplacements
# ajoutes restant a poids nul.
#
# C'est la regle qu'on ignorait, et elle a coute cher. Les emplacements
# inutilises etaient remplis de zeros — or zero est une vraie couche, l'herbe.
# Une colonne d'herbe pure ecrivait donc (0, 0, 0, 0) : quatre fois la meme
# matiere. Le mailleur, qui renormalise le jeu d'indices en ordre croissant et
# redistribue les poids en consequence, ne sait rien faire d'un ensemble
# degenere : il ressortait le jeu par defaut (0, 1, 2, 3) avec QUATRE POIDS
# NULS, et le shader retombait sur son repli.
#
# DEUX TIERS des sommets de surface etaient dans ce cas. La surface n'etait donc
# pas fondue du tout sur l'essentiel de l'ile, ce qui explique pourquoi elargir
# le noyau puis ajouter un pinceau ne changeait presque rien : le melange etait
# bien calcule, et jete juste apres.
# Le tableau est RENDU, pas modifie sur place : les Packed*Array sont des types
# VALEUR en GDScript, et une modification faite ici serait perdue au retour.
func _pad_to_four(kept: PackedInt32Array) -> PackedInt32Array:
	for layer in LAYER_COUNT:
		if kept.size() >= 4:
			break
		if not kept.has(layer):
			kept.append(layer)
	return kept


func _set_material_mix(buffer: VoxelBuffer, x: int, y: int, z: int, mix: Vector2i) -> void:
	buffer.set_voxel(mix.x, x, y, z, INDICES_CHANNEL)
	buffer.set_voxel(mix.y, x, y, z, WEIGHTS_CHANNEL)


# Melange des matieres de surface autour d'une colonne, sous la forme des deux
# mots de 16 bits qu'attendent les canaux : `x` les quatre indices, `y` les
# quatre poids.
#
# Voir BLEND_KERNEL pour la forme du noyau et les raisons de sa portee.
func _surface_mix(wx: int, wz: int) -> Vector2i:
	var totals := PackedInt32Array()
	totals.resize(LAYER_COUNT)

	for k in range(0, BLEND_KERNEL.size(), 3):
		var layer := _biome_layer[
			map.biome_at(wx + BLEND_KERNEL[k], wz + BLEND_KERNEL[k + 1])]
		totals[layer] += BLEND_KERNEL[k + 2]

	# Les quatre matieres les plus representees : au-dela, le format n'a plus
	# de place. Selection par passes plutot que par tri — il n'y a que huit
	# couches, et un tri coute davantage.
	var kept := PackedInt32Array()
	for _n in 4:
		var best := -1
		for layer in LAYER_COUNT:
			if totals[layer] > 0 and not kept.has(layer):
				if best < 0 or totals[layer] > totals[best]:
					best = layer
		if best < 0:
			break
		kept.append(best)

	kept = _pad_to_four(kept)

	# Ordre CANONIQUE, par indice croissant. C'est indispensable, pas cosmetique
	# : les indices etant lus en `flat`, un triangle applique des poids
	# INTERPOLES au jeu d'indices d'un seul de ses sommets. Deux colonnes
	# voisines qui listeraient les memes matieres dans un ordre different
	# feraient tomber chaque poids sur la mauvaise matiere.
	kept.sort()

	var total := 0
	for layer in kept:
		total += totals[layer]

	var indices := PackedInt32Array([0, 0, 0, 0])
	var weights := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for k in kept.size():
		indices[k] = kept[k]
		weights[k] = float(totals[kept[k]]) / float(maxi(total, 1))

	return Vector2i(
		VoxelTool.vec4i_to_u16_indices(
			Vector4i(indices[0], indices[1], indices[2], indices[3])),
		VoxelTool.color_to_u16_weights(
			Color(weights[0], weights[1], weights[2], weights[3])))


# Construites une fois, a l affectation de la carte : voir la note sur `map`.
#
# `surface_block` et `layer_for` ne dependent que du biome, et `_surface_mix`
# les appellerait vingt-cinq fois par colonne.
func _build_tables() -> void:
	_biome_layer.resize(WorldMap.Biome.size())
	for biome in _biome_layer.size():
		_biome_layer[biome] = layer_for(map.surface_block(biome))

	# Le couple (indices, poids) d'une matiere UNIQUE, pour les huit couches.
	# Meme regle que `_pad_to_four` : les trois emplacements libres recoivent des
	# indices distincts, a poids nul.
	_single_material.clear()
	for layer in LAYER_COUNT:
		var kept := _pad_to_four(PackedInt32Array([layer]))
		kept.sort()
		var weights := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
		for k in 4:
			if kept[k] == layer:
				weights[k] = 1.0
		_single_material.append(Vector2i(
			VoxelTool.vec4i_to_u16_indices(
				Vector4i(kept[0], kept[1], kept[2], kept[3])),
			VoxelTool.color_to_u16_weights(
				Color(weights[0], weights[1], weights[2], weights[3]))))


func layer_for(block_type: int) -> int:
	match block_type:
		TerrainMaterials.Type.GRASS: return Layer.GRASS
		TerrainMaterials.Type.DIRT: return Layer.DIRT
		TerrainMaterials.Type.STONE: return Layer.STONE
		TerrainMaterials.Type.STONE_DARK: return Layer.STONE_DARK
		TerrainMaterials.Type.SAND: return Layer.SAND
		TerrainMaterials.Type.SAND_PALE: return Layer.SAND_PALE
		TerrainMaterials.Type.GRAVEL: return Layer.GRAVEL
		TerrainMaterials.Type.SNOW: return Layer.SNOW
		_: return Layer.STONE
