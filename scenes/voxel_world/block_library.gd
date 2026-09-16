class_name BlockLibrary
extends RefCounted

# Table des types de blocs du terrain voxel.
#
# Point important, contre-intuitif : chaque bloc porte UNE coordonnee UV, pas
# une region a repeter. La texture KayKit
# (assets/kaykit/block_bits/block_bits_texture.png) n'est pas un atlas de
# matieres carrelables mais une palette de degrades unis. Les 4 coins d'une
# face partagent donc la meme UV, ce qui donne un quad de couleur plate —
# c'est exactement le rendu KayKit, ou le detail visuel vient de la geometrie
# du bloc et non de sa texture (voir issue #30).
#
# Consequence directe : le terrain maille ici et les props KayKit poses
# dessus peuvent partager le meme materiau Godot, donc exactement les memes
# teintes et le meme eclairage.
#
# Les UV ci-dessous sont relevees directement dans les .gltf du pack (lecture
# de l'accesseur TEXCOORD_0 puis echantillonnage de la palette), pas choisies
# a l'oeil : la couleur en commentaire est celle que renvoie l'atlas a cette
# coordonnee.

enum Type {
	AIR = 0,
	GRASS,
	DIRT,
	STONE,
	STONE_DARK,
	SAND,
	GRAVEL,
	SNOW,
}

const PALETTE_PATH := "res://assets/kaykit/block_bits/block_bits_texture.png"

const UV: Dictionary = {
	Type.GRASS: Vector2(0.4822, 0.8141),      # #009959
	Type.DIRT: Vector2(0.6703, 0.2244),       # #9B5A45
	Type.STONE: Vector2(0.3435, 0.2154),      # #5D6468
	Type.STONE_DARK: Vector2(0.4101, 0.2344), # #3C4246
	Type.SAND: Vector2(0.9203, 0.2201),       # #CE9965
	Type.GRAVEL: Vector2(0.2953, 0.2244),     # #596064
	Type.SNOW: Vector2(0.1399, 0.1037),       # #DCE1E4
}

# Repli si un type solide n'a pas d'entree dans UV (ne devrait pas arriver,
# mais mieux vaut un bloc gris qu'un plantage au milieu du maillage).
const FALLBACK_UV := Vector2(0.3435, 0.2154)

# Blocs que le joueur ne peut pas retirer.
#
# STONE_DARK joue le role de la bedrock de Minecraft. La generation en pose
# les DARK_STONE_DEPTH couches du fond de la quille (voir VoxelData), ce qui
# scelle le dessous de l'ile : on ne peut pas la percer de part en part, ni
# se creuser une sortie vers le vide sous ses propres pieds. C'est une
# protection utile sur une plateforme flottante ou tomber est mortel.
const INDESTRUCTIBLE: Array[int] = [Type.STONE_DARK]


static func is_solid(type: int) -> bool:
	return type != Type.AIR


static func is_breakable(type: int) -> bool:
	return is_solid(type) and not INDESTRUCTIBLE.has(type)


static func uv_for(type: int) -> Vector2:
	return UV.get(type, FALLBACK_UV)


# Materiau partage par tous les chunks. Un seul materiau pour tout le terrain
# (et, plus tard, pour les props KayKit) : la palette etant une texture
# unique, il n'y a aucune raison d'en avoir plusieurs.
static func build_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = load(PALETTE_PATH)
	# Le pack KayKit est en aplats : pas de reflet speculaire, tout le relief
	# vient de l'eclairage directionnel sur des faces plates.
	material.metallic = 0.0
	material.roughness = 1.0
	return material
