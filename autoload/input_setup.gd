extends Node

# Les commandes du jeu : leur liste, leurs touches par defaut, et leur
# reaffectation.
#
# Definies EN CODE plutot que dans `project.godot`, que `TASKS.md` liste parmi
# les fichiers sensibles aux conflits, et ou une liste de touches se relit mal.
#
# ===========================================================================
# TOUT CE QUI SE JOUE AU CLAVIER PASSE PAR ICI
# ===========================================================================
#
# `Maj` et `F` etaient lues en dur dans `voxel_debug_player.gd`
# (`Input.is_key_pressed(KEY_SHIFT)`, `physical_keycode == KEY_F`). Tant qu'une
# seule commande echappe a l'InputMap, l'ecran des parametres ment : il montre
# une touche qu'il ne sait pas changer. Elles ont donc rejoint la table.
#
# Ce qui n'y est PAS, et qui est annonce comme fixe dans l'ecran des
# parametres :
#
# - `Echap`, qui ouvre le menu de pause. C'est aussi `ui_cancel`, la touche dont
#   Godot se sert pour fermer ses propres controles : la reaffecter casserait la
#   sortie de tous les ecrans, y compris celui ou l'on serait en train de la
#   reaffecter.
# - Les gestes de souris (orbite, creusement, zoom), qui ne sont pas des
#   touches et se lisent comme des evenements de bouton.
#
# ===========================================================================
# CODES PHYSIQUES
# ===========================================================================
#
# On enregistre la POSITION de la touche et non le caractere grave dessus, pour
# que le carre de marche reste sous les memes doigts quelle que soit la
# disposition — il se lit ZQSD sur un clavier AZERTY. La reaffectation garde ce
# principe : on retient la position pressee, et l'ecran des parametres la
# retraduit en lettre du clavier branche pour l'afficher.

# Une commande : identifiant d'action, intitule montre au joueur, touche par
# defaut. L'ORDRE EST CELUI DE L'AFFICHAGE.
const ACTIONS: Array[Dictionary] = [
	{"action": "move_forward", "label": "Avancer", "default": KEY_W},
	{"action": "move_back", "label": "Reculer", "default": KEY_S},
	{"action": "move_left", "label": "Pas a gauche", "default": KEY_A},
	{"action": "move_right", "label": "Pas a droite", "default": KEY_D},
	{"action": "jump", "label": "Sauter, ou monter en vol", "default": KEY_SPACE},
	{"action": "sprint", "label": "Courir, ou descendre en vol", "default": KEY_SHIFT},
	{"action": "toggle_fly", "label": "Basculer vol / marche", "default": KEY_F},
	{"action": "toggle_inventory", "label": "Ouvrir/fermer l'inventaire", "default": KEY_I},
	{"action": "consume", "label": "Boire / manger", "default": KEY_E},
]


# Les actions existent des le demarrage, avant la premiere scene : un autoload
# est pret avant elle.
func _ready() -> void:
	apply_saved()


# (Re)pose toutes les touches : celles que le joueur a choisies, les valeurs par
# defaut pour le reste.
func apply_saved() -> void:
	for entry in ACTIONS:
		var action: String = entry["action"]
		_bind(action, int(GameSettings.bindings.get(action, entry["default"])))


# Touche actuellement affectee a une action, en code PHYSIQUE.
func key_of(action: String) -> int:
	if InputMap.has_action(action):
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				return (event as InputEventKey).physical_keycode
	return KEY_NONE


func label_of(action: String) -> String:
	for entry in ACTIONS:
		if entry["action"] == action:
			return entry["label"]
	return action


# Affecte une touche a une commande, EN ECHANGEANT si elle est deja prise.
#
# L'echange plutot que le vol : prendre la touche a son proprietaire le
# laisserait sans aucune, et rien a l'ecran ne dirait laquelle on vient de
# perdre — on s'en apercevrait en jeu, en n'avancant plus. L'echange, lui, est
# toujours defini et se lit sur place : les deux lignes changent en meme temps.
func rebind(action: String, keycode: int) -> void:
	var previous := key_of(action)
	for entry in ACTIONS:
		var other: String = entry["action"]
		if other != action and key_of(other) == keycode:
			_assign(other, previous)
	_assign(action, keycode)
	GameSettings.save()


func reset_defaults() -> void:
	GameSettings.bindings.clear()
	apply_saved()
	GameSettings.save()


func _assign(action: String, keycode: int) -> void:
	_bind(action, keycode)
	GameSettings.bindings[action] = keycode


func _bind(action: String, keycode: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	# Les evenements sont REMPLACES et non ajoutes : sans cela, reaffecter une
	# commande lui laisserait aussi son ancienne touche, et deux commandes
	# repondraient a la meme.
	InputMap.action_erase_events(action)
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	InputMap.action_add_event(action, event)
