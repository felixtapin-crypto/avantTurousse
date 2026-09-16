extends Control

# Menu des mondes : le premier ecran du jeu.
#
# Il montre les cartes deja calculees et permet d'en reprendre une d'un clic,
# ou d'en composer une nouvelle — auquel cas on passe a l'ecran d'apercu.
#
# Il existe parce qu'une carte coute cher : pres de quatre secondes pour 800 de
# cote. Le cache les gardait deja, mais rien ne les montrait : il fallait
# retrouver la seed de memoire et la ressaisir pour retomber sur un monde qu'on
# avait aime. Les vignettes sont ecrites au moment de la mise en cache, donc
# cet ecran n'ouvre aucune carte pour s'afficher.
#
# Le vocabulaire visuel vient de `IslandUI`, partage avec l'ecran d'apercu :
# deux ecrans qui se suivent ne supportent pas la moindre derive de style.

const PREVIEW_SCENE := "res://scenes/voxel_world/map_preview.tscn"
const WORLD_SCENE := "res://scenes/voxel_world/smooth_voxel_world.tscn"

const CARD_SIZE := Vector2(210, 210)
const COLUMNS := 4

var _grid: GridContainer
var _empty_note: Label
var _stale_note: Label


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		if (event as InputEventKey).keycode == KEY_F10:
			get_tree().quit()


func _ready() -> void:
	# Revenir ici depuis une partie laisserait la carte preparee en memoire :
	# on repart d'une page blanche, chaque vignette portant deja ses reglages.
	WorldSettings.prepared_map = null
	_build_ui()
	_refresh()


func _build_ui() -> void:
	add_child(IslandUI.backdrop())

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 36)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	margin.add_child(column)

	column.add_child(IslandUI.label("AVANT TOUROUSSE", 30, IslandUI.INK))
	column.add_child(IslandUI.label(
		"Une ile, deux naufrages, et tout a reapprendre.", 14, Color(IslandUI.INK, 0.55)))
	column.add_child(IslandUI.gap(6))
	column.add_child(IslandUI.caption("MONDES DEJA EXPLORES"))

	var frame := IslandUI.frame()
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(frame)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	frame.add_child(scroll)

	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", 14)
	_grid.add_theme_constant_override("v_separation", 14)
	scroll.add_child(_grid)

	_empty_note = IslandUI.label(
		"Aucun monde en memoire. Composez-en un.", 14, Color(IslandUI.INK, 0.45))
	column.add_child(_empty_note)

	_stale_note = IslandUI.label("", 12, Color(IslandUI.CORAL, 0.75))
	column.add_child(_stale_note)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)

	var new_map := IslandUI.action_button("Nouvelle carte", IslandUI.GOLD)
	new_map.size_flags_stretch_ratio = 1.6
	new_map.pressed.connect(func(): get_tree().change_scene_to_file(PREVIEW_SCENE))
	actions.add_child(new_map)

	var quit := IslandUI.action_button("Quitter", IslandUI.CORAL)
	quit.pressed.connect(func(): get_tree().quit())
	actions.add_child(quit)

	column.add_child(actions)


func _refresh() -> void:
	for child in _grid.get_children():
		child.queue_free()

	var entries := MapCache.entries()
	var stale := 0
	for entry in entries:
		if bool(entry["current"]):
			_grid.add_child(_build_card(entry))
		else:
			stale += 1

	_empty_note.visible = _grid.get_child_count() == 0
	# Une entree perimee ne peut plus etre relue : l'empreinte des reglages a
	# change depuis. La compter plutot que l'ignorer evite de se demander ou est
	# passee une carte qu'on sait avoir generee.
	_stale_note.visible = stale > 0
	_stale_note.text = ("%d carte(s) mise(s) de cote : les reglages de generation "
		+ "ont change depuis.") % stale


# Une carte : sa vignette, et ses parametres poses par-dessus.
#
# L'incrustation plutot qu'un bandeau separe : le rendu des biomes est sombre
# en bas (mer profonde), donc du texte clair y tient sans voile appuye, et la
# vignette garde toute sa surface.
func _build_card(entry: Dictionary) -> Control:
	var button := Button.new()
	button.custom_minimum_size = CARD_SIZE
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_stylebox_override("normal", IslandUI.flat(IslandUI.BG_SOFT, 5))
	button.add_theme_stylebox_override("hover", IslandUI.flat(Color(IslandUI.LAGOON, 0.30), 5))
	button.add_theme_stylebox_override("pressed", IslandUI.flat(Color(IslandUI.LAGOON, 0.45), 5))
	button.pressed.connect(func(): _open(entry))

	var texture := TextureRect.new()
	texture.texture = MapCache.thumbnail(entry)
	texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	texture.set_anchors_preset(Control.PRESET_FULL_RECT)
	texture.offset_left = 5
	texture.offset_top = 5
	texture.offset_right = -5
	texture.offset_bottom = -5
	texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(texture)

	# Voile du bas : la seed doit rester lisible meme sur une cote claire.
	var veil := ColorRect.new()
	veil.color = Color(IslandUI.BG, 0.72)
	veil.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	veil.offset_left = 5
	veil.offset_right = -5
	veil.offset_top = -46
	veil.offset_bottom = -5
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(veil)

	var text := VBoxContainer.new()
	text.add_theme_constant_override("separation", 0)
	text.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	text.offset_left = 13
	text.offset_right = -13
	text.offset_top = -42
	text.offset_bottom = -9
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(IslandUI.label("seed %d" % int(entry["seed"]), 17, IslandUI.INK))
	text.add_child(IslandUI.label(
		"%d x %d m" % [int(entry["size"]), int(entry["size"])],
		12, Color(IslandUI.INK, 0.55)))
	button.add_child(text)

	return button


# Reprendre un monde : on passe par l'ecran d'apercu plutot que d'entrer
# directement en jeu.
#
# C'est lui qui porte les reglages de rythme — duree du jour, heure de depart —
# lesquels ne sont PAS dans le nom du fichier de cache et n'ont donc pas leur
# place sur une vignette. La carte etant en cache, l'apercu s'affiche d'un
# coup : le detour ne coute rien et laisse le choix.
func _open(entry: Dictionary) -> void:
	WorldSettings.seed_value = int(entry["seed"])
	WorldSettings.size = int(entry["size"])
	get_tree().change_scene_to_file(PREVIEW_SCENE)
