extends Node3D

const PlayerScene := preload("res://scenes/player/player.tscn")

# TODO: viendra de la sauvegarde / d'un ecran "nouvelle partie" une fois ce
# systeme en place (voir DESIGN.md, section Sauvegarde). Pour l'instant fixe
# pour que la plateforme soit reproductible pendant qu'on teste.
const PLATFORM_SEED := 1

const FALL_LIMIT_Y := -30.0

@onready var platform: Platform = $Platform
@onready var players_root: Node3D = $Players
@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var game_over_panel: Control = $GameOverLayer/GameOverPanel

var game_over := false


func _ready() -> void:
	platform.generate(PLATFORM_SEED)

	spawner.spawn_path = players_root.get_path()
	spawner.spawn_function = _spawn_player

	if multiplayer.is_server():
		Network.player_connected.connect(_on_player_connected)
		Network.player_disconnected.connect(_on_player_disconnected)
		for id in Network.players.keys():
			spawner.spawn(id)


func _process(_delta: float) -> void:
	if game_over:
		return
	for player in players_root.get_children():
		if player.global_position.y < FALL_LIMIT_Y:
			_trigger_game_over()
			return


func _spawn_player(id: int) -> Node:
	var player := PlayerScene.instantiate()
	player.name = str(id)
	var offset := Vector2(players_root.get_child_count() * 2.5, 0.0)
	player.position = platform.get_spawn_position(offset)
	return player


func _on_player_connected(id: int, _player_name: String) -> void:
	spawner.spawn(id)


func _on_player_disconnected(id: int) -> void:
	var p := players_root.get_node_or_null(str(id))
	if p:
		p.queue_free()


func _trigger_game_over() -> void:
	game_over = true
	game_over_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _on_quit_pressed() -> void:
	Network.leave_game()
	get_tree().change_scene_to_file("res://scenes/main_menu/main_menu.tscn")
