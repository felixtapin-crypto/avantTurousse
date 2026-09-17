class_name Crosshair
extends Control

# Repere fixe au centre de l'ecran : la souris etant capturee en permanence
# (voir `VoxelDebugPlayer._ready`), il n'y a plus de curseur visible pour
# montrer ou pointe le regard. `VoxelDebugPlayer._edit` vise ce meme point
# (centre de l'ecran), donc ce que ce reticule montre est exactement ce que
# le clic va toucher.

const SIZE := 20.0
const LINE_LENGTH := 6.0
const GAP := 3.0
const THICKNESS := 2.0
const COLOR := Color(1, 1, 1, 0.85)


func _ready() -> void:
	# Ne doit jamais voler un clic destine au jeu ou a une UI derriere.
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var center := Vector2(SIZE, SIZE) / 2.0
	for dir in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		draw_line(
			center + dir * GAP,
			center + dir * (GAP + LINE_LENGTH),
			COLOR, THICKNESS)
