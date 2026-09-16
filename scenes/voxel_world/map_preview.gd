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

# Palette et assembleurs communs avec le menu des mondes : voir `island_ui.gd`.
# Les noms courts restent locaux, les valeurs ne sont plus recopiees.
const BG := IslandUI.BG
const BG_SOFT := IslandUI.BG_SOFT
const INK := IslandUI.INK
const GOLD := IslandUI.GOLD
const LAGOON := IslandUI.LAGOON
const CORAL := IslandUI.CORAL

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
var _generate_button: Button
var _cache_label: Label
var _progress_fill: Control
var _progress_row: Control

# Generation asynchrone.
#
# `_pending` est la carte EN COURS de calcul, et elle est tenue ici justement
# pour qu'on puisse lire son avancement et lui demander de s'arreter pendant
# que le fil travaille. `_thread` est vivant tant que le calcul l'est.
var _thread: Thread
var _pending: WorldMap
var _started_msec := 0


# F10 ferme le jeu depuis l ecran de carte aussi : c est le premier ecran, donc
# celui ou l on se trouve quand on veut simplement partir.
#
# Pas sur Echap : la saisie de graine est un LineEdit, et Echap y est le geste
# courant pour abandonner une saisie.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		if (event as InputEventKey).keycode == KEY_F10:
			get_tree().quit()
		elif (event as InputEventKey).keycode == KEY_ESCAPE and not _seed_edit.has_focus():
			# Echap revient au menu, SAUF pendant une saisie de graine : la, il
			# sert deja a abandonner ce qu on tape.
			_cancel_pending()
			get_tree().change_scene_to_file("res://scenes/voxel_world/world_menu.tscn")


func _ready() -> void:
	_build_ui()

	# Retour depuis la partie : la carte est deja la, en memoire, et elle a
	# exactement les reglages courants. La recalculer — ou meme la relire au
	# cache — ferait attendre plusieurs secondes pour retomber sur l'objet qu'on
	# tient deja.
	var kept := WorldSettings.prepared_map
	WorldSettings.prepared_map = null
	if kept != null and kept.size_xz == WorldSettings.size \
			and kept.size_y == WorldSettings.height:
		_map = kept
		WorldSettings.seed_value = kept.seed_used
		_seed_edit.text = str(kept.seed_used)
		_select_layer(_layer)
		_refresh_stats()
		_status.text = "Monde de la partie precedente"
		_refresh_buttons()
		_refresh_cache_label()
		return

	_regenerate()


# Un fil encore vivant a la fermeture fait rouspeter Godot, et a raison : il
# ecrit peut-etre dans le cache.
func _exit_tree() -> void:
	_cancel_pending()


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
	var back := _pill("Retour")
	back.pressed.connect(func():
		_cancel_pending()
		get_tree().change_scene_to_file("res://scenes/voxel_world/world_menu.tscn"))
	seed_row.add_child(back)
	var reroll := _pill("Au hasard")
	reroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reroll.pressed.connect(_on_reroll)
	seed_row.add_child(reroll)
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

	# Barre d'avancement, dans le meme vocabulaire que les parts de biome : une
	# piste sombre et un remplissage ancre a gauche. Elle n'est visible que
	# pendant un calcul, pour ne pas occuper la place en permanence.
	_progress_row = VBoxContainer.new()
	_progress_row.add_theme_constant_override("separation", 0)
	var track_stack := Control.new()
	track_stack.custom_minimum_size = Vector2(0, 4)
	var track := PanelContainer.new()
	track.add_theme_stylebox_override("panel", _bar(Color(INK, 0.12)))
	track.set_anchors_preset(Control.PRESET_FULL_RECT)
	track_stack.add_child(track)
	var fill := PanelContainer.new()
	fill.add_theme_stylebox_override("panel", _bar(GOLD))
	fill.set_anchors_preset(Control.PRESET_FULL_RECT)
	fill.anchor_right = 0.0
	track_stack.add_child(fill)
	_progress_fill = fill
	_progress_row.add_child(track_stack)
	_progress_row.add_child(_gap(8))
	_progress_row.visible = false
	side.add_child(_progress_row)

	# Les deux actions partagent la meme ligne : generer et partir sont les deux
	# issues de cet ecran, et rien ne justifie d'en releguer une plus haut.
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)

	_generate_button = _action_button("Generer", LAGOON)
	_generate_button.pressed.connect(_on_seed_entered)
	action_row.add_child(_generate_button)

	_play_button = _action_button("Explorer ce monde", GOLD)
	_play_button.size_flags_stretch_ratio = 1.6
	_play_button.pressed.connect(_on_play)
	action_row.add_child(_play_button)

	side.add_child(action_row)

	_select_size(SIZES.find(WorldSettings.size))
	_select_day_length(DAY_LENGTHS.find(WorldSettings.day_length_seconds))
	_select_start_hour(START_HOURS.find(WorldSettings.start_time_of_day))
	return side


# --- Petits assembleurs ----------------------------------------------------
#
# Tous delegues a `IslandUI` : les deux ecrans d avant-partie doivent se
# ressembler exactement, et deux copies auraient derive.

func _label(text: String, size: int, color: Color) -> Label:
	return IslandUI.label(text, size, color)


func _caption(text: String) -> Label:
	return IslandUI.caption(text)


func _gap(height: int) -> Control:
	return IslandUI.gap(height)


func _flat(color: Color, radius: int) -> StyleBoxFlat:
	return IslandUI.flat(color, radius)


func _bar(color: Color) -> StyleBoxFlat:
	return IslandUI.bar(color)


func _pill(text: String) -> Button:
	return IslandUI.pill(text)


func _action_button(text: String, color: Color) -> Button:
	return IslandUI.action_button(text, color)


func _mark_selected(button: Button, selected: bool) -> void:
	IslandUI.mark_selected(button, selected)


# --- Actions ---------------------------------------------------------------

func _select_layer(index: int) -> void:
	_layer = index
	for i in _layer_buttons.size():
		_mark_selected(_layer_buttons[i], i == index)
	_refresh_image()


# Changer la taille ANNULE le calcul en cours et laisse la carte affichee en
# l'etat.
#
# On ne relance pas tout seul : la taille se choisit souvent en deux clics, et
# enchainer une generation a chacun ferait travailler pour rien. La carte a
# l'ecran n'etant alors plus celle des reglages, « Explorer ce monde » se
# desactive de lui-meme — c'est `_map_is_current` qui s'en charge.
func _select_size(index: int) -> void:
	if index < 0:
		index = SIZES.find(800)
	_cancel_pending()
	WorldSettings.size = SIZES[index]
	for i in _size_buttons.size():
		_mark_selected(_size_buttons[i], i == index)
	_status.text = "Taille changee — a regenerer"
	_refresh_buttons()


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
	if _busy or not _map_is_current():
		return
	# La carte affichee part telle quelle : elle a deja coute son calcul, et la
	# regenerer donnerait exactement le meme resultat.
	WorldSettings.prepared_map = _map
	get_tree().change_scene_to_file("res://scenes/voxel_world/smooth_voxel_world.tscn")


# La generation part sur un FIL separe.
#
# Elle etait synchrone, avec une frame d'attente pour que le libelle s'affiche
# avant de figer la fenetre. Ca tenait tant qu'une carte coutait 400 ms ; a 800
# de cote elle en coute plusieurs milliers, pendant lesquelles rien ne bouge,
# aucun avancement ne s'affiche et aucun reglage ne repond.
#
# `WorldMap` s'y prete : c'est du calcul pur, sans acces a la scene.
func _regenerate() -> void:
	_cancel_pending()

	_pending = WorldMap.new(WorldSettings.size, WorldSettings.height)
	_seed_edit.text = str(WorldSettings.seed_value)
	_started_msec = Time.get_ticks_msec()
	_busy = true
	_set_progress(0.0)
	_refresh_buttons()

	# Les reglages sont recopies : ils peuvent changer pendant le calcul, et le
	# fil doit travailler sur ceux d'AU MOMENT du lancement.
	var seed_value := WorldSettings.seed_value
	var size := WorldSettings.size
	var height := WorldSettings.height
	var target := _pending

	_thread = Thread.new()
	_thread.start(func() -> WorldMap:
		return MapCache.load_or_generate(seed_value, size, height, target))
	set_process(true)


# Interrompt le calcul en cours, s'il y en a un.
#
# `wait_to_finish` bloque, mais brievement : la generation relit sa demande
# d'arret a chaque rangee de colonnes, soit quelques dixiemes de milliseconde.
# Ne pas attendre laisserait deux fils ecrire dans le cache en meme temps.
func _cancel_pending() -> void:
	if _thread == null:
		return
	if _pending != null:
		_pending.cancel_requested = true
	_thread.wait_to_finish()
	_thread = null
	_pending = null
	_busy = false


func _process(_delta: float) -> void:
	if _thread == null:
		set_process(false)
		return

	if _pending != null:
		_set_progress(_pending.progress)
		_status.text = "Generation du monde %d x %d — %d %%" % [
			WorldSettings.size, WorldSettings.size, int(_pending.progress * 100.0)]

	if _thread.is_alive():
		return

	var result: WorldMap = _thread.wait_to_finish()
	_thread = null
	_pending = null
	_busy = false
	set_process(false)

	if result == null:
		# Annulee : une autre generation a deja pris la suite, ou l'utilisateur
		# a change de reglage. Rien a afficher.
		return

	_map = result
	_set_progress(1.0)
	_select_layer(_layer)
	_refresh_stats()
	# On distingue les deux cas a l'ecran : qui calibre la generation doit
	# savoir s'il regarde un monde recalcule ou une vieille carte relue.
	_status.text = ("Monde repris du cache en %d ms" if MapCache.last_was_cached()
		else "Monde genere en %d ms") % (Time.get_ticks_msec() - _started_msec)
	_refresh_buttons()
	_refresh_cache_label()


# La carte affichee correspond-elle aux reglages COURANTS ?
#
# C'est la condition pour pouvoir partir explorer. Changer la graine ou la
# taille sans regenerer laisse a l'ecran une carte qui n'est plus celle qu'on
# obtiendrait, et lancer la partie dessus serait un piege.
func _map_is_current() -> bool:
	return (_map != null
		and _map.seed_used == WorldSettings.seed_value
		and _map.size_xz == WorldSettings.size
		and _map.size_y == WorldSettings.height)


func _refresh_buttons() -> void:
	if _generate_button != null:
		_generate_button.disabled = _busy
	if _play_button != null:
		_play_button.disabled = _busy or not _map_is_current()
	if _progress_row != null:
		_progress_row.visible = _busy


func _set_progress(value: float) -> void:
	if _progress_fill != null:
		_progress_fill.anchor_right = clampf(value, 0.0, 1.0)


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
