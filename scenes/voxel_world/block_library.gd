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
	SAND_PALE,
	GRAVEL,
	SNOW,
	WATER,
}

const PALETTE_PATH := "res://assets/kaykit/block_bits/block_bits_texture.png"

const UV: Dictionary = {
	Type.GRASS: Vector2(0.4822, 0.8141),      # #009959
	Type.DIRT: Vector2(0.6703, 0.2244),       # #9B5A45
	Type.STONE: Vector2(0.3435, 0.2154),      # #5D6468
	Type.STONE_DARK: Vector2(0.4101, 0.2344), # #3C4246
	# Deux sables, pris a deux hauteurs du meme degrade de la palette : le
	# sable de plage est fonce (mouille), celui du desert est pale (sec). Sans
	# cette distinction, une plage et une dune seraient exactement le meme
	# aplat, et la carte perdrait la lecture de ses biomes.
	Type.SAND: Vector2(0.9203, 0.2201),       # #CE9965
	Type.SAND_PALE: Vector2(0.9203, 0.0600),  # #E3BE8E
	Type.GRAVEL: Vector2(0.2953, 0.2244),     # #596064
	Type.SNOW: Vector2(0.1399, 0.1037),       # #DCE1E4
	Type.WATER: Vector2(0.1072, 0.8022),      # #28A1DA
}

# Repli si un type solide n'a pas d'entree dans UV (ne devrait pas arriver,
# mais mieux vaut un bloc gris qu'un plantage au milieu du maillage).
const FALLBACK_UV := Vector2(0.3435, 0.2154)

# Les memes teintes, en Color plutot qu'en coordonnee d'atlas.
#
# Le moteur maison echantillonne la palette par UV ; godot_voxel, lui, colore
# chaque modele de bloc par une propriete `color` que le mailleur repercute
# en couleur de sommet (`VoxelMesherBlocky.TINT_RAW_COLOR`). Aucun atlas
# n'est alors necessaire — ce qui tombe bien, la palette KayKit etant un
# nuancier d'aplats et non une matiere a repeter.
#
# Ces valeurs sont les couleurs que renvoie l'atlas aux UV ci-dessus, pas des
# teintes choisies a l'oeil : les deux moteurs rendent donc le meme monde.
const COLOR: Dictionary = {
	Type.GRASS: Color(0.000, 0.600, 0.349),      # #009959
	Type.DIRT: Color(0.608, 0.353, 0.271),       # #9B5A45
	Type.STONE: Color(0.365, 0.392, 0.408),      # #5D6468
	Type.STONE_DARK: Color(0.235, 0.259, 0.275), # #3C4246
	Type.SAND: Color(0.808, 0.600, 0.396),       # #CE9965
	Type.SAND_PALE: Color(0.890, 0.745, 0.557),  # #E3BE8E
	Type.GRAVEL: Color(0.349, 0.376, 0.392),     # #596064
	Type.SNOW: Color(0.863, 0.882, 0.894),       # #DCE1E4
	Type.WATER: Color(0.157, 0.631, 0.855, 0.62),# #28A1DA, translucide
}

const NAME: Dictionary = {
	Type.AIR: "air",
	Type.GRASS: "grass",
	Type.DIRT: "dirt",
	Type.STONE: "stone",
	Type.STONE_DARK: "bedrock",
	Type.SAND: "sand",
	Type.SAND_PALE: "sand_pale",
	Type.GRAVEL: "gravel",
	Type.SNOW: "snow",
	Type.WATER: "water",
}

# Blocs que le joueur ne peut pas retirer.
#
# STONE_DARK joue le role de la bedrock de Minecraft. La generation en pose
# les BEDROCK_DEPTH couches du fond de la carte (voir VoxelData), ce qui
# scelle le bas du monde : on ne peut pas le percer de part en part, et les
# grottes ne le traversent pas non plus.
const INDESTRUCTIBLE: Array[int] = [Type.STONE_DARK]


static func is_solid(type: int) -> bool:
	return type != Type.AIR and type != Type.WATER


static func is_liquid(type: int) -> bool:
	return type == Type.WATER


# Un bloc transparent ne cache pas son voisin : une face solide doit etre
# emise face a de l'air ET face a de l'eau, sinon le fond marin serait
# invisible des qu'on regarde dedans. L'eau, elle, ne s'emet que face a
# l'air (voir VoxelMesher) : sans ca, chaque voxel d'eau dessinerait ses
# faces internes contre ses voisins d'eau.
static func is_transparent(type: int) -> bool:
	return type == Type.AIR or type == Type.WATER


static func is_breakable(type: int) -> bool:
	if not is_solid(type):
		return false # ni l'air ni l'eau ne se creusent
	return not INDESTRUCTIBLE.has(type)


static func uv_for(type: int) -> Vector2:
	return UV.get(type, FALLBACK_UV)


# Materiau du terrain. Un seul materiau pour tous les chunks (et, plus tard,
# pour les props KayKit) : la palette etant une texture unique, il n'y a
# aucune raison d'en avoir plusieurs.
static func build_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = load(PALETTE_PATH)
	# Le pack KayKit est en aplats : pas de reflet speculaire, tout le relief
	# vient de l'eclairage directionnel sur des faces plates.
	material.metallic = 0.0
	material.roughness = 1.0
	return material


# Materiau de la mer, separe du terrain pour trois raisons : il est
# translucide, il ne doit pas etre occulte par le tri de transparence du
# terrain opaque, et il est rendu des deux cotes — seule la face du dessus
# est generee, donc sans CULL_DISABLED la surface disparait vue de dessous.
static func build_water_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_texture = load(PALETTE_PATH)
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.62)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.metallic = 0.0
	material.roughness = 0.15
	return material
