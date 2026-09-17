extends Control

# Menu des mondes : le premier ecran du jeu.
#
# C'est un SELECTEUR et non une galerie, sur le modele de l'ecran de choix de
# piste de `lonely-descent` : une pellicule de vignettes en bas, et tout le
# reste de l'ecran consacre au monde retenu. Une grille de cases traitait les
# douze mondes a egalite ; ici il y en a un qu'on regarde, et onze qu'on peut
# atteindre.
#
# Il existe parce qu'une carte coute cher — pres de quatre secondes a 800 de
# cote. Le cache les gardait deja, mais rien ne les montrait : retrouver un
# monde qu'on avait aime demandait de se rappeler sa graine et de la ressaisir.
#
# Rien n'est ouvert pour afficher cet ecran. Les vignettes et les mesures sont
# ecrites a cote de chaque carte au moment de la mise en cache : une carte de
# 800 pese une vingtaine de megaoctets, et le menu en presente douze.

const PREVIEW_SCENE := "res://scenes/voxel_world/map_preview.tscn"
const WORLD_SCENE := "res://scenes/voxel_world/smooth_voxel_world.tscn"
const STRIP_SIZE := Vector2(168, 92)

var _entries: Array[Dictionary] = []
var _selected := 0

var _backdrop: TextureRect
var _title: Label
var _subtitle: Label
var _portrait: Label
var _stats: VBoxContainer
var _strip: HBoxContainer
var _strip_buttons: Array[Button] = []
var _play_button: Button
var _empty_note: Label
var _cache_label: Label


func _ready() -> void:
	_entries = MapCache.entries().filter(func(e): return bool(e["current"]))
	_build_ui()
	_select(0)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed():
		return
	match (event as InputEventKey).keycode:
		KEY_LEFT:
			_select(_selected - 1)
		KEY_RIGHT:
			_select(_selected + 1)
		KEY_ENTER, KEY_KP_ENTER:
			_open()
		KEY_N:
			_new_map()
		KEY_ESCAPE:
			# Retour a l'accueil, et non plus sortie du jeu : cet ecran n'est
			# plus le premier depuis que le choix solo / reseau le precede.
			_go_home()
		KEY_F10:
			get_tree().quit()


# --- Construction de l'interface ------------------------------------------

func _build_ui() -> void:
	var rows := IslandUI.page(self)
	# Le temoin d'hebergement se tait en solo, et ne s'allume que si quelqu'un
	# attend derriere. Voir `host_status.gd`.
	rows.add_child(IslandUI.header("← Accueil", _go_home, HostStatus.new()))

	# Le monde retenu occupe le fond, tres assourdi. C'est ce qui remplit la
	# moitie droite sans y poser d'interface, et ce qui fait qu'on regarde un
	# lieu plutot qu'une fiche.
	#
	# Glisse JUSTE APRES la couleur de nuit posee par `page` et sous tout le
	# reste : l'ajouter en dernier le mettrait par-dessus l'interface, l'ajouter
	# avant le ferait recouvrir par cette couleur.
	_backdrop = TextureRect.new()
	_backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.modulate = Color(1.0, 1.0, 1.0, 0.16)
	add_child(_backdrop)
	move_child(_backdrop, 1)

	# --- Fiche du monde retenu ---
	#
	# Elle est tenue dans une COLONNE, centree, avec du vide de part et d'autre.
	# Sans cette colonne les barres et les boutons s etiraient sur toute la
	# largeur de l ecran, ce qui les rendait illisibles : une barre de mille cinq
	# cents pixels ne se compare plus a rien, et le fond n avait plus de place
	# pour respirer.
	var sheet := VBoxContainer.new()
	sheet.add_theme_constant_override("separation", IslandUI.SPACE_TIGHT)
	sheet.custom_minimum_size = Vector2(520, 0)
	rows.add_child(IslandUI.centered(sheet))

	_title = IslandUI.title("")
	sheet.add_child(_title)

	_subtitle = IslandUI.label("", 17, Color(IslandUI.GOLD, 0.85))
	sheet.add_child(_subtitle)

	sheet.add_child(IslandUI.group_gap())
	_portrait = IslandUI.label("", 15, Color(IslandUI.INK, 0.62))
	_portrait.custom_minimum_size = Vector2(460, 0)
	_portrait.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sheet.add_child(_portrait)

	sheet.add_child(IslandUI.group_gap())
	_stats = VBoxContainer.new()
	_stats.add_theme_constant_override("separation", IslandUI.SPACE_TIGHT)
	sheet.add_child(_stats)

	_empty_note = IslandUI.label("", 15, Color(IslandUI.INK, 0.55))
	_empty_note.custom_minimum_size = Vector2(500, 0)
	_empty_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sheet.add_child(_empty_note)

	sheet.add_child(IslandUI.group_gap())
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", IslandUI.SPACE_TIGHT)
	actions.custom_minimum_size = Vector2(460, 0)

	_play_button = IslandUI.action_button("Explorer ce monde", IslandUI.GOLD)
	_play_button.size_flags_stretch_ratio = 1.6
	_play_button.pressed.connect(_open)
	actions.add_child(_play_button)

	var new_map := IslandUI.action_button("Nouvelle carte", IslandUI.LAGOON)
	new_map.pressed.connect(_new_map)
	actions.add_child(new_map)
	sheet.add_child(actions)

	# --- Pellicule ---
	var scroll := ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, STRIP_SIZE.y + 30)
	rows.add_child(scroll)

	_strip = HBoxContainer.new()
	_strip.add_theme_constant_override("separation", IslandUI.SPACE_ROW)
	# La pellicule se centre comme le reste. Elle doit s'etirer pour cela : une
	# rangee laissee a sa taille minimale n'a pas de place ou se centrer.
	_strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_strip.alignment = BoxContainer.ALIGNMENT_CENTER
	scroll.add_child(_strip)

	# Pied de page : l etat du cache, a droite. Le cache est EXPOSE plutot que
	# cache — c est lui qui remplit cet ecran, et l empreinte change des qu on
	# retouche un reglage de generation. Le voir evite de se demander pourquoi
	# des mondes ont disparu.
	#
	# Le rappel des touches qui tenait la gauche a ete retire : tout ce qu'il
	# annoncait est deja un bouton a l'ecran, ou la pastille de retour en haut a
	# droite. Voir la note sur les pieds de page dans `island_ui.gd`.
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", IslandUI.SPACE_ROW)
	footer.add_child(IslandUI.spacer())

	_cache_label = IslandUI.label("", 12, Color(IslandUI.INK, 0.35))
	footer.add_child(_cache_label)

	var clear_button := IslandUI.pill("Vider le cache")
	clear_button.pressed.connect(_clear_cache)
	footer.add_child(clear_button)

	rows.add_child(footer)
	_rebuild_strip()


# Une vignette de pellicule : l'image, et le nom du monde en incrustation.
func _build_strip_item(entry: Dictionary) -> Button:
	var button := Button.new()
	button.custom_minimum_size = STRIP_SIZE
	button.focus_mode = Control.FOCUS_NONE

	var texture := TextureRect.new()
	texture.texture = MapCache.thumbnail(entry)
	texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	texture.set_anchors_preset(Control.PRESET_FULL_RECT)
	texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(texture)

	var veil := ColorRect.new()
	veil.color = Color(IslandUI.BG, 0.78)
	veil.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	veil.offset_top = -26
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(veil)

	var name_label := IslandUI.label(
		WorldName.for_seed(int(entry["seed"])).to_upper(), 11, Color(IslandUI.INK, 0.8))
	name_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	name_label.offset_left = 8
	name_label.offset_right = -8
	name_label.offset_top = -22
	name_label.offset_bottom = -5
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(name_label)

	return button


# --- Selection --------------------------------------------------------------

func _select(index: int) -> void:
	if _entries.is_empty():
		_show_empty()
		return

	_selected = clampi(index, 0, _entries.size() - 1)
	var entry := _entries[_selected]

	for i in _strip_buttons.size():
		_mark_strip(_strip_buttons[i], i == _selected)

	_backdrop.texture = MapCache.thumbnail(entry)
	_title.text = WorldName.for_seed(int(entry["seed"]))
	_subtitle.text = "graine %d  ·  %d x %d m" % [
		int(entry["seed"]), int(entry["size"]), int(entry["size"])]
	_portrait.text = WorldName.describe(entry.get("meta", {}))
	_empty_note.visible = false
	_play_button.disabled = false
	_rebuild_stats(entry)


func _show_empty() -> void:
	_title.text = "Aucun monde"
	_subtitle.text = ""
	_portrait.text = ""
	_empty_note.visible = true
	_empty_note.text = ("Rien en memoire pour l'instant. Composez une carte : "
		+ "elle sera gardee ici, et s'ouvrira ensuite sans attendre.")
	_play_button.disabled = true
	for child in _stats.get_children():
		child.queue_free()


# Les mesures, en barres.
#
# Un pourcentage seul ne se compare pas d'un coup d'oeil ; la barre, si. C'est
# le meme parti que les parts de biome de l'ecran d'apercu.
func _rebuild_stats(entry: Dictionary) -> void:
	for child in _stats.get_children():
		child.queue_free()

	var meta: Dictionary = entry.get("meta", {})
	if meta.is_empty():
		return

	_stats.add_child(_stat_row("TERRES EMERGEES",
		"%.0f %%" % (float(meta.get("land", 0.0)) * 100.0),
		float(meta.get("land", 0.0)), IslandUI.LAGOON))
	# Ce chiffre-la, et non la surface emergee, dit si un monde est habitable.
	_stats.add_child(_stat_row("TERRAIN PRATICABLE",
		"%.0f %%" % (float(meta.get("flat", 0.0)) * 100.0),
		float(meta.get("flat", 0.0)), Color("#7ee08a")))
	_stats.add_child(_stat_row("ETENDUE",
		"%d m" % int(entry["size"]), float(int(entry["size"])) / 800.0, IslandUI.GOLD))


func _stat_row(caption: String, value: String, share: float, color: Color) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	row.custom_minimum_size = Vector2(380, 0)
	row.add_child(IslandUI.caption(caption))
	row.add_child(IslandUI.label(value, 26, IslandUI.INK))

	var stack := Control.new()
	stack.custom_minimum_size = Vector2(0, 3)

	var track := PanelContainer.new()
	track.add_theme_stylebox_override("panel", IslandUI.bar(Color(IslandUI.INK, 0.14)))
	track.set_anchors_preset(Control.PRESET_FULL_RECT)
	stack.add_child(track)

	var fill := PanelContainer.new()
	fill.add_theme_stylebox_override("panel", IslandUI.bar(color))
	fill.set_anchors_preset(Control.PRESET_FULL_RECT)
	fill.anchor_right = clampf(share, 0.02, 1.0)
	stack.add_child(fill)

	row.add_child(stack)
	return row


# Le monde retenu est SOULEVE plutot que cerne : un liseré se perd sur une
# vignette deja bordee, une teinte franche et un trait d'or se voient.
func _mark_strip(button: Button, selected: bool) -> void:
	var tint := Color(IslandUI.GOLD, 0.55) if selected else Color(IslandUI.INK, 0.10)
	button.add_theme_stylebox_override("normal", IslandUI.flat(tint, 4))
	button.add_theme_stylebox_override("hover",
		IslandUI.flat(tint if selected else Color(IslandUI.LAGOON, 0.30), 4))
	button.modulate = Color(1, 1, 1, 1.0 if selected else 0.62)


# --- Actions ---------------------------------------------------------------

# Reprendre un monde entre DIRECTEMENT en jeu.
#
# L'apercu n'a rien a apprendre ici : on vient de choisir une carte en la
# voyant, avec ses mesures. Le detour ne servait qu'aux reglages de rythme
# (duree du jour, heure de depart), qui gardent leur derniere valeur et se
# reglent a la composition d'une carte neuve.
#
# La carte est CHARGEE ICI et transmise a la scene de jeu. C'est la meme
# seconde de lecture dans les deux cas, mais ici elle est annoncee : faite dans
# le `_ready` du monde, elle fige une fenetre noire avant que le moindre
# libelle ait pu etre peint.
func _open() -> void:
	if _entries.is_empty():
		return
	var entry := _entries[_selected]
	WorldSettings.seed_value = int(entry["seed"])
	WorldSettings.size = int(entry["size"])

	_title.text = "Ouverture..."
	_subtitle.text = WorldName.for_seed(int(entry["seed"]))
	_portrait.text = ""
	_play_button.disabled = true
	await get_tree().process_frame

	# La carte du dernier monde joue est GARDEE : revenir au menu puis y
	# retourner ne doit pas repayer une seconde de lecture pour retomber sur
	# l objet qu on tient deja.
	var kept := WorldSettings.prepared_map
	var matches := (kept != null
		and kept.seed_used == int(entry["seed"])
		and kept.size_xz == int(entry["size"]))
	if not matches:
		WorldSettings.prepared_map = MapCache.load_or_generate(
			int(entry["seed"]), int(entry["size"]), WorldSettings.height)
	get_tree().change_scene_to_file(WORLD_SCENE)


func _new_map() -> void:
	get_tree().change_scene_to_file(PREVIEW_SCENE)


# La pellicule est reconstruite plutot que modifiee : vider le cache change le
# nombre de vignettes, et il n'y a pas dix mondes a menager.
func _rebuild_strip() -> void:
	for child in _strip.get_children():
		_strip.remove_child(child)
		child.queue_free()
	_strip_buttons.clear()

	for i in _entries.size():
		var index := i
		var button := _build_strip_item(_entries[i])
		button.pressed.connect(func(): _select(index))
		_strip_buttons.append(button)
		_strip.add_child(button)

	_cache_label.text = "Cache · %d monde(s) · empreinte %x" % [
		_entries.size(), MapCache.parameters_hash() & 0xffffffff]


# Vider le cache efface les mondes ET leurs vignettes.
#
# Il n'y a pas de confirmation, et c'est defendable : rien n'est perdu pour de
# bon. Une carte se retrouve a l'identique en ressaisissant sa graine, puisque
# c'est tout ce dont depend le monde — le cache ne fait qu'eviter d'en repayer
# le calcul.
# Le serveur eventuellement ouvert est ferme par l'ecran d'accueil lui-meme,
# qui appelle `Network.leave_game()` en arrivant : un seul endroit sait ce que
# veut dire « repartir de zero ».
func _go_home() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu/main_menu.tscn")


func _clear_cache() -> void:
	MapCache.clear()
	_entries = []
	_selected = 0
	_rebuild_strip()
	_backdrop.texture = null
	_select(0)
