class_name Hotbar
extends Control

# Barre d'outils : les cases DE BASE de l'inventaire (touches 1-9), affichees
# en permanence pendant le jeu. Les cases bonus d'un sac a dos equipe ne sont
# PAS montrees ici - c'est du stockage supplementaire, pas de la selection
# rapide, voir `Inventory`/`inventory_screen.gd`.
#
# Construit en code comme `Crosshair`/`PauseMenu` - pas de `.tscn`. Reutilise
# la palette d'`IslandUI` (deja pensee pour ce jeu) mais pas `IslandUI.page()`,
# dont le fond plein-ecran opaque est fait pour remplacer un ecran, pas pour
# rester non-bloquant par-dessus la vue 3D.

const SLOT_SIZE := 44.0
const SLOT_GAP := 6.0
const MARGIN_BOTTOM := 18.0

var _slot_panels: Array[PanelContainer] = []
var _slot_swatches: Array[ColorRect] = []
var _slot_counts: Array[Label] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # jamais voler un clic, meme regle que Crosshair
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(SLOT_GAP))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)

	for i in Inventory.BASE_SLOT_COUNT:
		row.add_child(_build_slot(i))

	# Position finale une fois les enfants construits : la largeur totale de la
	# rangee n'est connue qu'apres, donc on centre par offset plutot que par
	# ancre seule (les deux ancres a 0.5 collent le CENTRE du nœud au centre de
	# l'ecran, encore faut-il que le nœud ait la bonne largeur).
	custom_minimum_size = Vector2(
		Inventory.BASE_SLOT_COUNT * SLOT_SIZE + (Inventory.BASE_SLOT_COUNT - 1) * SLOT_GAP,
		SLOT_SIZE)
	offset_left = -custom_minimum_size.x / 2.0
	offset_right = custom_minimum_size.x / 2.0
	offset_top = -SLOT_SIZE - MARGIN_BOTTOM
	offset_bottom = -MARGIN_BOTTOM


func _build_slot(index: int) -> PanelContainer:
	var panel := IslandUI.frame()
	panel.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_slot_panels.append(panel)

	var swatch := ColorRect.new()
	swatch.color = Color(0, 0, 0, 0)
	swatch.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(swatch)
	_slot_swatches.append(swatch)

	var key_label := IslandUI.label(str(index + 1), 10, Color(IslandUI.INK, 0.55))
	key_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	key_label.position = Vector2(3, 1)
	key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(key_label)

	var count_label := IslandUI.label("", 12, IslandUI.INK)
	count_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_label.position = Vector2(-16, -16)
	count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(count_label)
	_slot_counts.append(count_label)

	return panel


func refresh(inventory: Inventory) -> void:
	for i in Inventory.BASE_SLOT_COUNT:
		var slot = inventory.get_slot(i)
		var active := i == inventory.active_slot

		if slot == null:
			_slot_swatches[i].color = Color(0, 0, 0, 0)
			_slot_counts[i].text = ""
		else:
			var item_id: int = slot["item"]
			_slot_swatches[i].color = Color(ItemCatalog.color(item_id), 0.85)
			_slot_counts[i].text = str(slot["count"]) if slot["count"] > 1 else ""

		# Un cadre qui s'allume sur la case active plutot qu'un agrandissement
		# (l'ancien `ToolsRow` scalait 1.15x) : aussi lisible en bas d'ecran, et
		# ca ne fait pas "trembler" les cases voisines en redimensionnant la
		# rangee.
		var style := StyleBoxFlat.new()
		style.bg_color = IslandUI.BG_SOFT
		style.set_corner_radius_all(6)
		style.set_content_margin_all(10)
		style.set_border_width_all(2 if active else 1)
		style.border_color = IslandUI.GOLD if active else Color(IslandUI.INK, 0.12)
		_slot_panels[i].add_theme_stylebox_override("panel", style)
