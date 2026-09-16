class_name WorldSettings
extends RefCounted

# Reglages choisis dans l'ecran d'apercu et repris par la scene de jeu.
#
# Variables statiques plutot qu'un autoload : un autoload se declare dans
# `project.godot`, que `TASKS.md` liste parmi les fichiers sensibles aux
# conflits, et cette classe ne justifie pas d'y toucher.
#
# Ce n'est PAS une sauvegarde. La seed devra a terme venir d'un fichier de
# partie et, surtout, etre transmise par l'hote au client avant qu'il ne
# genere quoi que ce soit — voir issue #31.

static var seed_value: int = 1
static var size: int = 600
static var height: int = 64

# Identifiant du pack de textures du terrain. "procedural" est celui genere a
# partir de la palette du projet ; les autres sont des dossiers d'images
# deposes sous res://assets/texture_packs (voir texture_packs.gd).
static var texture_pack: String = TexturePacks.PROCEDURAL_ID

# Renseigne quand l'ecran d'apercu a deja calcule cette carte : la scene de
# jeu la reprend telle quelle au lieu de refaire 1,6 s de calcul pour
# retomber exactement sur le meme resultat.
static var prepared_map: WorldMap = null


static func take_map() -> WorldMap:
	var map := prepared_map
	prepared_map = null
	if map != null and map.size_xz == size and map.size_y == height:
		return map
	return null
