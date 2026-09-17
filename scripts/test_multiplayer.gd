extends SceneTree

# Banc d'essai du multijoueur, A DEUX PROCESSUS.
#
#   godot --headless --path . --script res://scripts/test_multiplayer.gd -- hote
#   godot --headless --path . --script res://scripts/test_multiplayer.gd -- client
#
# Lancer l'hote d'abord, le client dans la foulee. Chacun ecrit des lignes
# prefixees `HOTE` ou `CLIENT`, et une derniere ligne `VERDICT`.
#
# POURQUOI UN BANC ET PAS DEUX FENETRES. Le reste du projet se verifie par
# `verify_voxel_rules.gd`, qui interroge le generateur ; le reseau, lui, ne peut
# pas se verifier dans un seul processus — la boucle d'un pair sur lui-meme ne
# passe par aucun socket et ne prouve rien. Deux processus qui se parlent par
# ENet, c'est la seule facon de savoir si la poignee de main tient.
#
# IL A DEJA SERVI, DEUX FOIS.
#
# Sa premiere execution a montre que le corps de l'hote restait fige a son point
# d'apparition chez le client, alors que celui du client bougeait bien chez
# l'hote : la replication ne marchait que dans le sens ou l'ordre d'arrivee lui
# etait favorable (voir la note sur la visibilite dans `voxel_debug_player.gd`).
# La seconde a montre qu'un de ses propres controles passait pour la mauvaise
# raison — voir `T_LINGER`.
#
# Ce que le banc regarde, dans l'ordre ou les choses doivent arriver :
#
#   1. la graine arrive chez le client, et il entre dans le monde ;
#   2. les DEUX corps existent chez les DEUX pairs ;
#   3. le corps d'en face BOUGE quand son proprietaire bouge ;
#   4. un creusement fait par l'hote se voit chez le client PARTI AILLEURS,
#      quand il revient ;
#   5. l'heure d'un client desynchronise est recalee sur celle de l'hote.
#
# Il ne regarde PAS ce qui se voit a l'oeil : le rendu, la camera, l'interface.

const SCENE := "res://scenes/voxel_world/smooth_voxel_world.tscn"
const MAP_SIZE := 300
const SEED := 7

# DISTANCE DE VUE VOLONTAIREMENT COURTE.
#
# C'est ce qui rend le controle 4 concluant. A 256 m — le reglage normal — un
# pair charge l'ile entiere depuis n'importe ou sur une carte de 300, donc il
# recevrait le creusement par l'appel direct et le banc ne dirait rien du
# synchroniseur de terrain. A 64 m, un client parti a 120 m n'a plus la zone :
# seul un envoi de BLOCS peut la lui rendre.
const VIEW_DISTANCE := 64
const AWAY := Vector3(120.0, 0.0, 0.0)

# Calendrier, en secondes depuis le demarrage du processus. Genereux : la carte
# se calcule, puis le terrain se met en flux, et l'un comme l'autre prennent
# plusieurs secondes.
#
# Les deux processus ne partent pas au meme instant — le client suit l'hote
# d'environ une seconde — donc chaque etape garde plusieurs secondes de marge
# sur la suivante. Le premier jet n'en avait pas, et le client relevait sa
# mesure « avant creusement » APRES que l'hote eut creuse : le controle passait
# sans rien prouver.
const T_ENTER := 3.0
const T_MOVE := 14.0
const T_BEFORE := 19.0
const T_AWAY := 21.0
const T_EDIT := 27.0
const T_RETURN := 32.0
const T_NEAR := 38.0
const T_DESYNC := 42.0
const T_REPORT := 54.0

# L HOTE SURVIT AU CLIENT.
#
# Son depart coupe la partie chez le client : le monde y vide sa file de
# generation, libere le spectateur et decharge ses blocs. Le client lisait alors
# 100 partout et croyait voir un creusement la ou il ne voyait plus rien du
# tout — un controle qui passait pour la mauvaise raison.
const T_LINGER := 14.0

# De combien on pousse le corps local, a chaque fois.
const NUDGE := Vector3(6.0, 0.0, 6.0)

var _role := "hote"
var _world: Node3D
var _net: Node
var _log: Array[String] = []


func _initialize() -> void:
	_watchdog()
	var args := OS.get_cmdline_user_args()
	_role = args[0] if args.size() > 0 else "hote"
	_net = root.get_node("Network")
	_run()


func _say(text: String) -> void:
	print("%s %s" % [_role.to_upper(), text])


func _check(label: String, ok: bool, detail: String = "") -> void:
	_log.append("%s %s" % ["OK" if ok else "ECHEC", label])
	_say("%s %s%s" % ["ok   " if ok else "ECHEC", label,
		"" if detail == "" else " : " + detail])


func _run() -> void:
	await process_frame

	WorldSettings.seed_value = SEED
	WorldSettings.size = MAP_SIZE
	WorldSettings.prepared_map = null
	GameSettings.view_distance = VIEW_DISTANCE

	if _role == "hote":
		_net.host_game()
		_say("serveur ouvert sur le port %d" % _net.PORT)
	else:
		_net.join_game("127.0.0.1")
		_say("connexion a 127.0.0.1...")
		# LE CLIENT N'ENTRE PAS DE LUI-MEME : il attend les reglages de l'hote,
		# sans quoi il genererait une autre ile. C'est le premier point a
		# verifier.
		var got := await _await_signal(_net.world_received, 20.0)
		_check("la graine de l'hote arrive", got,
			"graine %d, etendue %d" % [WorldSettings.seed_value, WorldSettings.size])
		if not got:
			_finish()
			return

	await create_timer(T_ENTER).timeout
	_world = load(SCENE).instantiate()
	root.add_child(_world)
	_say("monde ouvert")

	await create_timer(T_MOVE - T_ENTER).timeout
	_check("mon corps existe", _world._local_player != null,
		"id %s" % ("aucun" if _world._local_player == null
			else _world._local_player.name))
	_check("le corps d'en face existe", _remote_body() != null)
	_nudge()

	await create_timer(T_BEFORE - T_MOVE).timeout
	var home: Vector3 = _world._spawn_position(0)
	var target := home + Vector3(0.0, -8.0, 0.0)
	var before := _sample(target)
	var remote_before := _remote_position()
	_say("avant : roche %.3f en %s, corps d'en face en %s"
		% [before, target, remote_before])

	# --- Le client s'eloigne, l'hote creuse en son absence ---
	await create_timer(T_AWAY - T_BEFORE).timeout
	if _role == "client":
		_teleport(home + AWAY)
		_say("parti a %d m" % int(AWAY.length()))

	await create_timer(T_EDIT - T_AWAY).timeout
	if _role == "hote":
		_world.request_terrain_edit(target, 3.0, true)
		_say("creusement demande, le client est loin")
	else:
		# LA PREUVE QUE L'APPEL DIRECT NE PEUT PAS AVOIR SERVI : au moment ou
		# l'hote creuse, le client n'a pas la zone en memoire, donc il aurait
		# refuse d'y sculpter. Ce qu'il verra au retour ne peut venir que des
		# blocs envoyes par le synchroniseur.
		_check("la zone est hors de portee du client pendant le creusement",
			not _editable(target))
	_nudge()

	# --- Le client revient ---
	await create_timer(T_RETURN - T_EDIT).timeout
	if _role == "client":
		_teleport(home)
		_say("de retour au point de depart")

	# --- Le client creuse a son tour, les deux etant cote a cote ---
	#
	# C'est l'autre sens, et le cas de PROXIMITE. Il etait couvert par un appel
	# diffuse a tous les pairs, retire depuis : le synchroniseur pousse la zone
	# modifiee a ceux qui la regardent, et ce controle-ci le verifie.
	var mine := home + Vector3(7.0, -8.0, 0.0)
	await create_timer(T_NEAR - T_RETURN).timeout
	# Releve JUSTE AVANT le creusement : au retour, la zone n est pas encore
	# rechargee chez le client, et un bloc absent se lit 100.
	var mine_before := _sample(mine)
	if _role == "client":
		_world.request_terrain_edit(mine, 3.0, true)
		_say("le client creuse a cote de l'hote")

	await create_timer(T_DESYNC - T_NEAR).timeout
	if _role == "client":
		# ON DESYNCHRONISE EXPRES. Sans cela les deux horloges resteraient
		# proches toutes seules — elles partent de la meme heure — et le
		# controle passerait sans rien prouver.
		_world._sky.time_of_day = 0.0
		_say("horloge du client forcee a 00:00")

	await create_timer(T_REPORT - T_DESYNC).timeout
	var after := _sample(target)
	var remote_after := _remote_position()

	_check("le corps d'en face a bouge",
		remote_before.distance_to(remote_after) > 1.0,
		"%s -> %s" % [remote_before, remote_after])
	_say("diagnostic : zone editable=%s, corps=%d, spectateurs=%d"
		% [_editable(target), _world.players_root.get_child_count(),
			_world.find_children("*", "VoxelViewer", true, false).size()])
	# La roche etait PLEINE (distance signee negative) et devient du VIDE
	# (positive) : c'est bien le creusement, et pas un bloc absent — un bloc
	# absent se lit 100.
	var mine_after := _sample(mine)
	_check("le creusement demande par le client se voit ici",
		mine_before < 0.0 and mine_after > 0.0 and mine_after < 50.0,
		"distance signee %.3f -> %.3f" % [mine_before, mine_after])
	_check("le creusement de l'hote se voit ici",
		before < 0.0 and after > 0.0 and after < 50.0,
		"distance signee %.3f -> %.3f" % [before, after])
	if _role == "client":
		_check("l'heure est recalee sur celle de l'hote",
			_world._sky.time_of_day > 0.02,
			"il est %s" % _world._sky.clock())
	_finish()


func _remote_body() -> Node3D:
	for body in _world.players_root.get_children():
		if body != _world._local_player:
			return body as Node3D
	return null


func _remote_position() -> Vector3:
	var body := _remote_body()
	return Vector3.INF if body == null else body.global_position


func _nudge() -> void:
	if _world._local_player != null:
		_world._local_player.position += NUDGE


func _teleport(to: Vector3) -> void:
	if _world._local_player == null:
		return
	_world._local_player.position = to
	_world._local_player.snap_camera()


func _sample(at: Vector3) -> float:
	if _world._tool == null:
		return NAN
	return _world._tool.get_voxel_f(Vector3i(at.round()))


func _editable(at: Vector3) -> bool:
	if _world._tool == null:
		return false
	return _world._tool.is_area_editable(
		AABB(at - Vector3.ONE * 3.0, Vector3.ONE * 6.0))


func _await_signal(sig: Signal, timeout: float) -> bool:
	var box := {"fired": false}
	sig.connect(func(): box["fired"] = true, CONNECT_ONE_SHOT)
	var waited := 0.0
	while waited < timeout and not box["fired"]:
		await create_timer(0.25).timeout
		waited += 0.25
	return box["fired"]


func _finish() -> void:
	await process_frame
	var failed := 0
	for line in _log:
		if line.begins_with("ECHEC"):
			failed += 1
	if _role == "hote":
		await create_timer(T_LINGER).timeout
	print("VERDICT %s : %d controle(s), %d echec(s)" % [
		_role.to_upper(), _log.size(), failed])
	quit(0 if failed == 0 else 1)


# GARDE-FOU : le banc ne doit jamais PENDRE.
#
# Toute la sequence vit dans une coroutine. Une erreur au milieu — une scene
# qui ne charge pas, un noeud absent — la tue en silence : `quit()` n'est
# jamais atteint, le processus reste en vie, et il garde le port 7777. L'essai
# suivant echoue alors sur « Couldn't create an ENet host » et l'on cherche la
# panne au mauvais endroit. C'est exactement ce qui est arrive.
#
# Un essai qui echoue se lit ; un essai qui pend fait perdre du temps aux deux
# suivants.
const T_WATCHDOG := 90.0


func _watchdog() -> void:
	await create_timer(T_WATCHDOG).timeout
	printerr("VERDICT %s : ABANDON, rien n'a abouti en %d s"
		% [_role.to_upper(), int(T_WATCHDOG)])
	quit(2)
