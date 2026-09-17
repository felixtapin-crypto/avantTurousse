class_name GameSettings
extends RefCounted

# Reglages du JOUEUR, par opposition a `WorldSettings` qui porte les reglages
# d'une partie.
#
# La distinction n'est pas cosmetique : ceux-ci survivent a la partie et se
# retrouvent d'une session a l'autre, ceux-la sont choisis a la composition
# d'une carte et meurent avec elle. Melanger les deux ferait voyager une
# sensibilite de souris dans la RPC qui transporte le monde.
#
# Variables statiques plutot qu'un autoload, pour la meme raison que
# `WorldSettings` : un autoload se declare dans `project.godot`, que `TASKS.md`
# liste parmi les fichiers sensibles aux conflits.
#
# CE QUI EST ICI EST CE QUI EXISTE VRAIMENT. On n'y trouve pas de volume
# sonore : le jeu n'a pas encore un seul son, et un curseur qui ne commande
# rien est pire qu'un reglage absent — il fait douter de tous les autres.

const PATH := "user://settings.cfg"
const SECTION := "jeu"

# Radians par pixel de souris. Valeur de terrain-3d, d'ou vient le rig.
const SENSITIVITY_MIN := 0.0008
const SENSITIVITY_MAX := 0.0060

# Distance de vue en metres. Le plafond reprend l'ancienne valeur du monde
# avant qu'elle ne soit ramenee a 256 — voir la note sur `view_distance` dans
# `smooth_voxel_world.gd` : le nombre de blocs a generer croit avec le CARRE
# de cette distance, et notre generateur est en GDScript.
const VIEW_MIN := 96
const VIEW_MAX := 384

static var mouse_sensitivity := 0.0025
static var view_distance := 256
static var fullscreen := false
static var vsync := true

# Touches reaffectees par le joueur : identifiant d'action -> code PHYSIQUE.
#
# Seules les DIFFERENCES sont gardees. Un fichier qui ne contient rien veut donc
# dire « les touches d'origine », et une commande ajoutee plus tard arrive avec
# sa valeur par defaut chez tout le monde — au lieu d'etre absente d'un fichier
# ecrit avant qu'elle n'existe.
#
# La liste des commandes et leurs defauts vivent dans `autoload/input_setup.gd`,
# pas ici : ce fichier ne fait que retenir des choix.
static var bindings := {}


# Lu au premier acces a la classe, donc avant tout ecran.
static func _static_init() -> void:
	restore()


static func restore() -> void:
	var file := ConfigFile.new()
	if file.load(PATH) != OK:
		return
	mouse_sensitivity = clampf(
		float(file.get_value(SECTION, "mouse_sensitivity", mouse_sensitivity)),
		SENSITIVITY_MIN, SENSITIVITY_MAX)
	view_distance = clampi(
		int(file.get_value(SECTION, "view_distance", view_distance)),
		VIEW_MIN, VIEW_MAX)
	fullscreen = bool(file.get_value(SECTION, "fullscreen", fullscreen))
	vsync = bool(file.get_value(SECTION, "vsync", vsync))
	var saved: Dictionary = file.get_value(SECTION, "bindings", {})
	bindings.clear()
	for action in saved:
		bindings[str(action)] = int(saved[action])


static func save() -> void:
	var file := ConfigFile.new()
	file.set_value(SECTION, "mouse_sensitivity", mouse_sensitivity)
	file.set_value(SECTION, "view_distance", view_distance)
	file.set_value(SECTION, "fullscreen", fullscreen)
	file.set_value(SECTION, "vsync", vsync)
	file.set_value(SECTION, "bindings", bindings)
	file.save(PATH)


# Applique ce qui se regle sur la fenetre elle-meme. A appeler au demarrage et
# a chaque changement : ces deux-la ne se relisent nulle part ailleurs.
static func apply_display() -> void:
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen
		else DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
