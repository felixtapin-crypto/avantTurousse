extends Control

@onready var address_edit: LineEdit = $CenterContainer/VBoxContainer/AddressEdit
@onready var status_label: Label = $CenterContainer/VBoxContainer/StatusLabel


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Network.player_connected.connect(_on_player_connected)
	Network.connection_failed.connect(_on_connection_failed)


func _on_host_pressed() -> void:
	Network.host_game()
	status_label.text = "Serveur lance, en attente de joueurs..."
	_go_to_world()


func _on_join_pressed() -> void:
	var address := address_edit.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	status_label.text = "Connexion a %s..." % address
	Network.join_game(address)


func _on_player_connected(_id: int, _player_name: String) -> void:
	if not multiplayer.is_server():
		_go_to_world()


func _on_connection_failed() -> void:
	status_label.text = "Connexion echouee."


func _go_to_world() -> void:
	get_tree().change_scene_to_file("res://scenes/world/world.tscn")
