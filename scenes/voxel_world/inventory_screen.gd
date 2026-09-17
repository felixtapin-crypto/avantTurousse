class_name InventoryScreen
extends Control

# Ecran d'inventaire complet : TOUTES les cases (barre de base + bonus d'un
# sac a dos equipe) et l'emplacement d'equipement. S'ouvre/se ferme a la
# touche `toggle_inventory` (voir `VoxelDebugPlayer`), NE MET PAS LE JEU EN
# PAUSE - nouveau territoire dans ce code, le seul precedent de superposition
# (`PauseMenu`) fige l'arbre. Le joueur continue de marcher (WASD) pendant
# qu'on farfouille ; seule la camera arrete de suivre la souris, le curseur
# etant libere pour cliquer ici - meme bascule de `Input.mouse_mode` que la
# pause, juste sans `get_tree().paused`.
#
# Interaction volontairement minimale : CLIC POUR EQUIPER/DESEQUIPER, pas de
# glisser-depose. Cliquer une case contenant un objet d'equipement l'equipe ;
# cliquer la case d'equipement occupee le retire. Reordonner les objets entre
# cases n'est pas construit cette version.

signal closed

const SLOT_SIZE := 56.0
const COLUMNS := 5

var _inventory: Inventory
var _grid: GridContainer
var _equip_button: Button
var _hint_label: Label


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Voile SEMI-TRANSPARENT : contrairement a `IslandUI.page()` (opaque), le
	# joueur doit encore voir/suivre ce qui se passe autour de lui en
	# farfouillant dans son sac.
	var veil := ColorRect.new()
	veil.color = Color(IslandUI.BG, 0.72)
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(veil)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := IslandUI.frame()
	center.add_child(panel)

	var column := IslandUI.column(COLUMNS * int(SLOT_SIZE) + 40)
	panel.add_child(column)

	column.add_child(IslandUI.title("Inventaire"))
	column.add_child(IslandUI.subtitle("Clic sur un sac pour l'equiper, ou sur l'equipement pour le retirer."))
	column.add_child(IslandUI.group_gap())

	column.add_child(IslandUI.caption("EQUIPEMENT"))
	_equip_button = Button.new()
	_equip_button.custom_minimum_size = Vector2(0, SLOT_SIZE)
	_equip_button.pressed.connect(_on_equip_slot_pressed)
	column.add_child(_equip_button)
	column.add_child(IslandUI.group_gap())

	column.add_child(IslandUI.caption("CASES"))
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	column.add_child(_grid)

	_hint_label = IslandUI.caption("")
	column.add_child(_hint_label)


func open(inventory: Inventory) -> void:
	_inventory = inventory
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	refresh()


# Publique : appelee aussi bien par cet ecran lui-meme (Echap, touche
# inventaire) que par le monde de l'exterieur (la pause doit primer sur
# l'inventaire, voir `SmoothVoxelWorld._open_pause`).
func close() -> void:
	if not visible:
		return
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("toggle_inventory"):
		get_viewport().set_input_as_handled()
		close()


func refresh() -> void:
	if _inventory == null:
		return

	var backpack_id: Variant = _inventory.equipped("back")
	if backpack_id == null:
		_equip_button.text = "Dos : vide"
		_equip_button.disabled = true
	else:
		_equip_button.text = "Dos : %s (clic pour retirer)" % ItemCatalog.display_name(backpack_id)
		_equip_button.disabled = false

	for child in _grid.get_children():
		child.queue_free()

	for i in _inventory.slot_count():
		_grid.add_child(_build_slot_button(i))


func _build_slot_button(index: int) -> Button:
	var slot = _inventory.get_slot(index)
	var button := Button.new()
	button.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	button.focus_mode = Control.FOCUS_NONE

	if slot == null:
		button.text = ""
		button.disabled = true
		button.add_theme_stylebox_override("disabled", IslandUI.flat(Color(IslandUI.INK, 0.05), 6))
	else:
		var item_id: int = slot["item"]
		var count: int = slot["count"]
		button.text = "%s\n%d" % [ItemCatalog.display_name(item_id), count] if count > 1 \
			else ItemCatalog.display_name(item_id)
		var style := IslandUI.flat(Color(ItemCatalog.color(item_id), 0.35), 6)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("hover", IslandUI.flat(Color(ItemCatalog.color(item_id), 0.5), 6))
		button.disabled = not ItemCatalog.is_equipment(item_id)
		if not button.disabled:
			button.pressed.connect(_on_slot_pressed.bind(index))

	return button


func _on_slot_pressed(index: int) -> void:
	if _inventory.equip_from_slot(index):
		_hint_label.text = ""
	else:
		_hint_label.text = "Impossible d'equiper cet objet la (emplacement deja pris ?)."
	refresh()


func _on_equip_slot_pressed() -> void:
	if not _inventory.unequip("back"):
		_hint_label.text = "Videz des cases avant de retirer le sac."
	else:
		_hint_label.text = ""
	refresh()
