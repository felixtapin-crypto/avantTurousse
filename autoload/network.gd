extends Node

# Thin wrapper around Godot's high-level ENet multiplayer API.
# One player hosts (acts as server + player 1), the other joins their IP.

const PORT := 7777
const MAX_PLAYERS := 8

signal player_connected(id: int, player_name: String)
signal player_disconnected(id: int)
signal server_disconnected
signal connection_failed

var players: Dictionary = {}
var player_name: String = "Player"


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connected_fail)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func host_game() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		push_error("Impossible de creer le serveur (code %s)" % err)
		return
	multiplayer.multiplayer_peer = peer
	players[1] = player_name
	player_connected.emit(1, player_name)


func join_game(address: String) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		push_error("Impossible de rejoindre %s (code %s)" % [address, err])
		connection_failed.emit()
		return
	multiplayer.multiplayer_peer = peer


func leave_game() -> void:
	multiplayer.multiplayer_peer = null
	players.clear()


func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		players[id] = "Player %d" % id
		player_connected.emit(id, players[id])


func _on_peer_disconnected(id: int) -> void:
	players.erase(id)
	player_disconnected.emit(id)


func _on_connected_ok() -> void:
	var id := multiplayer.get_unique_id()
	players[id] = player_name
	player_connected.emit(id, player_name)


func _on_connected_fail() -> void:
	multiplayer.multiplayer_peer = null
	connection_failed.emit()


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	players.clear()
	server_disconnected.emit()
