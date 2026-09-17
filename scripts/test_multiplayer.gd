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
#   5. la MATIERE d'un depot voyage avec sa geometrie ;
#   6. un objet au sol ne se ramasse QU'UNE FOIS, meme si les deux le veulent ;
#   7. l'heure d'un client desynchronise est recalee sur celle de l'hote.
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
const T_LINGER := 18.0

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
	# Point de DEPOT, a l'oppose : loin des corps, et deja dans la roche, donc
	# sans consequence physique. Ce qu'on y regarde n'est pas la geometrie mais
	# la MATIERE — voir le controle en fin de course.
	var dropped := home + Vector3(-9.0, -8.0, 0.0)
	await create_timer(T_NEAR - T_RETURN).timeout
	# Releve JUSTE AVANT le creusement : au retour, la zone n est pas encore
	# rechargee chez le client, et un bloc absent se lit 100.
	var mine_before := _sample(mine)
	if _role == "client":
		_world.request_terrain_edit(mine, 3.0, true)
		_say("le client creuse a cote de l'hote")
	else:
		# DEPOT, et non creusement : c'est le seul geste qui ecrit aussi la
		# MATIERE. La geometrie voyageait deja ; ce qu'on veut savoir ici, c'est
		# si la terre arrive en terre chez l'autre ou si elle y repousse en herbe.
		_world.request_terrain_edit(dropped, 3.0, false)
		_say("l'hote depose de la terre")

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
	# LA MATIERE VOYAGE-T-ELLE AVEC LA GEOMETRIE ?
	#
	# Un depot pose une sphere solide ET la peint en terre : `do_sphere` ne
	# touche que la geometrie, la matiere des voxels neufs resterait a sa valeur
	# par defaut, qui est l'herbe. Comme l'hote renvoie des BLOCS ENTIERS, tous
	# canaux confondus, les deux doivent se decider chez lui — sinon sa version
	# verte revient ecraser la terre peinte chez le creuseur, et le depot
	# reverdit chez tout le monde.
	var layer := _layer_at(dropped)
	_check("le depot de l'hote est en TERRE ici",
		layer == TerrainGenerator.Layer.DIRT,
		"matiere dominante %d (terre = %d)" % [layer, TerrainGenerator.Layer.DIRT])

	await _check_pickup()

	if _role == "client":
		_check("l'heure est recalee sur celle de l'hote",
			_world._sky.time_of_day > 0.02,
			"il est %s" % _world._sky.clock())
	_finish()


# UN OBJET NE SE RAMASSE QU'UNE FOIS, MEME SI LES DEUX LE DEMANDENT.
#
# Les objets sont tires de la graine : les deux pairs ont les memes, au meme
# rang. On demande donc LE MEME au meme instant, des deux cotes, et l'on
# verifie que l'hote n'en accorde qu'un — l'objet disparait chez tout le monde,
# mais un seul inventaire s'en trouve garni.
#
# C'est le controle qui manquait : le ramassage se decidait sur place, donc
# chacun prenait sa copie du meme caillou.
func _check_pickup() -> void:
	# LE MEME RANG DES DEUX COTES, en dur.
	#
	# Un premier jet demandait « le premier objet encore la ». Les deux n'ont
	# alors pas demande le meme : l'hote avait deja pris le rang 0, et il avait
	# disparu chez le client, qui s'est rabattu sur le rang 1. Chacun repartait
	# avec un objet — et le controle criait a la duplication alors qu'il ne
	# mettait personne en concurrence. Designer le rang lui-meme est la seule
	# facon de faire porter la demande sur un objet unique.
	const INDEX := 0
	# Le premier distribue est un caillou (voir `_scatter_items`), et on ne peut
	# pas le lire sur l'objet : chez le client, il a peut-etre deja disparu.
	var item_id := ItemCatalog.Id.ROCK
	var before: int = _world._local_player.inventory.count(item_id)
	_world.request_pickup(INDEX)
	await create_timer(3.0).timeout
	var after: int = _world._local_player.inventory.count(item_id)

	_check("l'objet disparait chez les deux",
		_world._pickup_at(INDEX) == null, "rang %d" % INDEX)
	# L'hote demande une seconde avant le client — c'est le decalage de
	# demarrage sur lequel tout le banc repose. Il l'emporte donc, et le client
	# repart les mains vides : c'est exactement ce que l'ancien ramassage local
	# ne faisait pas, les deux se servant dans leur copie.
	if _role == "hote":
		_check("l'hote, arrive le premier, l'obtient", after == before + 1,
			"inventaire %d -> %d" % [before, after])
	else:
		_check("le client, arrive apres, n'obtient rien", after == before,
			"inventaire %d -> %d" % [before, after])


# Matiere dominante d'un voxel : quatre index, quatre poids, on rend celui qui
# pese le plus. C'est l'encodage que `TerrainGenerator` ecrit et que le shader
# lit — le relire ici, c'est verifier ce qui sera reellement affiche.
func _layer_at(at: Vector3) -> int:
	if _world._tool == null:
		return -1
	var pos := Vector3i(at.round())
	_world._tool.channel = VoxelBuffer.CHANNEL_INDICES
	var indices := VoxelTool.u16_indices_to_vec4i(_world._tool.get_voxel(pos))
	_world._tool.channel = VoxelBuffer.CHANNEL_WEIGHTS
	var weights := VoxelTool.u16_weights_to_color(_world._tool.get_voxel(pos))
	# Le reste du monde suppose le canal de distance signee actif.
	_world._tool.channel = VoxelBuffer.CHANNEL_SDF

	var best := -1
	var best_weight := -1.0
	for k in 4:
		if weights[k] > best_weight:
			best_weight = weights[k]
			best = indices[k]
	return best


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
