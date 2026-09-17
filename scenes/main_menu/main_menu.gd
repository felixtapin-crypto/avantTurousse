extends Control

# Premier ecran : seul ou a deux.
#
# Il precede le menu des mondes, et cet ordre n'est pas arbitraire. C'est
# L'HOTE QUI CHOISIT LE MONDE : le client rejoint le sien, il n'a donc rien a
# choisir. Mettre le menu des mondes en premier lui ferait selectionner une
# carte qui serait ecrasee par celle de l'hote a la connexion — un choix qui ne
# sert a rien est pire qu'un choix absent.
#
# D'ou trois chemins :
#
#   Solo      -> menu des mondes -> partie
#   Heberger  -> menu des mondes -> partie, en attendant un joueur
#   Rejoindre -> partie directement, avec le monde recu de l'hote
#
# ===========================================================================
# CE QUI MANQUE ENCORE
# ===========================================================================
#
# La partie n'est PAS synchronisee. La graine traverse le reseau, donc les deux
# joueurs generent la meme ile — c'est gratuit, tout se redérive de la graine —
# mais rien ne transporte encore ni les positions ni le creusement. Voir
# `network.gd` pour ce qui passe le fil aujourd'hui.

const WORLD_MENU := "res://scenes/voxel_world/world_menu.tscn"
const GAME := "res://scenes/voxel_world/smooth_voxel_world.tscn"
const SETTINGS := "res://scenes/settings/settings.tscn"

var _address: LineEdit
var _status: Label
var _solo_button: Button
var _host_button: Button
var _join_button: Button
# Une demande de connexion est-elle en cours ?
#
# Elle peut durer : ENet reessaie un moment avant d'abandonner, et meme une
# fois connecte le client attend que l'hote ait choisi son monde — ce qui ne
# vient pas tant que l'hote reste dans le menu des mondes. Sans sortie, on
# serait pris au piege sur cet ecran.
var _joining := false


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Le plein ecran et la synchronisation verticale sont des reglages de
	# FENETRE : ils ne se relisent nulle part ailleurs, donc c'est ici, sur le
	# premier ecran, qu'ils doivent etre reappliques a chaque lancement.
	GameSettings.apply_display()
	# Toute partie precedente est fermee ici, et pas ailleurs : on revient sur
	# cet ecran par le menu des mondes, qui ne sait rien du reseau.
	Network.leave_game()
	Network.player_connected.connect(_on_player_connected)
	Network.connection_failed.connect(_on_connection_failed)
	Network.server_disconnected.connect(_on_server_disconnected)
	Network.world_received.connect(_on_world_received)
	_build()


# La MEME grille que les deux autres ecrans : enseigne en haut a gauche, titre
# dessous, contenu dans une colonne a gauche.
#
# Une carte centree aurait fait une plus jolie porte d'entree, et elle aurait
# deplace l'oeil a chaque changement d'ecran. Un joueur qui passe d'ici au menu
# des mondes doit retrouver l'enseigne et le titre ou il les a laisses.
#
# Pas de retour en en-tete : c'est le premier ecran, il n'y a rien au-dessus.
func _build() -> void:
	var rows := IslandUI.page(self)
	rows.add_child(IslandUI.header("", Callable()))

	var column := IslandUI.column(460)
	rows.add_child(IslandUI.centered(column))

	column.add_child(IslandUI.title("Avant Tourousse"))
	column.add_child(IslandUI.subtitle(
		"Une ile, deux joueurs, un oeuf de dragon a couver."))
	column.add_child(IslandUI.group_gap())

	_solo_button = IslandUI.action_button("Jouer seul", IslandUI.GOLD)
	_solo_button.pressed.connect(_on_solo_pressed)
	column.add_child(_solo_button)
	column.add_child(IslandUI.group_gap())

	column.add_child(IslandUI.caption("A DEUX"))
	_host_button = IslandUI.action_button("Heberger une partie", IslandUI.LAGOON)
	_host_button.pressed.connect(_on_host_pressed)
	column.add_child(_host_button)

	_address = LineEdit.new()
	_address.placeholder_text = "Adresse de l'hote (127.0.0.1 par defaut)"
	_address.add_theme_color_override("font_color", IslandUI.INK)
	_address.add_theme_color_override("font_placeholder_color",
		Color(IslandUI.INK, 0.35))
	_address.add_theme_stylebox_override("normal",
		IslandUI.flat(Color(IslandUI.INK, 0.07), 4))
	_address.add_theme_stylebox_override("focus",
		IslandUI.flat(Color(IslandUI.LAGOON, 0.20), 4))
	column.add_child(_address)

	_join_button = IslandUI.quiet_action("Rejoindre")
	_join_button.pressed.connect(_on_join_pressed)
	column.add_child(_join_button)

	_status = IslandUI.caption("")
	column.add_child(_status)

	# Parametres et Quitter font une SECTION a part, sous les trois facons de
	# jouer : ce ne sont pas des quatriemes et cinquiemes choix de la meme
	# famille. L'ecart le dit.
	#
	# Les parametres sont ici ET dans le menu de pause. Les regler demandait
	# jusque-la de lancer une partie puis de la mettre en pause — donc de charger
	# un monde entier pour changer une sensibilite de souris. Et c'est le premier
	# ecran qu'on ouvre quand on veut regler l'affichage avant d'entrer.
	#
	# Quitter est un BOUTON et non le rappel « F10 quitter » qu'il remplace : sur
	# les autres ecrans quitter n'est qu'une touche parmi d'autres, mais ici
	# c'est une des choses qu'on vient FAIRE. Un raccourci ne se propose pas, il
	# se sait — il ne rendait donc service qu'a qui le connaissait deja.
	column.add_child(IslandUI.section_gap())
	var settings_button := IslandUI.quiet_action("Parametres")
	settings_button.pressed.connect(_open_settings)
	column.add_child(settings_button)

	var quit_button := IslandUI.quiet_action("Quitter")
	quit_button.pressed.connect(_quit)
	column.add_child(quit_button)


# Les parametres sont une SCENE depuis ici, au meme titre que les autres
# boutons de cette colonne : rien n'est charge derriere l'accueil, donc rien ne
# coute a demonter. En partie, le meme ecran est superpose — voir
# `scenes/settings/settings.gd`, qui explique les deux.
func _open_settings() -> void:
	get_tree().change_scene_to_file(SETTINGS)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed():
		return
	# Pas d'ECHAP ici : il n'y a rien au-dessus de cet ecran, et le faire
	# quitter le jeu en ferait un piege — on l'utilise partout ailleurs pour
	# REMONTER.
	if (event as InputEventKey).keycode == KEY_F10:
		_quit()


func _quit() -> void:
	get_tree().quit()


func _on_solo_pressed() -> void:
	get_tree().change_scene_to_file(WORLD_MENU)


# L'hote passe par le menu des mondes : c'est lui qui choisit la carte, et le
# serveur tourne pendant qu'il la choisit. Un client qui se connecte a ce
# moment-la recevra les reglages, puis la partie quand l'hote y entrera.
func _on_host_pressed() -> void:
	Network.host_game()
	get_tree().change_scene_to_file(WORLD_MENU)


# Le meme bouton demande et annule : tant que la connexion n'a pas abouti, la
# seule chose qu'on puisse vouloir en faire est de renoncer.
func _on_join_pressed() -> void:
	if _joining:
		Network.leave_game()
		_set_joining(false)
		_say("Demande annulee.")
		return

	var address := _address.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	_set_joining(true)
	_say("Connexion a %s..." % address)
	Network.join_game(address)


# Pendant une demande, les autres chemins sont fermes : partir en solo ou
# heberger laisserait un pair a moitie ouvert derriere soi.
func _set_joining(active: bool) -> void:
	_joining = active
	_join_button.text = "Annuler" if active else "Rejoindre"
	_solo_button.disabled = active
	_host_button.disabled = active
	_address.editable = not active


func _on_player_connected(_id: int, _player_name: String) -> void:
	if not multiplayer.is_server():
		# CONNECTE NE VEUT PAS DIRE PRET. On attend les reglages de monde : sans
		# la graine de l'hote, le client genererait une AUTRE ile et les deux
		# joueurs joueraient chacun la sienne sans que rien ne le signale.
		#
		# L'attente reste donc ANNULABLE : l'hote peut rester indefiniment dans
		# son menu des mondes.
		_say("Connecte, en attente du monde de l'hote...")


func _on_world_received() -> void:
	get_tree().change_scene_to_file(GAME)


func _on_connection_failed() -> void:
	_set_joining(false)
	_say("Connexion echouee.")


func _on_server_disconnected() -> void:
	_set_joining(false)
	_say("L'hote a ferme la partie.")


func _say(text: String) -> void:
	_status.text = text
