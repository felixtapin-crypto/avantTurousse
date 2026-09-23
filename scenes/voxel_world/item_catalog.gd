class_name ItemCatalog
extends RefCounted

# Catalogue fixe des objets manipulables, sur le meme modele que
# `terrain_materials.gd` (enum + tables paralleles) : le precedent le plus
# proche dans ce code pour "un petit catalogue fixe de choses typees",
# plus adapte ici qu'une ressource `.tres` par objet vu le nombre d'entrees.

enum Id {
	DIRT = 0,
	ROCK = 1,
	BACKPACK = 2,
	BERRY = 3,
}

const NAME := {
	Id.DIRT: "terre",
	Id.ROCK: "caillou",
	Id.BACKPACK: "sac a dos",
	Id.BERRY: "baie",
}

# DIRT reprend exactement l'ancien CARRY_CAPACITY (8, deja calibre par la PR
# #49 : "faible au depart pour que la contrainte se sente") - la
# generalisation ne doit pas rejouer ce reglage. BACKPACK non empilable (1) :
# un objet d'equipement unique, pas une ressource.
const MAX_STACK := {
	Id.DIRT: 8,
	Id.ROCK: 12,
	Id.BACKPACK: 1,
	Id.BERRY: 8,
}

# Pas d'icone : meme convention que `terrain_materials.gd`, un aplat de
# couleur suffit tant qu'on est en mecanique-d'abord. DIRT/ROCK reprennent
# directement la teinte du materiau terrain correspondant, pour qu'un objet
# ramasse se reconnaisse d'un coup d'oeil face a la matiere dont il vient.
const COLOR := {
	Id.DIRT: TerrainMaterials.COLOR[TerrainMaterials.Type.DIRT],
	Id.ROCK: TerrainMaterials.COLOR[TerrainMaterials.Type.STONE],
	Id.BACKPACK: Color(0.55, 0.35, 0.18),
	Id.BERRY: Color(0.62, 0.08, 0.20),
}

# Objets COMESTIBLES : combien de faim ils restaurent (sur 100). Seule la
# baie existe pour l'instant - cueillette sauvage directe, voir DESIGN.md
# ("Flore et faune", "la source de nourriture de base, toujours disponible").
# Le jardinage (semer/arroser/recolter) est un systeme plus large, deja suivi
# a part (issues #20-24/#28) et hors scope de cette passe.
const HUNGER_RESTORE := {
	Id.BERRY: 25.0,
}

# Objets d'EQUIPEMENT : quel emplacement ils occupent une fois equipes, et le
# bonus de cases qu'ils accordent. Un seul emplacement existe pour l'instant
# ("back") - la table est prete a en recevoir d'autres sans etre restructuree.
const EQUIP_SLOT := {
	Id.BACKPACK: "back",
}

# 9 -> 15 cases une fois le sac equipe : sensible sans etre demesure.
const CAPACITY_BONUS := {
	Id.BACKPACK: 6,
}

# Point d'extension NON UTILISE cette version (voir DESIGN.md, jauge de
# charge future - hors scope ici, ticket separe).
const WEIGHT := {
	Id.DIRT: 0.0,
	Id.ROCK: 0.0,
	Id.BACKPACK: 0.0,
}


static func max_stack(item_id: int) -> int:
	return MAX_STACK.get(item_id, 1)


static func display_name(item_id: int) -> String:
	return NAME.get(item_id, "objet inconnu")


static func color(item_id: int) -> Color:
	return COLOR.get(item_id, Color.WHITE)


static func is_equipment(item_id: int) -> bool:
	return EQUIP_SLOT.has(item_id)


static func equip_slot(item_id: int) -> String:
	return EQUIP_SLOT.get(item_id, "")


static func capacity_bonus(item_id: int) -> int:
	return CAPACITY_BONUS.get(item_id, 0)


static func is_food(item_id: int) -> bool:
	return HUNGER_RESTORE.has(item_id)


static func hunger_restore(item_id: int) -> float:
	return HUNGER_RESTORE.get(item_id, 0.0)
