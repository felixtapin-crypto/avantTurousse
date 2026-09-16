extends Node

# Defines the input actions in code (rather than in project.godot) so the
# key bindings are easy to read and change without hand-editing a .tscn-like
# config format. Uses physical keycodes so WASD stays in the same physical
# position on AZERTY keyboards (shown as Z/Q/S/D there).

func _init() -> void:
	_add_action("move_forward", KEY_W)
	_add_action("move_back", KEY_S)
	_add_action("move_left", KEY_A)
	_add_action("move_right", KEY_D)
	_add_action("jump", KEY_SPACE)


func _add_action(action_name: String, keycode: Key) -> void:
	if InputMap.has_action(action_name):
		return
	InputMap.add_action(action_name)
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	InputMap.action_add_event(action_name, event)
