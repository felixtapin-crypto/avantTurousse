class_name SurvivalBars
extends Control

# Trois barres (faim, soif, vie), en haut a droite, toujours affichees.
# Construites en code comme `Hotbar`/`Crosshair` - pas de `.tscn`. La vie
# reste visible en permanence (pas seulement sous 100 %) : la voir descendre
# des les premieres secondes de privation, plutot que d'apparaitre d'un coup
# a la moitie, est ce qui rend la menace lisible.

const BAR_WIDTH := 160.0
const BAR_HEIGHT := 10.0
const BAR_GAP := 6.0
const MARGIN_TOP := 16.0
const MARGIN_RIGHT := 16.0

const HUNGER_COLOR := Color("#e0a542")   # or, meme accent que le reste du HUD
const THIRST_COLOR := Color("#4fb3a5")   # lagon
const HEALTH_COLOR := Color("#e2725b")   # corail

var _hunger_fill: ColorRect
var _thirst_fill: ColorRect
var _health_fill: ColorRect


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 0.0

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", int(BAR_GAP))
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(column)

	_health_fill = _build_row(column, "Vie", HEALTH_COLOR)
	_hunger_fill = _build_row(column, "Faim", HUNGER_COLOR)
	_thirst_fill = _build_row(column, "Soif", THIRST_COLOR)

	custom_minimum_size = Vector2(BAR_WIDTH, 3.0 * BAR_HEIGHT + 2.0 * BAR_GAP)
	offset_left = -BAR_WIDTH - MARGIN_RIGHT
	offset_right = -MARGIN_RIGHT
	offset_top = MARGIN_TOP
	offset_bottom = MARGIN_TOP + custom_minimum_size.y


func _build_row(parent: Control, label_text: String, color: Color) -> ColorRect:
	var track := IslandUI.frame()
	track.custom_minimum_size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(track)

	var fill := ColorRect.new()
	fill.color = color
	fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.add_child(fill)

	# Legende discrete, superposee : cette barre est petite et lue de loin,
	# une legende a cote l'aurait poussee bien plus large que necessaire.
	var caption := IslandUI.label(label_text, 8, Color(IslandUI.INK, 0.7))
	caption.set_anchors_preset(Control.PRESET_TOP_LEFT)
	caption.position = Vector2(4, -1)
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.add_child(caption)

	return fill


func refresh(survival: SurvivalGauges) -> void:
	_set_fill(_hunger_fill, survival.hunger / SurvivalGauges.MAX)
	_set_fill(_thirst_fill, survival.thirst / SurvivalGauges.MAX)
	_set_fill(_health_fill, survival.health / SurvivalGauges.MAX)


func _set_fill(fill: ColorRect, ratio: float) -> void:
	fill.anchor_right = clampf(ratio, 0.0, 1.0)
