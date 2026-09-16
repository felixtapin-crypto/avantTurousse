extends Node3D

const PlayerScene := preload("res://scenes/player/player.tscn")

@onready var spawn_points: Node3D = $SpawnPoints
@onready var players_root: Node3D = $Players
@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner


func _ready() -> void:
	spawner.spawn_path = players_root.get_path()
	spawner.spawn_function = _spawn_player

	if multiplayer.is_server():
		Network.player_connected.connect(_on_player_connected)
		Network.player_disconnected.connect(_on_player_disconnected)
		for id in Network.players.keys():
			spawner.spawn(id)


func _spawn_player(id: int) -> Node:
	var player := PlayerScene.instantiate()
	player.name = str(id)
	var points := spawn_points.get_children()
	var index := players_root.get_child_count() % points.size()
	player.position = points[index].position
	return player


func _on_player_connected(id: int, _player_name: String) -> void:
	spawner.spawn(id)


func _on_player_disconnected(id: int) -> void:
	var p := players_root.get_node_or_null(str(id))
	if p:
		p.queue_free()
