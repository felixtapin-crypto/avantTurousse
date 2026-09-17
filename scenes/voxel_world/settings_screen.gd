class_name SettingsScreen
extends Control

# Ecran des parametres.
#
# Il est bati sur la MEME grille que les ecrans d'avant-partie (voir la section
# « Grille de lecture » d'`island_ui.gd`) : enseigne en haut a gauche, retour a
# droite, titre dessous. C'est ce qui permet de l'ouvrir depuis le menu
# d'accueil comme depuis la pause sans que le joueur ait a rechercher la sortie.
#
# C'EST UN CONTROLE ET NON UNE SCENE, et c'est ce qui le rend ouvrable EN
# PARTIE. Changer de scene pour regler une sensibilite de souris demonterait le
# terrain voxel — plusieurs secondes de file de generation a vider a l'aller,
# autant a recalculer au retour. Superpose, il ne coute rien.
#
# Depuis l'accueil, ou rien n'est charge derriere, il est tout de meme ouvert
# comme une vraie scene : `scenes/settings/settings.tscn` l'etend pour cela. Le
# joueur voit le meme ecran dans les deux cas.
#
# Les trois onglets sont ceux demandes. Deux ont du contenu, le troisieme
# annonce son absence : le jeu n'a pas encore de son, et poser un curseur de
# volume qui ne commande rien ferait douter des reglages qui, eux, marchent.

signal closed
# La distance de vue s'applique A CHAUD sur le terrain deja charge. Sans ce
# signal, la changer en partie ne se verrait qu'au monde suivant.
signal view_distance_changed(meters: int)

const TABS := ["Controles", "Affichage", "Audio"]

# --- Respiration ------------------------------------------------------------
#
# CET ECRAN EST UNE LISTE, et une liste serree ne se lit pas : l'oeil ne sait
# plus quelle valeur va avec quel intitule quand les lignes se touchent.
#
# Les ECARTS viennent de l'echelle partagee (`IslandUI.SPACE_*`) et ne sont pas
# redefinis ici — c'est ce qui fait que cet ecran respire comme les autres. Ne
# restent en propre que les deux mesures d'une LIGNE, qui n'existent nulle part
# ailleurs.
const ROW_HEIGHT := 34
const ROW_TEXT := 16

# --- Reaffectation ----------------------------------------------------------

# Intitule montre sur la pastille pendant qu'on attend une touche.
const LISTENING_TEXT := "Appuyez sur une touche"

# Ou mene la pastille de retour, en un mot.
#
# Les ecrans de ce jeu NOMMENT leur destination — « ← Accueil », « ← Retour aux
# mondes ». Un « ← Retour » nu obligerait a se rappeler d'ou l'on vient, et cet
# ecran-ci s'ouvre depuis deux endroits differents.
var back_label := "Retour"

var _tab_buttons: Array[Button] = []
var _panel: VBoxContainer
var _tab := 0

# Commande dont on attend la nouvelle touche, vide sinon.
var _listening := ""
# Pastilles des touches, par action, pour les rafraichir toutes d'un coup —
# une reaffectation en change DEUX quand il y a echange.
var _binding_buttons := {}


func _ready() -> void:
	# Ouvert depuis la pause, il doit vivre PENDANT la pause. Sans effet quand
	# il est ouvert comme scene a part entiere, ou rien n'est en pause.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# BATI A LA PREMIERE OUVERTURE et non au chargement.
	#
	# La scene de jeu le cree en meme temps que le menu de pause, donc a chaque
	# partie ; la plupart des sessions ne l'ouvriront jamais. Le construire
	# d'avance faisait aussi lire le clavier du systeme au demarrage, ce dont un
	# serveur d'affichage sans fenetre — celui des captures et des verifications
	# — est incapable.
	visibility_changed.connect(_ensure_built)
	_ensure_built()


func _ensure_built() -> void:
	if not visible or _panel != null:
		return
	_build()
	_select_tab(0)


func _build() -> void:
	var rows := IslandUI.page(self)
	rows.add_child(IslandUI.header("← %s" % back_label, _close))
	rows.add_child(IslandUI.title("Parametres"))
	rows.add_child(IslandUI.subtitle(
		"Ce qui vous suit d'une partie a l'autre."))
	rows.add_child(IslandUI.gap(IslandUI.SPACE_TIGHT))

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", IslandUI.SPACE_TIGHT)
	for i in TABS.size():
		var index := i
		var button := IslandUI.pill(TABS[i])
		button.custom_minimum_size = Vector2(140, ROW_HEIGHT)
		button.add_theme_font_size_override("font_size", 14)
		button.pressed.connect(func(): _select_tab(index))
		_tab_buttons.append(button)
		tabs.add_child(button)
	tabs.add_child(IslandUI.spacer())
	rows.add_child(tabs)

	rows.add_child(IslandUI.gap(IslandUI.SPACE_GROUP))

	# LE CONTENU D'UN ONGLET PREND TOUTE LA LARGEUR DE LA PAGE.
	#
	# C'est le seul ecran ou la colonne centree serait un contresens : un
	# reglage n'est pas un texte a lire, c'est un intitule a gauche et une
	# valeur a droite, et l'ecart entre les deux est ce qui fait la lisibilite
	# d'un tableau de reglages. Serres dans une colonne de cinq cents pixels,
	# les intitules et leurs valeurs se collent et la liste redevient une
	# bouillie.
	#
	# Deroulable : la liste des touches depasse la fenetre par defaut, et sans
	# cela c'est la PAGE qui prendrait sa hauteur minimale — le defaut qui avait
	# deja fait deborder l'ecran d'apercu.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rows.add_child(scroll)

	# LA BARRE DE DEFILEMENT SE POSE PAR-DESSUS LE CONTENU, elle ne lui prend
	# pas de place. Sans cette marge elle coupe la derniere lettre de chaque
	# valeur — et les valeurs sont justement rangees au bord droit.
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_theme_constant_override("margin_right", 18)
	pad.add_theme_constant_override("margin_bottom", 24)
	scroll.add_child(pad)

	_panel = VBoxContainer.new()
	_panel.add_theme_constant_override("separation", IslandUI.SPACE_SECTION)
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pad.add_child(_panel)


# Echap ferme l'ecran — SAUF pendant l'attente d'une touche, ou elle annule
# cette attente. Ce cas-la est traite dans `_input`, qui passe avant.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()


# CAPTURE D'UNE TOUCHE.
#
# Elle se fait dans `_input` et non dans `_unhandled_input` : la touche pressee
# est peut-etre deja une action du jeu, ou `ui_cancel`, et il faut l'intercepter
# AVANT que qui que ce soit d'autre ne la traite — sans quoi reaffecter
# « Reculer » sur Echap fermerait l'ecran au lieu d'affecter la touche.
#
# Echap n'est pas affectable et sert donc a renoncer. Un clic ailleurs renonce
# aussi : c'est le geste naturel quand on a ouvert une attente par erreur.
func _input(event: InputEvent) -> void:
	if _listening == "" or not visible:
		return

	if event is InputEventMouseButton and event.is_pressed():
		get_viewport().set_input_as_handled()
		_stop_listening()
		return

	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	get_viewport().set_input_as_handled()

	var code := (event as InputEventKey).physical_keycode
	var target := _listening
	_listening = ""
	if code != KEY_ESCAPE:
		InputSetup.rebind(target, code)
	_refresh_bindings()


func _close() -> void:
	GameSettings.save()
	closed.emit()


func _select_tab(index: int) -> void:
	_tab = clampi(index, 0, TABS.size() - 1)
	for i in _tab_buttons.size():
		IslandUI.mark_selected(_tab_buttons[i], i == _tab)

	# Les pastilles de touches disparaissent avec l'onglet : en garder la trace
	# ferait rafraichir des boutons deja liberes a la prochaine reaffectation.
	_listening = ""
	_binding_buttons.clear()
	for child in _panel.get_children():
		_panel.remove_child(child)
		child.queue_free()

	match _tab:
		0:
			_build_controls()
		1:
			_build_display()
		2:
			_build_audio()


# --- Controles --------------------------------------------------------------

func _build_controls() -> void:
	var mouse := _section("SOURIS")
	# Le rappel est nomme avant l'appel plutot que passe en ligne : une lambda de
	# plusieurs lignes glissee au milieu d'une liste d'arguments se relit mal, et
	# se termine sur une virgule que l'analyseur accepte de justesse.
	var set_sensitivity := func(value: float) -> String:
		GameSettings.mouse_sensitivity = value
		return "%.4f" % value
	mouse.add_child(_slider_row(
		"Sensibilite", GameSettings.mouse_sensitivity,
		GameSettings.SENSITIVITY_MIN, GameSettings.SENSITIVITY_MAX, 0.0002,
		set_sensitivity))
	mouse.add_child(_hint(
		"S'applique au mouvement de la souris, qui fait tourner la camera."))

	var keys := _section("TOUCHES  ·  CLIQUEZ POUR REAFFECTER")
	for entry in InputSetup.ACTIONS:
		keys.add_child(_binding_row(entry["action"], entry["label"]))
	keys.add_child(_hint(
		"Si la touche choisie sert deja, les deux commandes l'ECHANGENT : "
		+ "aucune ne se retrouve sans touche. Echap renonce."))
	keys.add_child(IslandUI.gap(IslandUI.SPACE_TIGHT))

	var reset := IslandUI.pill("Retablir les touches par defaut")
	reset.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	reset.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	reset.pressed.connect(func():
		InputSetup.reset_defaults()
		_refresh_bindings())
	keys.add_child(reset)

	var fixed := _section("GESTES FIXES")
	for pair in [
		["Tourner la camera", "Bouton droit maintenu"],
		["Reculer / avancer la camera", "Molette"],
		["Creuser", "Clic gauche"],
		["Ajouter de la matiere", "Maj + clic gauche"],
		["Menu de pause", "Echap"],
	]:
		fixed.add_child(_fixed_row(str(pair[0]), str(pair[1])))
	fixed.add_child(_hint(
		"Les gestes de souris ne se reaffectent pas encore, et Echap ne le fera "
		+ "jamais : c'est aussi la touche dont Godot se sert pour fermer ses "
		+ "propres ecrans, celui-ci compris."))

	_panel.add_child(_hint(
		"Les touches sont retenues par POSITION et non par lettre : sur un "
		+ "clavier AZERTY, le carre de marche reste ZQSD, et c'est la lettre de "
		+ "votre clavier qui s'affiche ci-dessus."))


# Une ligne reaffectable : intitule a gauche, pastille de la touche a droite.
func _binding_row(action: String, label_text: String) -> Control:
	var line := _row(label_text)
	var button := IslandUI.pill(_key_name(InputSetup.key_of(action)))
	button.custom_minimum_size = Vector2(CONTROL_WIDTH, ROW_HEIGHT)
	button.add_theme_font_size_override("font_size", 14)
	button.pressed.connect(func(): _start_listening(action))
	_binding_buttons[action] = button
	line.add_child(button)
	return line


# Une ligne qu'on ne peut pas changer : la valeur est du TEXTE, pas un bouton.
# La difference doit se voir, sinon on clique sur « Clic gauche » en attendant
# qu'il se passe quelque chose.
func _fixed_row(label_text: String, value: String) -> Control:
	var line := _row(label_text)
	var value_label := IslandUI.label(value, ROW_TEXT, Color(IslandUI.GOLD, 0.7))
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value_label.custom_minimum_size = Vector2(CONTROL_WIDTH, 0)
	line.add_child(value_label)
	return line


func _start_listening(action: String) -> void:
	if _listening != "":
		return
	_listening = action
	var button: Button = _binding_buttons[action]
	button.text = LISTENING_TEXT
	IslandUI.mark_selected(button, true)


func _stop_listening() -> void:
	_listening = ""
	_refresh_bindings()


func _refresh_bindings() -> void:
	for action in _binding_buttons:
		var button: Button = _binding_buttons[action]
		if not is_instance_valid(button):
			continue
		button.text = _key_name(InputSetup.key_of(action))
		IslandUI.mark_selected(button, false)


# Nom de la touche TEL QU'IL EST GRAVE sur le clavier branche.
#
# Les affectations retiennent une POSITION (voir `input_setup.gd`). Afficher le
# code brut annoncerait « W » a un joueur qui doit presser « Z ».
static func _key_name(physical: int) -> String:
	if physical == KEY_NONE:
		return "—"
	var code := physical
	# Un serveur d'affichage sans fenetre n'a pas de clavier a interroger, et le
	# demander y remonte une erreur par touche. On retombe alors sur le code
	# physique, qui reste lisible — et la question ne se pose que dans les
	# outils, jamais en jeu.
	if DisplayServer.get_name() != "headless":
		code = DisplayServer.keyboard_get_label_from_physical(physical)
	return OS.get_keycode_string(code)


# --- Affichage --------------------------------------------------------------

func _build_display() -> void:
	var set_fullscreen := func(on: bool) -> void:
		GameSettings.fullscreen = on
		GameSettings.apply_display()

	var set_vsync := func(on: bool) -> void:
		GameSettings.vsync = on
		GameSettings.apply_display()

	var set_view_distance := func(value: float) -> String:
		GameSettings.view_distance = int(value)
		view_distance_changed.emit(GameSettings.view_distance)
		return "%d m" % GameSettings.view_distance

	var window := _section("FENETRE")
	window.add_child(_toggle_row(
		"Plein ecran", GameSettings.fullscreen, set_fullscreen))
	window.add_child(_toggle_row(
		"Synchronisation verticale", GameSettings.vsync, set_vsync))
	window.add_child(_hint(
		"Synchronisation coupee, l'image est plus reactive et se dechire en "
		+ "tournant vite."))

	var world := _section("MONDE")
	world.add_child(_slider_row(
		"Distance de vue", float(GameSettings.view_distance),
		float(GameSettings.VIEW_MIN), float(GameSettings.VIEW_MAX), 16.0,
		set_view_distance))
	world.add_child(_hint(
		"Le nombre de blocs a calculer croit avec le CARRE de cette distance, "
		+ "et le generateur est en GDScript : au-dela de 300 m, quitter une "
		+ "partie attend que la file se vide."))


# --- Audio ------------------------------------------------------------------

func _build_audio() -> void:
	_panel.add_child(IslandUI.label("Pas encore de son", 22, IslandUI.INK))
	_panel.add_child(_hint(
		"Le jeu ne joue aucun son a ce jour : ni pas, ni vent, ni riviere, ni "
		+ "musique. Cet onglet attend qu'il y ait quelque chose a regler — un "
		+ "curseur de volume qui ne commande rien ferait douter des reglages "
		+ "qui, eux, fonctionnent."))


# --- Briques ----------------------------------------------------------------
#
# TOUTES LES LIGNES ONT LA MEME FORME : intitule a gauche, reglage range au
# bord droit. C'est ce qui rend la liste lisible — une colonne de reglages que
# l'oeil descend d'un trait, et un intitule dont on voit tout de suite a quoi il
# se rapporte.
#
# La premiere version mettait l'intitule AU-DESSUS, en petites capitales. Sur
# une page pleine largeur, « PLEIN ECRAN » se retrouvait en haut a gauche et sa
# pastille en bas a droite : l'ecart entre une commande et son propre reglage
# etait alors aussi grand qu'entre deux reglages differents, et plus rien ne
# disait ce qui allait avec quoi. Les petites capitales ne servent plus qu'aux
# titres de SECTION.

# Largeur de la colonne des reglages, au bord droit.
const CONTROL_WIDTH := 206


# Un bloc : son titre de section, puis ses lignes.
func _section(caption: String) -> VBoxContainer:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", IslandUI.SPACE_TIGHT)
	block.add_child(IslandUI.caption(caption))
	_panel.add_child(block)
	return block


func _row(label_text: String) -> HBoxContainer:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", IslandUI.SPACE_GROUP)
	line.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	var name_label := IslandUI.label(
		label_text, ROW_TEXT, Color(IslandUI.INK, 0.72))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(name_label)
	return line


# Une ligne de reglage continu. Le curseur a besoin de LARGEUR, donc c'est lui
# qui pousse et l'intitule qui garde une largeur fixe — l'inverse des autres
# lignes, mais les deux bords restent alignes.
#
# `on_change` renvoie le TEXTE a afficher plutot que de l'ecrire lui-meme : le
# libelle n'existe pas encore quand on construit le rappel, et le faire capturer
# par reference obligerait a une variable intermediaire par ligne.
func _slider_row(label_text: String, value: float, minimum: float,
		maximum: float, step: float, on_change: Callable) -> Control:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", IslandUI.SPACE_GROUP)
	line.custom_minimum_size = Vector2(0, ROW_HEIGHT)

	var name_label := IslandUI.label(
		label_text, ROW_TEXT, Color(IslandUI.INK, 0.72))
	name_label.custom_minimum_size = Vector2(300, 0)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(name_label)

	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(slider)

	var readout := IslandUI.label("", 18, IslandUI.INK)
	readout.custom_minimum_size = Vector2(110, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	readout.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(readout)

	readout.text = str(on_change.call(value))
	slider.value_changed.connect(func(v: float):
		readout.text = str(on_change.call(v)))
	return line


# Une ligne de reglage a deux etats. La pastille DIT son etat plutot que de le
# figurer par une case : « Actif » se lit sans apprentissage, une coche dans un
# carre sombre demande de savoir si le carre est coche.
func _toggle_row(label_text: String, value: bool,
		on_change: Callable) -> Control:
	var line := _row(label_text)
	var button := IslandUI.pill("")
	button.custom_minimum_size = Vector2(CONTROL_WIDTH, ROW_HEIGHT)
	button.add_theme_font_size_override("font_size", 14)
	var state := {"on": value}
	var refresh := func() -> void:
		button.text = "Actif" if state["on"] else "Inactif"
		IslandUI.mark_selected(button, state["on"])
	refresh.call()
	button.pressed.connect(func():
		state["on"] = not state["on"]
		refresh.call()
		on_change.call(state["on"]))
	line.add_child(button)
	return line


func _hint(text: String) -> Label:
	var note := IslandUI.label(text, 14, Color(IslandUI.INK, 0.42))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return note
