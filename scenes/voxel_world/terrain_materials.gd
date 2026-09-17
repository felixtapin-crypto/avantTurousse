class_name TerrainMaterials
extends RefCounted

# Matieres du terrain : la liste des natures de sol que la generation sait
# produire, et la teinte de chacune.
#
# Les couleurs viennent du pack KayKit Block Bits, dont on a releve la palette
# avant d'abandonner le rendu en blocs (voir issue #30). Le pack lui-meme
# n'est plus dans le depot — le terrain est lisse, donc il n'a plus de blocs a
# instancier — mais sa gamme reste une bonne direction artistique : des aplats
# franches et lisibles, qui se distinguent d'un coup d'oeil sur une carte
# comme sur le terrain.
#
# Ces teintes servent aujourd'hui a deux choses : les textures bouchons du
# terrain lisse (`smooth_texture_array.gd`) et la carte d'apercu. Elles
# deviendront les couleurs de reference a respecter le jour ou de vraies
# matieres carrelables les remplaceront.

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

const COLOR: Dictionary = {
	Type.GRASS: Color(0.000, 0.600, 0.349),       # #009959
	Type.DIRT: Color(0.608, 0.353, 0.271),        # #9B5A45
	Type.STONE: Color(0.365, 0.392, 0.408),       # #5D6468
	Type.STONE_DARK: Color(0.235, 0.259, 0.275),  # #3C4246
	# Deux sables : celui des plages est fonce (mouille), celui du desert est
	# pale (sec). Sans cette distinction, une dune et un rivage seraient
	# exactement la meme matiere.
	Type.SAND: Color(0.808, 0.600, 0.396),        # #CE9965
	Type.SAND_PALE: Color(0.890, 0.745, 0.557),   # #E3BE8E
	Type.GRAVEL: Color(0.349, 0.376, 0.392),      # #596064
	Type.SNOW: Color(0.863, 0.882, 0.894),        # #DCE1E4
	Type.WATER: Color(0.157, 0.631, 0.855, 0.62), # #28A1DA, translucide
}

const NAME: Dictionary = {
	Type.AIR: "air",
	Type.GRASS: "herbe",
	Type.DIRT: "terre",
	Type.STONE: "roche",
	Type.STONE_DARK: "roche sombre",
	Type.SAND: "sable humide",
	Type.SAND_PALE: "sable sec",
	Type.GRAVEL: "gravier",
	Type.SNOW: "neige",
	Type.WATER: "eau",
}


static func is_solid(type: int) -> bool:
	return type != Type.AIR and type != Type.WATER
