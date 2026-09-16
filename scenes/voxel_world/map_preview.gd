extends Control

# Ecran de generation du monde, avant la partie.
#
# Le but n'est pas decoratif. Toute la generation a ete calibree a l'aveugle,
# en comptant des colonnes dans un script de verification : c'est comme ca
# qu'on a decouvert que le desert etait litteralement impossible (temperature
# et humidite anti-correlees) et que la neige ne sortait jamais. Un rendu 2D
# des champs rend ces reglages VISIBLES, et permet de juger une seed avant d'y
# passer une partie — ce que reclame le pilier "chaque partie est differente"
# de DESIGN.md.
#
# L'interface est construite EN CODE plutot qu'en .tscn. Deux raisons : le
# style repose sur des StyleBox et des opacites graduees, penibles a relire
# dans un fichier de scene ; et les barres de biomes sont produites a partir
# des donnees, donc leur nombre n'est pas connu d'avance.

const RENDER = preload("res://scenes/voxel_world/map_render.gd")

# Palette : nuit oceanique, encre parcheminee, or de sable, lagon. On evite le
# gris neutre, qui ferait outil de debug plutot qu'ecran de jeu.
const BG := Color("#0b1a1f")
const BG_SOFT := Color("#122a31")
const INK := Color("#f0e6d2")
const GOLD := Color("#e0a542")
const LAGOON := Color("#4fb3a5")
const CORAL := Color("#e2725b")

const SIZES := [300, 450, 600, 800]

# Duree d'un cycle complet, en secondes reelles. DESIGN.md proposait 15 a 20
# minutes ; les valeurs courtes servent a voir un lever et un coucher sans
# attendre, pendant la mise au point.
const DAY_LENGTHS := [120.0, 300.0, 900.0, 1800.0]
const DAY_LABELS := ["2 min", "5 min", "15 min", "30 min"]

const START_HOURS := [0.26, 0.50, 0.76, 0.95]
const HOUR_LABELS := ["Aube", "Midi", "Couchant", "Nuit"]

var _map: WorldMap
var _layer := 0
var _busy := false

var _preview: TextureRect
var _legend: RichTextLabel
var _status: Label
var _seed_edit: LineEdit
var _land_value: Label
var _flat_value: Label
var _layer_buttons: Array[Button] = []
var _size_buttons: Array[Button] = []
var _day_buttons: Array[Button] = []
var _hour_buttons: Array[Button] = []
var _biome_rows: VBoxContainer
var _play_button: Button
var _cache_label: Label


# F10 ferme le jeu depuis l ecran de carte aussi : c est le premier ecran, donc
# celui ou l on se trouve quand on veut simplement partir.
#
# Pas sur Echap : la saisie de graine est un LineEdit, et Echap y est le geste
# courant pour abandonner une saisie.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		if (event as InputEventKey).keycode == KEY_F10:
			get_tree().quit()


func _ready() -> void:
	_build_ui()
	_regenerate()


# --- Construction de l'interface ------------------------------------------

func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = BG
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 28)
	margin.add_child(columns)

	columns.add_child(_build_map_column())
	columns.add_child(_build_side_column())


func _build_map_column() -> Control:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 14)

	var header := HBoxContainer.new()
	header.add_child(_label("AVANT TOUROUSSE", 13, Color(INK, 0.45)))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_status = _label("", 13, Color(LAGOON, 0.9))
	header.add_child(_status)
	column.add_child(header)

	# La carte est encadree d'un liseré discret : elle doit se lire comme une
	# piece posee sur la table, pas comme un widget colle au fond.
	var frame := PanelContainer.new()
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = BG_SOFT
	frame_style.set_corner_radius_all(6)
	frame_style.set_border_width_all(1)
	frame_style.border_color = Color(INK, 0.12)
	frame_style.set_content_margin_all(10)
	frame.add_theme_stylebox_override("panel", frame_style)

	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_child(_preview)
	column.add_child(frame)

	var layer_bar := HBoxContainer.new()
	layer_bar.add_theme_constant_override("separation", 6)
	for i in RENDER.LAYERS.size():
		var button := _pill(RENDER.LAYERS[i]["name"])
		var index := i
		button.pressed.connect(func(): _select_layer(index))
		_layer_buttons.append(button)
		layer_bar.add_child(button)
	column.add_child(layer_bar)

	_legend = RichTextLabel.new()
	_legend.bbcode_enabled = true
	_legend.fit_content = true
	_legend.scroll_active = false
	_legend.custom_minimum_size = Vector2(0, 46)
	_legend.add_theme_color_override("default_color", Color(INK, 0.62))
	_legend.add_theme_font_size_override("normal_font_size", 13)
	column.add_child(_legend)

	return column


func _build_side_column() -> Control:
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(320, 0)
	side.add_theme_constant_override("separation", 10)

	side.add_child(_caption("SEED — MODIFIABLE"))
	# Champ de saisie et non simple libelle : une seed qui donne un bon monde
	# doit pouvoir etre notee puis ressaisie, sinon la retrouver demande de
	# tirer au hasard jusqu'a retomber dessus.
	_seed_edit = LineEdit.new()
	_seed_edit.text = str(WorldSettings.seed_value)
	_seed_edit.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_seed_edit.add_theme_font_size_override("font_size", 40)
	_seed_edit.add_theme_color_override("font_color", INK)
	_seed_edit.add_theme_color_override("caret_color", GOLD)
	_seed_edit.add_theme_stylebox_override("normal", _flat(Color(INK, 0.06), 4))
	_seed_edit.add_theme_stylebox_override("focus", _flat(Color(GOLD, 0.18), 4))
	_seed_edit.text_submitted.connect(_on_seed_submitted)
	side.add_child(_seed_edit)

	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 6)
	var reroll := _pill("Au hasard")
	reroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reroll.pressed.connect(_on_reroll)
	seed_row.add_child(reroll)
	var again := _pill("Generer")
	again.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	again.pressed.connect(_on_seed_entered)
	seed_row.add_child(again)
	side.add_child(seed_row)

	side.add_child(_gap(10))
	side.add_child(_caption("ETENDUE DU MONDE"))
	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 6)
	for i in SIZES.size():
		var button := _pill("%d" % SIZES[i])
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var index := i
		button.pressed.connect(func(): _select_size(index))
		_size_buttons.append(button)
		size_row.add_child(button)
	side.add_child(size_row)

	# Rythme du monde. Ces deux reglages ne changent pas la carte — ils ne
	# touchent donc pas a l'empreinte du cache — mais ils decident de
	# l'ambiance d'une partie, ce qui a sa place ici plutot qu'en dur.
	side.add_child(_gap(10))
	side.add_child(_caption("DUREE D'UN JOUR"))
	var day_row := HBoxContainer.new()
	day_row.add_theme_constant_override("separation", 6)
	for i in DAY_LENGTHS.size():
		var button := _pill(DAY_LABELS[i])
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var index := i
		button.pressed.connect(func(): _select_day_length(index))
		_day_buttons.append(button)
		day_row.add_child(button)
	side.add_child(day_row)

	side.add_child(_caption("HEURE DE DEPART"))
	var hour_row := HBoxContainer.new()
	hour_row.add_theme_constant_override("separation", 6)
	for i in START_HOURS.size():
		var button := _pill(HOUR_LABELS[i])
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var index := i
		button.pressed.connect(func(): _select_start_hour(index))
		_hour_buttons.append(button)
		hour_row.add_child(button)
	side.add_child(hour_row)

	side.add_child(_gap(10))
	var figures := HBoxContainer.new()
	figures.add_theme_constant_override("separation", 18)

	var land_box := VBoxContainer.new()
	land_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	land_box.add_child(_caption("TERRES EMERGEES"))
	_land_value = _label("—", 30, LAGOON)
	land_box.add_child(_land_value)
	figures.add_child(land_box)

	var flat_box := VBoxContainer.new()
	flat_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flat_box.add_child(_caption("TERRAIN PLAT"))
	_flat_value = _label("—", 30, Color("#7ee08a"))
	flat_box.add_child(_flat_value)
	figures.add_child(flat_box)

	side.add_child(figures)

	side.add_child(_gap(10))
	side.add_child(_caption("BIOMES"))
	_biome_rows = VBoxContainer.new()
	_biome_rows.add_theme_constant_override("separation", 7)
	_biome_rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(_biome_rows)

	# Le cache est expose plutot que cache : l'empreinte des reglages change des
	# qu'on retouche une constante de generation, et le voir a l'ecran evite de
	# se demander si un monde a bien ete recalcule.
	var cache_row := HBoxContainer.new()
	cache_row.add_theme_constant_override("separation", 6)
	_cache_label = _label("", 11, Color(INK, 0.40))
	_cache_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cache_row.add_child(_cache_label)
	var clear_button := _pill("Vider")
	clear_button.pressed.connect(func():
		MapCache.clear()
		_refresh_cache_label())
	cache_row.add_child(clear_button)
	side.add_child(cache_row)

	_play_button = Button.new()
	_play_button.text = "Explorer ce monde"
	_play_button.custom_minimum_size = Vector2(0, 46)
	_play_button.add_theme_font_size_override("font_size", 16)
	_play_button.add_theme_color_override("font_color", BG)
	_play_button.add_theme_color_override("font_hover_color", BG)
	_play_button.add_theme_color_override("font_pressed_color", BG)
	_play_button.add_theme_stylebox_override("normal", _flat(GOLD, 4))
	_play_button.add_theme_stylebox_override("hover", _flat(GOLD.lightened(0.12), 4))
	_play_button.add_theme_stylebox_override("pressed", _flat(GOLD.darkened(0.15), 4))
	_play_button.pressed.connect(_on_play)
	side.add_child(_play_button)

	_select_size(SIZES.find(WorldSettings.size))
	_select_day_length(DAY_LENGTHS.find(WorldSettings.day_length_seconds))
	_select_start_hour(START_HOURS.find(WorldSettings.start_time_of_day))
	return side


# --- Petits assembleurs ----------------------------------------------------

func _label(text: String, size: int, color: Color) -> Label:
	var node := Label.new()
	node.text = text
	node.add_theme_font_size_override("font_size", size)
	node.add_theme_color_override("font_color", color)
	return node


func _caption(text: String) -> Label:
	return _label(text, 11, Color(INK, 0.40))


func _gap(height: int) -> Control:
	var node := Control.new()
	node.custom_minimum_size = Vector2(0, height)
	return node


func _flat(color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(8)
	return style


# Bouton plat facon pastille, sans le relief du theme par defaut : c'est ce
# qui distingue le plus une interface de jeu d'un panneau d'editeur.
func _pill(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 13)
	button.add_theme_color_override("font_color", Color(INK, 0.70))
	button.add_theme_color_override("font_hover_color", INK)
	button.add_theme_color_override("font_pressed_color", INK)
	button.add_theme_stylebox_override("normal", _flat(Color(INK, 0.07), 4))
	button.add_theme_stylebox_override("hover", _flat(Color(INK, 0.15), 4))
	button.add_theme_stylebox_override("pressed", _flat(Color(LAGOON, 0.35), 4))
	return button


func _mark_selected(button: Button, selected: bool) -> void:
	button.add_theme_stylebox_override("normal",
		_flat(Color(LAGOON, 0.30) if selected else Color(INK, 0.07), 4))
	button.add_theme_color_override("font_color", INK if selected else Color(INK, 0.70))


# --- Actions ---------------------------------------------------------------

func _select_layer(index: int) -> void:
	_layer = index
	for i in _layer_buttons.size():
		_mark_selected(_layer_buttons[i], i == index)
	_refresh_image()


func _select_size(index: int) -> void:
	if index < 0:
		index = SIZES.find(600)
	WorldSettings.size = SIZES[index]
	for i in _size_buttons.size():
		_mark_selected(_size_buttons[i], i == index)


func _on_reroll() -> void:
	WorldSettings.seed_value = randi() % 1000000
	_seed_edit.text = str(WorldSettings.seed_value)
	_regenerate()


# Une seed saisie a la main peut etre n'importe quoi : on prend la valeur
# entiere si le texte en contient une, et le hachage du texte sinon, ce qui
# accepte aussi bien "421" qu'un mot comme nom de monde.
func _on_seed_entered() -> void:
	var text := _seed_edit.text.strip_edges()
	if text.is_valid_int():
		WorldSettings.seed_value = absi(text.to_int())
	elif text.is_empty():
		WorldSettings.seed_value = 1
	else:
		WorldSettings.seed_value = absi(hash(text))
	_seed_edit.text = str(WorldSettings.seed_value)
	_regenerate()


func _on_seed_submitted(_text: String) -> void:
	_on_seed_entered()


func _on_play() -> void:
	if _map == null or _busy:
		return
	# La carte affichee part telle quelle : elle a deja coute son calcul, et la
	# regenerer donnerait exactement le meme resultat.
	WorldSettings.prepared_map = _map
	get_tree().change_scene_to_file("res://scenes/voxel_world/smooth_voxel_world.tscn")


func _regenerate() -> void:
	if _busy:
		return
	_busy = true
	_play_button.disabled = true
	_seed_edit.text = str(WorldSettings.seed_value)
	_status.text = "Generation du monde %d x %d..." % [WorldSettings.size, WorldSettings.size]
	# Une frame pour que le libelle s'affiche : la generation est synchrone et
	# fige la fenetre plusieurs secondes.
	await get_tree().process_frame

	var started := Time.get_ticks_msec()
	_map = MapCache.load_or_generate(
		WorldSettings.seed_value, WorldSettings.size, WorldSettings.height)
	var elapsed := Time.get_ticks_msec() - started

	_select_layer(_layer)
	_refresh_stats()
	# On distingue les deux cas a l'ecran : qui calibre la generation doit
	# savoir s'il regarde un monde recalcule ou une vieille carte relue.
	_status.text = ("Monde repris du cache en %d ms" if MapCache.last_was_cached()
		else "Monde genere en %d ms") % elapsed
	_play_button.disabled = false
	_busy = false
	_refresh_cache_label()


func _refresh_image() -> void:
	if _map == null:
		return
	_preview.texture = ImageTexture.create_from_image(RENDER.render(_map, _layer))
	_legend.text = RENDER.legend(_layer)


func _refresh_stats() -> void:
	for child in _biome_rows.get_children():
		child.queue_free()

	var counts := {}
	var land := 0
	var flat := 0
	for z in _map.size_xz:
		for x in _map.size_xz:
			var biome := _map.biome_at(x, z)
			counts[biome] = int(counts.get(biome, 0)) + 1
			if _map.terrain_height(x, z) <= WorldMap.SEA_LEVEL:
				continue
			land += 1
			if _map.slope_at(x, z) <= WorldMap.FLAT_SLOPE:
				flat += 1

	var total := _map.size_xz * _map.size_xz
	_land_value.text = "%.0f %%" % (100.0 * float(land) / float(total))
	# Part des terres ou l'on peut s'installer : c'est ce chiffre, et non la
	# surface emergee, qui dit si un monde est habitable.
	_flat_value.text = "%.0f %%" % (100.0 * float(flat) / float(maxi(land, 1)))

	var ordered := counts.keys()
	ordered.sort_custom(func(a, b): return counts[a] > counts[b])
	for biome in ordered:
		if biome == WorldMap.Biome.DEEP_SEA or biome == WorldMap.Biome.SHALLOW_SEA:
			continue
		var share := float(counts[biome]) / float(maxi(land, 1))
		_biome_rows.add_child(_biome_row(biome, share))

	# Un biome present dans le code mais absent de la carte est un seuil mal
	# calibre, pas une fonctionnalite : autant le dire ici plutot que de le
	# decouvrir en jeu.
	var missing := PackedStringArray()
	for required in [WorldMap.Biome.BEACH, WorldMap.Biome.DESERT,
			WorldMap.Biome.SNOW, WorldMap.Biome.RIVER, WorldMap.Biome.FOREST]:
		if int(counts.get(required, 0)) == 0:
			missing.append(_map.biome_name(required))
	if missing.size() > 0:
		_biome_rows.add_child(_gap(6))
		_biome_rows.add_child(_label("Absents : " + ", ".join(missing), 12, CORAL))


# Une ligne de biome : nom, part, et une barre fine. La barre vaut mieux qu'un
# pourcentage seul — elle rend comparables d'un coup d'oeil des biomes qui
# vont de 22 % a 0,3 %.
func _biome_row(biome: int, share: float) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 3)

	var head := HBoxContainer.new()
	head.add_child(_label(_map.biome_name(biome), 13, Color(INK, 0.85)))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	head.add_child(_label("%.1f %%" % (share * 100.0), 13, Color(INK, 0.55)))
	row.add_child(head)

	var stack := Control.new()
	stack.custom_minimum_size = Vector2(0, 4)

	var track := PanelContainer.new()
	track.add_theme_stylebox_override("panel", _bar(Color(INK, 0.12)))
	track.set_anchors_preset(Control.PRESET_FULL_RECT)
	stack.add_child(track)

	var fill := PanelContainer.new()
	fill.add_theme_stylebox_override("panel", _bar(RENDER.BIOME_COLOR.get(biome, INK)))
	fill.set_anchors_preset(Control.PRESET_FULL_RECT)
	# La racine ecrase l'echelle : sans elle, tout ce qui est sous 5 % devient
	# un trait invisible a cote de la prairie, alors que c'est justement la
	# que se joue la question "ce biome sort-il vraiment ?".
	fill.anchor_right = clampf(sqrt(share), 0.02, 1.0)
	stack.add_child(fill)

	row.add_child(stack)
	return row


func _bar(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(2)
	style.set_content_margin_all(0)
	return style


func _refresh_cache_label() -> void:
	_cache_label.text = "Cache · %d carte(s) · empreinte %x" % [
		MapCache.entry_count(), MapCache.parameters_hash() & 0xffffffff]


# Duree du jour et heure de depart ne changent pas la carte : ils ne
# declenchent donc aucune regeneration, contrairement a la seed et a la
# taille.
func _select_day_length(index: int) -> void:
	if index < 0:
		index = DAY_LENGTHS.find(900.0)
	WorldSettings.day_length_seconds = DAY_LENGTHS[index]
	for i in _day_buttons.size():
		_mark_selected(_day_buttons[i], i == index)


func _select_start_hour(index: int) -> void:
	if index < 0:
		index = 0
	WorldSettings.start_time_of_day = START_HOURS[index]
	for i in _hour_buttons.size():
		_mark_selected(_hour_buttons[i], i == index)
