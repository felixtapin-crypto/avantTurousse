extends Node

# Thin wrapper around Godot's high-level ENet multiplayer API.
# One player hosts (acts as server + player 1), the other joins their IP.

const PORT := 7777
const MAX_PLAYERS := 8

signal player_connected(id: int, player_name: String)
signal player_disconnected(id: int)
signal server_disconnected
signal connection_failed
# Emis chez le CLIENT quand les reglages de monde de l'hote sont arrives.
signal world_received

var players: Dictionary = {}
var player_name: String = "Player"
# L'hote a-t-il ARRETE son choix de monde ?
#
# Il heberge avant de choisir sa carte, donc un client peut se connecter
# pendant qu'il est encore dans le menu des mondes. Lui envoyer les reglages a
# cet instant l'enverrait dans le monde PAR DEFAUT, et l'hote le rejoindrait
# ensuite dans un autre. On n'annonce donc qu'au moment ou l'hote entre en
# partie, et un client arrive plus tot patiente.
var world_ready := false

# Avons-nous ouvert un pair NOUS-MEMES ?
#
# `multiplayer.has_multiplayer_peer()` ne repond PAS a cette question. Godot
# installe un pair « hors ligne » par defaut, qui porte l'identifiant 1 : la
# fonction rend donc vrai en solo, et `is_server()` avec elle. Le temoin
# d'hebergement s'allumait ainsi sur une partie a un joueur, annoncant qu'on
# attendait quelqu'un qui n'avait aucune raison de venir.
#
# Mesure a l'appui : une capture de l'ecran d'apercu, instancie seul dans un
# arbre vide, affichait « PARTIE OUVERTE, EN ATTENTE D'UN JOUEUR ».
var _online := false


func _ready() -> void:
	# LE RESEAU NE SE MET PAS EN PAUSE.
	#
	# Le menu de pause fige l'arbre, et un arbre fige ne remet plus ses
	# messages : un client en pause n'apprendrait la fermeture de la partie
	# qu'en la reprenant. Or c'est justement quand il ne joue pas qu'il a le
	# plus de chances de manquer le depart de l'hote.
	process_mode = Node.PROCESS_MODE_ALWAYS
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connected_fail)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# Une partie EN RESEAU est-elle ouverte ? Voir `_online`.
func is_online() -> bool:
	return _online


# Sommes-nous l'hote d'une partie en reseau ?
func is_hosting() -> bool:
	return _online and multiplayer.is_server()


func host_game() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		push_error("Impossible de creer le serveur (code %s)" % err)
		return
	multiplayer.multiplayer_peer = peer
	_online = true
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
	_online = true


func leave_game() -> void:
	multiplayer.multiplayer_peer = null
	_online = false
	players.clear()
	world_ready = false


# LA GRAINE DOIT TRAVERSER LE FIL, et c'est ce qui rend le monde gratuit a
# partager.
#
# Tout ici se rederive de la graine : relief, climat, biomes, rivieres,
# grottes. Deux machines qui partent de la meme graine obtiennent la meme ile
# au voxel pres, sans qu'un seul bloc ne transite. C'est la raison pour
# laquelle les grottes sont EVALUEES et non creusees (voir `cave_network.gd`),
# et pourquoi aucun `VoxelStream` n'est configure.
#
# Sans cet envoi, un client genererait sa propre ile avec sa propre graine et
# les deux joueurs joueraient chacun la sienne — sans que rien ne le signale,
# puisque les deux mondes seraient parfaitement valides.
#
# Repond a une partie de #31 : la graine sort du code et voyage a la connexion.
# Restent a transporter les positions des joueurs et le creusement.
#
# Annonce le monde a tous les joueurs deja connectes, et ouvre la porte a ceux
# qui arriveront ensuite. Appelee par l'hote quand il entre en partie.
func announce_world() -> void:
	world_ready = true
	for id in players:
		if id != 1:
			send_world(id)


# L'hote ne propose plus son monde.
#
# Appelee quand il quitte la partie, AVANT la vidange de la file de generation
# — qui dure plusieurs secondes, pendant lesquelles le serveur repond encore.
# Sans cela, un client qui se connecte dans cette fenetre recevrait les reglages
# d'un monde qu'on est en train de fermer et entrerait dans une partie dont
# l'hote s'en va, pour en etre ejecte une seconde plus tard.
#
# `leave_game()` le fait aussi, mais trop tard : il n'est appele qu'a l'arrivee
# sur l'ecran d'accueil.
func close_world() -> void:
	world_ready = false


func send_world(id: int) -> void:
	_receive_world.rpc_id(id, {
		"seed": WorldSettings.seed_value,
		"size": WorldSettings.size,
		"height": WorldSettings.height,
		"day_length": WorldSettings.day_length_seconds,
		"start_time": WorldSettings.start_time_of_day,
	})


@rpc("authority", "call_remote", "reliable")
func _receive_world(settings: Dictionary) -> void:
	WorldSettings.seed_value = int(settings.get("seed", WorldSettings.seed_value))
	WorldSettings.size = int(settings.get("size", WorldSettings.size))
	WorldSettings.height = int(settings.get("height", WorldSettings.height))
	WorldSettings.day_length_seconds = float(
		settings.get("day_length", WorldSettings.day_length_seconds))
	WorldSettings.start_time_of_day = float(
		settings.get("start_time", WorldSettings.start_time_of_day))
	# Une carte preparee pour d'AUTRES reglages ne vaut plus rien : la laisser
	# ferait entrer le client dans l'ile qu'il avait calculee avant de se
	# connecter.
	WorldSettings.prepared_map = null
	world_received.emit()


func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		players[id] = "Player %d" % id
		player_connected.emit(id, players[id])
		if world_ready:
			send_world(id)


func _on_peer_disconnected(id: int) -> void:
	players.erase(id)
	player_disconnected.emit(id)


func _on_connected_ok() -> void:
	var id := multiplayer.get_unique_id()
	players[id] = player_name
	player_connected.emit(id, player_name)


func _on_connected_fail() -> void:
	multiplayer.multiplayer_peer = null
	_online = false
	connection_failed.emit()


func _on_server_disconnected() -> void:
	multiplayer.multiplayer_peer = null
	_online = false
	world_ready = false
	players.clear()
	server_disconnected.emit()
