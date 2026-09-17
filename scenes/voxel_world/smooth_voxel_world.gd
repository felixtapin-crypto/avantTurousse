extends Node3D

# Monde de jeu : terrain lisse (Transvoxel) genere depuis une `WorldMap`.
#
# Un rendu en blocs a existe en parallele le temps de comparer les deux
# directions artistiques ; le lisse l'a emporte et l'autre a ete retire (voir
# issue #34). Restent deux consequences a retrancher un jour, qui ne sont pas
# visuelles :
#
# - creuser est du sculptage a la sphere, pas du retrait de bloc, alors que
#   `DESIGN.md` demande de "poser des voxels/blocs pour batir une cabane" ;
# - la bedrock ne peut plus etre protegee bloc par bloc, il faudra borner la
#   distance signee dans le generateur.

const PLAYER_SCENE := preload("res://scenes/voxel_world/voxel_player.tscn")

@onready var players_root: Node3D = $Players
@onready var status_label: Label = $Hud/StatusLabel

# Le corps qu'ON PILOTE. Les autres sont des avatars, sans camera ni physique.
# Chez un client il n'existe pas encore au `_ready` du monde : il arrive avec la
# liste que renvoie le serveur. Voir `_setup_players` et `_attach_player`.
var _local_player: CharacterBody3D

# Qui est PRESENT dans le monde. Tenue par le serveur seul ; les clients ne font
# qu'appliquer la liste qu'il leur envoie. Voir `_setup_players`.
var _present := {}

var _exit_bar: Control
var _exit_fill: ColorRect
var _exit_label: Label
var _water_veil: ColorRect
var _camera: Camera3D
var _pause_menu: PauseMenu
var _settings_screen: SettingsScreen
var _crosshair: Crosshair
var _hotbar: Hotbar
var _inventory_screen: InventoryScreen
var _viewer: VoxelViewer
# Provisoire : voir la section LAMPE DE GROTTE en bas de fichier.
var _cave_lamp: OmniLight3D

@export var world_seed: int = 1
@export var map_size: int = 600
@export var map_height: int = 64
# Distance de vue, en metres.
#
# Ramenee de 384 a 256, et c'est un choix mesure plutot qu'un reglage de
# confort. Le nombre de blocs a generer croit avec le CARRE de cette valeur :
# 256 en demande 44 % de ce que demandait 384. Or notre generateur est en
# GDScript, il tient environ cinq millisecondes par bloc, et sa file d'attente
# ne s'annule pas — quitter la partie attend qu'elle se vide, ce qui prenait
# jusqu'a deux minutes.
#
# Ce qu'on perd se voit a peine : a la densite de brouillard reglee dans
# SkyCycle, il ne reste que 54 % de visibilite a 384 m. Le lointain est deja
# peint par la perspective aerienne, pas par la geometrie.
@export var view_distance: int = 256

const MESSAGE_DURATION := 2.5

# Ecart entre deux points d apparition, en metres.
const SPAWN_SPACING := 3

var map: WorldMap
var terrain: VoxelTerrain
var _tool: VoxelTool
var _message := ""
var _message_timer := 0.0
var _sky: SkyCycle
var _sea: Sea
var _river_splines: RiverSplines
# La sortie est-elle engagee ? Voir `_unhandled_input` et `_announce_exit`.
var _leaving := false


func _ready() -> void:
	status_label.text = "Calcul de la carte..."
	# ORDRE D'EMPILEMENT, du fond vers le dessus : le voile d'immersion, le
	# viseur, la barre d'outils, l'ecran d'inventaire, le menu de pause, puis
	# la barre de sortie. Quitter depuis le menu de pause doit montrer le
	# voile de transition, et non le menu par-dessus ; l'ecran d'inventaire
	# doit passer au-dessus de la barre d'outils mais rester sous la pause
	# (la pause prime sur l'inventaire, voir `_open_pause`).
	_build_water_veil()
	_build_crosshair()
	_build_hotbar()
	_build_inventory_screen()
	_build_pause_menu()
	_build_exit_bar()
	_watch_network()

	# La distance de vue est un REGLAGE DU JOUEUR : elle ne depend ni de la
	# carte ni de la partie, et elle se retrouve d'une session a l'autre.
	view_distance = GameSettings.view_distance

	# Reglages venus de l'ecran d'apercu, si la partie est passee par lui.
	world_seed = WorldSettings.seed_value
	map_size = WorldSettings.size

	var started := Time.get_ticks_msec()
	map = WorldSettings.take_map()
	if map == null:
		# Lancee directement, sans passer par l'ecran de generation : le cache
		# evite de repayer les secondes de calcul a chaque essai.
		map = MapCache.load_or_generate(world_seed, map_size, map_height)
	var map_ms := Time.get_ticks_msec() - started

	# La carte est RENDUE aux reglages, pour que l'ecran de generation la
	# retrouve telle quelle si l'on y revient. Sans ca, quitter la partie coute
	# une relecture complete du cache — plusieurs secondes sur une carte de 800,
	# pour retomber sur l'objet qu'on vient de fermer.
	WorldSettings.prepared_map = map

	var generator := TerrainGenerator.new()
	generator.map = map

	terrain = VoxelTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.generator = generator
	terrain.mesher = _build_mesher()
	terrain.generate_collisions = true
	terrain.max_view_distance = view_distance
	terrain.bounds = AABB(
		Vector3.ZERO,
		Vector3(float(map_size), float(map_height), float(map_size)))
	terrain.material_override = _terrain_material()
	add_child(terrain)

	_tool = terrain.get_voxel_tool()
	# En lisse, l'outil travaille sur la distance signee, pas sur un type.
	_tool.channel = VoxelBuffer.CHANNEL_SDF

	_build_terrain_sync()
	_setup_players()

	_add_sky()
	_add_sea()
	_add_rivers()
	_scatter_items()

	# L'hote annonce SON monde en entrant en partie, et pas avant : c'est ici
	# que ses reglages sont arretes. Un client connecte plus tot patiente sur
	# l'ecran d'accueil jusqu'a ce moment — voir `network.gd`.
	if Network.is_hosting():
		Network.announce_world()

	status_label.text = "Carte calculee en %d ms — streaming en cours..." % map_ms
	# Les entrees de grottes sont annoncees dans la console : sans leurs
	# coordonnees elles sont introuvables sur une ile de plusieurs centaines de
	# metres, et c'est exactement le defaut qui rendait les anciennes grottes
	# inutiles. A remplacer par un vrai repere en jeu (voir issue #8).
	var entrances := map.cave_entrances()
	print("%d salles, %d entrees de grotte :" % [map.cave_rooms().size(), entrances.size()])
	for entrance in entrances:
		print("  entree en x=%d y=%d z=%d" % [entrance.x, entrance.y, entrance.z])


# ===========================================================================
# LES JOUEURS
# ===========================================================================
#
# UN CORPS PAR JOUEUR PRESENT DANS LE MONDE. Le nom du noeud est l'identifiant
# du pair, donc chacun sait en arrivant lequel il pilote (voir
# `voxel_debug_player.gd`), et le chemin `Players/<id>` est le meme partout —
# ce dont le synchroniseur de chaque corps a besoin pour retrouver son jumeau.
#
# PRESENT N'EST PAS CONNECTE, et c'est toute la difficulte.
#
# Un client se connecte pendant que l'hote est encore dans son menu des mondes :
# a cet instant, aucune scene de jeu n'existe ni chez l'un ni chez l'autre. Un
# `MultiplayerSpawner` y perd son latin — il diffuse ses apparitions aux pairs
# CONNECTES, donc a un client qui n'a pas encore de monde ou les poser, et le
# message tombe dans le vide. Le client entrerait dans une ile vide, sans meme
# son propre corps.
#
# Le serveur tient donc la liste de ceux qui sont VRAIMENT ENTRES : chacun le
# lui annonce en arrivant, et la liste complete est renvoyee a tout le monde.
# Chaque pair cree ce qui manque et retire ce qui est parti. Un arrivant tardif
# recoit la liste entiere, donc les corps de ceux qui l'ont precede.
#
# En solo, la liste tient en un nom et ne voyage pas.
func _setup_players() -> void:
	if not Network.is_online():
		_set_roster([1])
		return
	if multiplayer.is_server():
		_present[1] = true
		_publish_roster()
		return
	_entered_world.rpc_id(1)


@rpc("any_peer", "reliable")
func _entered_world() -> void:
	if not multiplayer.is_server():
		return
	_present[multiplayer.get_remote_sender_id()] = true
	_publish_roster()


func _publish_roster() -> void:
	# TRIEE, parce que le rang dans la liste decide du point d'apparition : deux
	# pairs qui l'ordonnent differemment poseraient le meme joueur a deux
	# endroits.
	# Diffusee A CHAQUE PRESENT plutot qu a la cantonade, pour la meme raison
	# que l horloge : un pair connecte sans monde ne peut pas la recevoir.
	var ids: Array = _present.keys()
	ids.sort()
	for id in ids:
		if int(id) != 1:
			_set_roster.rpc_id(int(id), ids)
	_set_roster(ids)


@rpc("authority", "call_remote", "reliable")
func _set_roster(ids: Array) -> void:
	for rank in ids.size():
		var id := int(ids[rank])
		if not players_root.has_node(str(id)):
			_add_player(id, rank)
	for body in players_root.get_children():
		if not ids.has(body.name.to_int()):
			body.queue_free()
	_show_local_body_to(ids)


# OUVRE NOTRE CORPS AUX AUTRES, un par un.
#
# Le synchroniseur de chaque corps est en visibilite declaree (voir
# `voxel_debug_player._configure_replication`) : sans cet appel, personne ne
# verrait jamais personne bouger. On ne l'ouvre qu'a des pairs qu'on sait
# PRESENTS, ce qui est tout l'interet — l'annonce part quand le destinataire a
# de quoi la recevoir, et non quand il se trouve simplement connecte.
func _show_local_body_to(ids: Array) -> void:
	if _local_player == null or not Network.is_online():
		return
	var me := multiplayer.get_unique_id()
	for id in ids:
		if int(id) != me:
			_local_player.sync.set_visibility_for(int(id), true)


func _add_player(id: int, rank: int) -> void:
	var body := PLAYER_SCENE.instantiate()
	body.name = str(id)
	# Decales les uns des autres, faute de quoi deux joueurs apparaissent dans
	# la meme capsule et se repoussent violemment a la premiere image.
	body.position = _spawn_position(rank)
	# `add_child` appelle `_ready` tout de suite : le corps sait donc deja s'il
	# est le notre quand on l'equipe.
	players_root.add_child(body)
	_attach_player(body)


# Ce que le monde donne a un corps : l'outil de creusement et lui-meme, pour
# tous ; la camera, le spectateur de streaming et la lampe, pour le seul qu'on
# pilote.
func _attach_player(body: CharacterBody3D) -> void:
	if body == null:
		return
	body.world = self
	body.voxel_tool = _tool
	if not body.is_multiplayer_authority():
		if multiplayer.is_server():
			_attach_remote_viewer(body)
		return

	_local_player = body
	body.edit_refused.connect(_on_edit_refused)
	# L inventaire est celui du corps QU ON PILOTE : la barre rapide et l ecran
	# d inventaire ne montrent que le sien, et l avatar du compagnon n a pas a
	# ouvrir d interface chez nous.
	body.inventory_toggle_requested.connect(_toggle_inventory)
	body.flying = true
	# La camera est en `top_level` : elle ne suit pas un saut de position, il
	# faut la recoller apres l'apparition. Voir `PlayerCamera.snap`.
	body.snap_camera()
	# C est l OEIL qui passe sous la surface, et il le fait avant les pieds.
	_camera = body.camera

	# LE SPECTATEUR SUIT LE CORPS QU'ON PILOTE, et lui seul : c'est ce qui
	# decide des blocs a charger. En poser un sur chaque avatar ferait generer
	# le terrain autour du compagnon aussi, pour personne qui le regarde.
	_viewer = VoxelViewer.new()
	_viewer.name = "VoxelViewer"
	_viewer.view_distance = view_distance
	_viewer.requires_visuals = true
	_viewer.requires_collisions = true
	body.add_child(_viewer)

	_build_cave_lamp(body)


# ===========================================================================
# LE TERRAIN CREUSE VOYAGE PAR BLOCS
# ===========================================================================
#
# L'appel de creusement, a lui seul, ne suffit pas : il ne touche que les pairs
# qui ont DEJA la zone en memoire. Un compagnon parti a l'autre bout de l'ile ne
# le recevra pas, et retrouvera le terrain intact en revenant — deux iles qui
# divergent sans que personne ne puisse s'en apercevoir.
#
# `VoxelTerrainMultiplayerSynchronizer` repond exactement a ce cas. Il n'a ni
# reglage ni signal — deux points d'entree RPC, et rien d'autre : tout se decide
# par l'ARBRE et par les VIEWERS.
#
# - il se decouvre lui-meme en etant ENFANT DU TERRAIN ;
# - il doit porter le MEME NOM chez tous les pairs, sinon l'appel distant ne
#   trouve pas son destinataire ;
# - cote serveur, il apprend ou est chacun par des `VoxelViewer` marques d'un
#   identifiant de pair (voir `_attach_remote_viewer`), et c'est la notification
#   d'entree dans un bloc qui declenche l'envoi — d'ou
#   `set_block_enter_notification_enabled`.
#
# Il est annonce « very experimental » par godot_voxel, et documente pour
# `VoxelTerrain` seulement — ce qui est notre cas.
const TERRAIN_SYNC_NAME := "MultiplayerSync"


func _build_terrain_sync() -> void:
	if not Network.is_online():
		return
	var sync := VoxelTerrainMultiplayerSynchronizer.new()
	sync.name = TERRAIN_SYNC_NAME
	terrain.add_child(sync)
	if multiplayer.is_server():
		terrain.set_block_enter_notification_enabled(true)


# Distance a laquelle le SERVEUR tient le terrain autour d'un joueur distant.
#
# Plus courte que la distance de vue : il n'a pas a VOIR ce que regarde son
# compagnon, seulement a detenir ce qu'il pourrait creuser et ce qu'il faudra
# lui renvoyer. Elle doit rester tres au-dessus de la portee du pinceau (huit
# metres), faute de quoi le serveur refuserait d'arbitrer un creusement fait
# loin de lui.
const REMOTE_VIEW_DISTANCE := 128


# LE SERVEUR TIENT LE TERRAIN AUTOUR DE CHAQUE JOUEUR, pas seulement du sien.
#
# Sans ce spectateur-la, le serveur ne sait rien de la region ou se trouve son
# compagnon : il ne peut ni arbitrer un creusement qu'on y fait, ni lui renvoyer
# les blocs modifies quand il y revient. C'est lui qui porte l'identifiant de
# pair, seul lien entre une position dans le monde et quelqu'un au bout du fil.
#
# SANS VISUEL NI COLLISION : le serveur n'a pas besoin de mailler ni de marcher
# sur ce terrain-la, seulement de le detenir. C'est ce qui rend la depense
# supportable — elle reste reelle, notre generateur etant en GDScript.
func _attach_remote_viewer(body: CharacterBody3D) -> void:
	var viewer := VoxelViewer.new()
	viewer.name = "VoxelViewer"
	viewer.view_distance = REMOTE_VIEW_DISTANCE
	viewer.requires_visuals = false
	viewer.requires_collisions = false
	viewer.requires_data_block_notifications = true
	viewer.set_network_peer_id(body.name.to_int())
	body.add_child(viewer)


# En lisse, l'eau ne peut pas etre un voxel : la surface d'isovaleur est
# unique, elle ne sait pas representer un volume translucide distinct. C'est
# donc une surface a part, avec son propre shader (voir sea.gd).
func _add_sea() -> void:
	_sea = Sea.new()
	_sea.name = "Sea"
	add_child(_sea)
	_sea.setup(map)


# Les rivieres sont une surface a part, et non le plan de `_add_sea` : une
# riviere descend de quarante metres d'altitude jusqu'au rivage, alors qu'un
# ocean tient a une seule altitude.
#
# Le contour du creusement en tient lieu, et il a remplace une nappe calculee
# separement : celle-ci se donnait son propre bord a partir d'un champ de
# niveau, la ou le contour EST deja le bord exact du creusement. Voir
# `river_splines.gd`.
func _add_rivers() -> void:
	_river_splines = RiverSplines.new()
	_river_splines.name = "RiverSplines"
	add_child(_river_splines)
	_river_splines.setup(map)


# Le ciel et le soleil sont pilotes par l'heure du jour. Le shader de ciel lit
# la direction du soleil tout seul, donc il suffit de faire tourner la lumiere
# pour que l'horizon suive — y compris le rougeoiement au lever et au coucher.
func _add_sky() -> void:
	_sky = SkyCycle.new()
	_sky.name = "SkyCycle"
	_sky.day_length_seconds = WorldSettings.day_length_seconds
	_sky.time_of_day = WorldSettings.start_time_of_day
	add_child(_sky)
	_sky.setup($DirectionalLight3D, $WorldEnvironment.environment)


# Le mailleur doit etre explicitement autorise a transporter la matiere.
#
# `texturing_mode` vaut TEXTURES_NONE par defaut : le mailleur n'ecrit alors
# AUCUNE donnee de matiere dans le maillage, l'attribut CUSTOM1 reste a zero,
# et le shader echantillonne la couche 0 pour tout le monde. Le terrain sort
# donc entierement en herbe, sans la moindre erreur, et le choix du pack de
# textures semble ignore alors que c'est tout le tableau qui n'arrive jamais.
#
# MIXEL4_S4 est le format qu'ecrit `TerrainGenerator` : quatre indices et
# quatre poids sur 4 bits chacun, encodes par `vec4i_to_u16_indices` et
# `color_to_u16_weights`.
func _build_mesher() -> VoxelMesherTransvoxel:
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_MIXEL4_S4
	# Les voxels d'air portent eux aussi un indice de matiere, faute de quoi
	# le generateur devrait traiter le vide a part ; les ignorer ici evite
	# qu'ils ne diluent le melange sur les sommets de surface.
	# A true, le mailleur laisse des sommets aux quatre poids nuls la ou une
	# cellule ne contient que de l'air exploitable. Nos voxels d'air portent de
	# toute facon la matiere de leur colonne, donc les compter ne fausse rien
	# et evite ce cas.
	mesher.textures_ignore_air_voxels = false
	return mesher


func _terrain_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://scenes/voxel_world/smooth_terrain.gdshader")
	material.set_shader_parameter("u_albedo_array", TerrainTextures.albedo_array())
	material.set_shader_parameter("u_normal_array", TerrainTextures.normal_array())
	material.set_shader_parameter("u_height_array", TerrainTextures.height_array())
	# L'echelle est donnee PAR MATIERE, en metres reels : les textures vont de
	# 1,4 m a 3,5 m de cote, donc une repetition unique les ferait paraitre
	# deux fois et demie differentes les unes des autres.
	material.set_shader_parameter("u_layer_meters", TerrainTextures.meters())
	material.set_shader_parameter("u_layer_roughness", TerrainTextures.roughness())
	material.set_shader_parameter("u_scale", 1.0)
	material.set_shader_parameter("u_normal_strength", 1.0)
	material.set_shader_parameter("u_blend_sharpness", 3.0)
	return material


# ===========================================================================
# SORTIE DU MONDE
# ===========================================================================
#
# ECHAP OUVRE LE MENU DE PAUSE, et c'est la seule facon de sortir d'une partie.
#
# Avant, trois touches se partageaient la sortie sans qu'aucune ne la dise :
# `M` renvoyait au menu des mondes, `F10` fermait le jeu, et `Echap` ne faisait
# que rendre la souris. Les trois n'existaient que dans une ligne d'aide en bas
# d'ecran — un raccourci ne se propose pas, il se sait, donc elles ne servaient
# qu'a qui les connaissait deja.
#
# Deux d'entre elles sont retirees, et pas seulement remplacees :
#
# - `M` menait au MENU DES MONDES, ou un client n'a rien a faire : son monde lui
#   vient de l'hote, et en choisir un autre n'aurait eu aucun effet. Le menu de
#   pause remonte a l'accueil, qui ferme proprement la partie.
# - `F10` fermait le jeu sur une pression, sans confirmation. Annoncee, c'etait
#   un raccourci ; muette, ce serait un piege. Le menu porte l'action en toutes
#   lettres.
#
# `Echap` n'a plus a rendre la souris : elle n'est plus captive (voir
# `voxel_debug_player.gd`). C'est ce qui leve l'ancienne tension entre les deux
# usages de la touche.
#
# UNE SORTIE ENGAGEE NE SE REOUVRE PAS. `_announce_exit` avance image par
# image ; mettre l'arbre en pause pendant qu'elle vide la file l'arreterait au
# milieu, voile de transition affiche et rien derriere.
func _unhandled_input(event: InputEvent) -> void:
	if _leaving:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_open_pause()


func _build_crosshair() -> void:
	_crosshair = Crosshair.new()
	_crosshair.name = "Crosshair"
	_crosshair.anchor_left = 0.5
	_crosshair.anchor_top = 0.5
	_crosshair.anchor_right = 0.5
	_crosshair.anchor_bottom = 0.5
	var half := Crosshair.SIZE / 2.0
	_crosshair.offset_left = -half
	_crosshair.offset_top = -half
	_crosshair.offset_right = half
	_crosshair.offset_bottom = half
	$Hud.add_child(_crosshair)


func _build_hotbar() -> void:
	_hotbar = Hotbar.new()
	_hotbar.name = "Hotbar"
	$Hud.add_child(_hotbar)


func _build_inventory_screen() -> void:
	_inventory_screen = InventoryScreen.new()
	_inventory_screen.name = "InventoryScreen"
	_inventory_screen.closed.connect(func(): _crosshair.visible = true)
	$Hud.add_child(_inventory_screen)


# Bascule appelee par `VoxelDebugPlayer.inventory_toggle_requested` (le
# joueur ne construit pas lui-meme l'ecran, qui vit dans le monde).
func _toggle_inventory() -> void:
	if _inventory_screen.visible:
		_inventory_screen.close()
	else:
		_crosshair.visible = false
		_inventory_screen.open(_local_player.inventory)


func _build_pause_menu() -> void:
	_pause_menu = PauseMenu.new()
	_pause_menu.name = "PauseMenu"
	_pause_menu.visible = false
	_pause_menu.resumed.connect(_close_pause)
	_pause_menu.settings_requested.connect(_open_settings)
	_pause_menu.home_requested.connect(_go_home)
	_pause_menu.quit_requested.connect(_quit_to_desktop)
	$Hud.add_child(_pause_menu)

	# L'ecran des parametres est SUPERPOSE et non ouvert comme scene : changer
	# de scene demonterait le terrain voxel, soit une file de generation a vider
	# a l'aller et plusieurs secondes de calcul au retour — pour regler une
	# sensibilite de souris. Depuis l'accueil, le meme ecran est une vraie
	# scene ; voir `scenes/settings/settings.gd`.
	_settings_screen = SettingsScreen.new()
	_settings_screen.name = "SettingsScreen"
	# La pastille de retour NOMME sa destination, et d'ici on retombe sur la
	# pause et non sur l'accueil.
	_settings_screen.back_label = "Pause"
	_settings_screen.visible = false
	_settings_screen.closed.connect(_close_settings)
	_settings_screen.view_distance_changed.connect(_set_view_distance)
	$Hud.add_child(_settings_screen)


# LA PARTIE S'ARRETE VRAIMENT.
#
# Sans `paused`, les touches de marche continueraient d'etre lues pendant qu'on
# lit le menu : on reviendrait au jeu vingt metres plus loin, ou au fond d'un
# ravin. Le menu et l'ecran des parametres sont en PROCESS_MODE_ALWAYS, sans
# quoi ils se figeraient avec le reste et ne pourraient plus se refermer.
func _open_pause() -> void:
	# La pause PRIME sur l'inventaire : les deux liberent la souris de la
	# meme facon, mais seule la pause fige l'arbre - les garder ouverts tous
	# les deux a la fois n'aurait pas de sens.
	_inventory_screen.close()
	# La souris est capturee en permanence pendant le jeu (voir
	# `VoxelDebugPlayer._ready`) : sans ca, le menu s'afficherait sans curseur
	# pour le cliquer.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_crosshair.visible = false
	_hotbar.visible = false
	_pause_menu.visible = true
	get_tree().paused = true


func _close_pause() -> void:
	get_tree().paused = false
	_pause_menu.visible = false
	# La souris est capturee en permanence pendant le jeu (voir
	# `VoxelDebugPlayer._ready`) : il faut la recapturer explicitement en
	# sortant de la pause, sinon elle resterait visible et libre.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_crosshair.visible = true
	_hotbar.visible = true


func _open_settings() -> void:
	_pause_menu.visible = false
	_settings_screen.visible = true


func _close_settings() -> void:
	_settings_screen.visible = false
	_pause_menu.visible = true


# La distance de vue s'applique A CHAUD : au terrain, qui decide des blocs a
# garder, et au spectateur, qui decide de ceux a demander. Regler l'un sans
# l'autre ferait charger des blocs aussitot jetes.
func _set_view_distance(meters: int) -> void:
	view_distance = meters
	if terrain != null:
		terrain.max_view_distance = meters
	if _viewer != null:
		_viewer.view_distance = meters


# Quitter passe par `_announce_exit`, donc par la vidange de la file de
# generation. La pause est levee AVANT : cette vidange avance image par image,
# et un arbre en pause ne lui en donnerait aucune.
func _go_home() -> void:
	get_tree().paused = false
	Network.close_world()
	await _announce_exit("Retour a l'accueil...")
	get_tree().change_scene_to_file("res://scenes/main_menu/main_menu.tscn")


func _quit_to_desktop() -> void:
	get_tree().paused = false
	Network.close_world()
	await _announce_exit("Fermeture...")
	get_tree().quit()


# ===========================================================================
# RESEAU
# ===========================================================================
#
# LA SCENE DE JEU N'ECOUTAIT RIEN, et c'etait le trou le plus visible de la
# cinematique d'ecrans : un client dont l'hote fermait la partie restait dans un
# monde fige, sans un mot, jusqu'a ce qu'il tue la fenetre lui-meme. Rien non
# plus ne disait qu'un compagnon venait d'arriver.
#
# CE QUI TRAVERSE LE FIL, desormais : la graine, les corps, le creusement et
# l'heure. Voir `_setup_players`, `request_terrain_edit` et `_share_clock`.
func _watch_network() -> void:
	Network.player_connected.connect(_on_player_connected)
	Network.player_disconnected.connect(_on_player_disconnected)
	Network.server_disconnected.connect(_on_server_disconnected)


# Connecte, mais pas encore entre dans le monde : son corps n'apparait qu'a son
# annonce, quelques secondes plus tard, le temps qu'il calcule l'ile. Voir
# `_setup_players`.
func _on_player_connected(id: int, player_name: String) -> void:
	# Le pair recoit aussi sa propre arrivee ; se l'annoncer n'aurait pas de
	# sens.
	if id == multiplayer.get_unique_id():
		return
	_notify("%s a rejoint la partie." % player_name)


func _on_player_disconnected(id: int) -> void:
	_notify("Un joueur a quitte la partie.")
	# Le corps part avec son joueur, et c'est la LISTE qui le dit : le serveur la
	# republie sans lui, chaque pair retire ce qui n'y est plus.
	if not multiplayer.is_server():
		return
	_present.erase(id)
	_publish_roster()


# ===========================================================================
# LE CREUSEMENT TRAVERSE LE FIL
# ===========================================================================
#
# C'est le SEUL geste qui change l'ile, donc le seul qui doive etre partage.
# Tout le reste — relief, biomes, grottes, rivieres — se rederive de la graine
# et est deja identique au voxel pres chez les deux joueurs.
#
# LE GESTE MONTE A L'HOTE, LE RESULTAT REDESCEND EN BLOCS.
#
# Deux chemins, et ils ne transportent pas la meme chose. Le geste — un centre,
# un rayon, creuser ou ajouter — tient en quelques octets et ne part que vers
# l'hote. Ce que l'hote en fait redescend ensuite sous forme de VOXELS, par le
# synchroniseur de terrain (voir `_build_terrain_sync`), qui sait a la fois
# pousser la zone modifiee a ceux qui la regardent et rendre le bloc entier a
# celui qui y revient plus tard.
#
# L'HOTE ARBITRE, donc, et c'est ce qui permettra d'y poser une REGLE — la
# bedrock increusable, par exemple (issue #34) — sans qu'un pair puisse la
# contourner en s'adressant directement aux autres.
#
# Le demandeur applique TOUT DE SUITE, sans attendre la reponse. Le sculptage
# est deterministe et idempotent (la distance signee prend un min ou un max),
# donc la version de l'hote qui arrive ensuite repose exactement la meme chose.
# Sans cette avance, creuser accuserait l'aller-retour reseau a chaque coup de
# pinceau.
func request_terrain_edit(center: Vector3, radius: float, remove: bool) -> void:
	if Network.is_online() and not multiplayer.is_server():
		_apply_terrain_edit(center, radius, remove)
		_ask_terrain_edit.rpc_id(1, center, radius, remove)
		return
	_publish_terrain_edit(center, radius, remove)


# Cote hote : applique, et c'est tout.
#
# LA REDISTRIBUTION N'EST PLUS FAITE ICI. Elle l'a ete, par un appel diffuse a
# tous les pairs, et ca marchait — pour ceux qui avaient deja la zone en
# memoire. Le synchroniseur de terrain, lui, couvre les deux cas d'un seul
# mecanisme : il pousse la zone modifiee aux pairs qui la regardent, et envoie
# le bloc entier a celui qui y revient plus tard. Garder les deux aurait laisse
# deux chemins pour une seule chose, dont un qui ne couvrait qu'a moitie.
func _publish_terrain_edit(center: Vector3, radius: float, remove: bool) -> void:
	_apply_terrain_edit(center, radius, remove)


# Demande d'un client. NE VA QUE VERS L'HOTE — la garde ferme la porte a un
# pair qui s'adresserait a un autre client pour contourner l'arbitrage.
@rpc("any_peer", "reliable")
func _ask_terrain_edit(center: Vector3, radius: float, remove: bool) -> void:
	if not multiplayer.is_server():
		return
	_publish_terrain_edit(center, radius, remove)


func _apply_terrain_edit(center: Vector3, radius: float, remove: bool) -> void:
	if _tool == null:
		return
	# La zone peut n'etre pas chargee chez ce pair-la : on ne sculpte pas dans
	# un bloc qui n'existe pas encore, il serait ecrase a son arrivee.
	var box := AABB(center - Vector3.ONE * radius, Vector3.ONE * radius * 2.0)
	if not _tool.is_area_editable(box):
		return
	_tool.mode = VoxelTool.MODE_REMOVE if remove else VoxelTool.MODE_ADD
	_tool.do_sphere(center, radius)
	if not remove:
		_paint_single_material(center, radius, TerrainGenerator.Layer.DIRT)
		_regrow_biome_surface(center, radius)


# UN DEPOT SORT DE TERRE, PAS D'HERBE.
#
# `do_sphere` en MODE_ADD ne touche que le canal SDF (la geometrie) : la matiere
# des voxels nouvellement solides reste a sa valeur par defaut, qui se trouve
# etre GRASS (index 0). On la force a DIRT juste apres le sculptage. Creuser n'a
# pas besoin de cette etape : la coupe expose la stratification deja posee par
# `TerrainGenerator` (terre puis roche en profondeur).
#
# MODE_TEXTURE_PAINT (le mode dedie, texture_index/texture_opacity) ne produisait
# aucun changement visible a l'essai — plutot que d'insister sur une API non
# documentee, `_paint_single_material` ecrit DIRECTEMENT les canaux
# INDICES/WEIGHTS avec le meme encodage que celui deja utilise, et deja verifie a
# l'ecran, par `TerrainGenerator._single_material`.
#
# CETTE PEINTURE VIT DANS LE MONDE ET NON DANS LE JOUEUR, depuis que le terrain
# se partage : elle doit s'appliquer partout ou la sphere s'applique, c'est-a-dire
# chez l'hote, qui est celui dont les blocs font foi.

# Repousse sur un depot laisse a l'air libre, avec le temps - PAS TOUJOURS DE
# L'HERBE : la matiere qui reprend est celle de la SURFACE DU BIOME a cet
# endroit (`map.biome_at`/`surface_block`), sinon un depot de terre sur une
# plage ou en montagne enneigee finirait vert au bout d'une minute, ce
# qu'aucun des deux ne ferait naturellement.
#
# Duree a calibrer en playtest (voir `FarmPlot.GROWTH_DURATION` pour le meme
# genre de reglage sur l'ancien prototype). Repeindre un depot qui a ete
# recreuse entretemps ne fait rien de visible : sans matiere solide la, la
# peinture ne colore aucune surface.
#
# Tourne partout ou `_apply_terrain_edit` tourne (client en avance locale ET
# hote qui fait foi) : deterministe a partir des memes `center`/`radius`, les
# deux versions convergent sans le moindre message reseau dedie.
const REGROWTH_SECONDS := 60.0


func _regrow_biome_surface(center: Vector3, radius: float) -> void:
	await get_tree().create_timer(REGROWTH_SECONDS).timeout
	if _tool == null or map == null:
		return
	var biome := map.biome_at(int(center.x), int(center.z))
	var layer := TerrainGenerator.layer_for(map.surface_block(biome))
	_paint_single_material(center, radius, layer)


# Peint une sphere d'une SEULE matiere, avec EXACTEMENT le meme encodage que
# `TerrainGenerator._single_material`/`_pad_to_four` : les trois emplacements
# libres recoivent les plus petits index DISTINCTS de `layer` (dans l'ordre
# 0, 1, 2... en sautant `layer` s'il y apparait), le tout trie, et tout le
# poids sur celui qui vaut `layer`. Generalise l'ancienne version qui figeait
# les index a (0,1,2,3) et ne marchait donc que pour `layer` < 4 (GRASS/DIRT)
# - insuffisant des qu'un biome donne une surface de sable, gravier ou neige
# (index 4 a 7) a la repousse.
func _paint_single_material(center: Vector3, radius: float, layer: int) -> void:
	var kept: Array = [layer]
	for candidate in TerrainGenerator.LAYER_COUNT:
		if kept.size() >= 4:
			break
		if not kept.has(candidate):
			kept.append(candidate)
	kept.sort()

	var weights := [0.0, 0.0, 0.0, 0.0]
	for k in 4:
		if kept[k] == layer:
			weights[k] = 1.0

	var indices := VoxelTool.vec4i_to_u16_indices(Vector4i(kept[0], kept[1], kept[2], kept[3]))
	var packed_weights := VoxelTool.color_to_u16_weights(
		Color(weights[0], weights[1], weights[2], weights[3]))

	_tool.channel = VoxelBuffer.CHANNEL_INDICES
	_tool.mode = VoxelTool.MODE_SET
	_tool.value = indices
	_tool.do_sphere(center, radius)

	_tool.channel = VoxelBuffer.CHANNEL_WEIGHTS
	_tool.value = packed_weights
	_tool.do_sphere(center, radius)

	# Le reste du monde (et le raycast du joueur) suppose le canal SDF actif.
	_tool.channel = VoxelBuffer.CHANNEL_SDF


# ===========================================================================
# L'HEURE EST CELLE DE L'HOTE
# ===========================================================================
#
# Les deux machines avancent leur cycle a leur propre cadence d'images. Rien
# ne les recale, donc elles derivent : au bout d'une heure de jeu, l'un peut
# etre au couchant quand l'autre a encore le soleil au zenith — et le ciel, la
# lumiere et les ombres en dependent tous.
#
# L'hote envoie donc SON heure a intervalle regulier, et les clients s'y posent.
# Le saut est franc plutot que lisse : entre deux envois l'ecart accumule vaut
# au plus quelques milliemes de journee, ce qui ne se voit pas ; et un client
# qui arrive en cours de partie DOIT sauter, son ciel pouvant etre a des heures
# de celui de l'hote.
#
# La duree du jour voyage avec, parce qu'elle se choisit a la composition de la
# carte et qu'un client entre sans etre passe par cet ecran.
#
# PAS DE METEO A ARBITRER POUR L'INSTANT : le monde voxel n'en a pas. Le jour
# ou il en aura une, c'est ici qu'elle passera — meme envoi, meme cadence.
const CLOCK_PERIOD := 2.0

var _clock_timer := 0.0


func _share_clock(delta: float) -> void:
	if _sky == null or not Network.is_hosting():
		return
	_clock_timer -= delta
	if _clock_timer > 0.0:
		return
	_clock_timer = CLOCK_PERIOD
	# ENVOYEE AUX SEULS PAIRS PRESENTS, un par un, et non diffusee a tous.
	#
	# Un client connecte mais pas encore entre n'a pas de scene de jeu ou poser
	# l'appel : Godot ne trouve pas le noeud destinataire et remonte une erreur.
	# Toutes les deux secondes, pendant les dix a vingt secondes que dure le
	# calcul de son ile.
	for id in _present:
		if int(id) != 1:
			_receive_clock.rpc_id(
				int(id), _sky.time_of_day, _sky.day_length_seconds)


@rpc("authority", "call_remote", "reliable")
func _receive_clock(time_of_day: float, day_length: float) -> void:
	if _sky == null:
		return
	_sky.time_of_day = time_of_day
	_sky.day_length_seconds = day_length


# L'hote est parti : il n'y a plus de partie a jouer.
#
# On ne reste pas dans le monde « en solo », et c'est delibere : la carte du
# client vient de l'hote, la partie etait la sienne, et le laisser marcher dans
# une ile dont le proprietaire est parti donnerait a croire que la connexion
# tient encore.
func _on_server_disconnected() -> void:
	# On peut etre deja en train de sortir : c'est meme le cas courant chez
	# l'hote, dont le depart provoque ce signal chez lui aussi.
	if _leaving:
		return
	get_tree().paused = false
	await _announce_exit("L'hote a ferme la partie.")
	get_tree().change_scene_to_file("res://scenes/main_menu/main_menu.tscn")


# Vide la file de generation AVANT de demonter le terrain, en affichant
# l'avancement.
#
# Liberer un VoxelTerrain attend que sa file se vide, et rien ne permet de
# l'annuler depuis GDScript. Fait pendant `free()`, cette attente est un gel
# muet : aucune image n'est dessinee, donc aucune barre ne pourrait avancer.
#
# On attend donc AVANT, image par image. La file ne se remplit plus une fois le
# spectateur retire, `VoxelEngine.get_stats()` dit combien il en reste, et la
# meme attente devient une barre qui progresse. Le `free()` qui suit ne trouve
# plus rien a attendre.
func _announce_exit(message: String) -> void:
	_leaving = true
	set_process(false)
	_exit_bar.visible = true
	_exit_label.text = message

	# Couper la DEMANDE avant de compter : sans spectateur, plus aucun bloc
	# n'est reclame et la file ne fait plus que decroitre.
	for viewer in find_children("*", "VoxelViewer", true, false):
		(viewer as Node).queue_free()
	if terrain != null:
		terrain.max_view_distance = 16
	await get_tree().process_frame

	var initial := maxi(_pending_voxel_tasks(), 1)
	while true:
		var remaining := _pending_voxel_tasks()
		if remaining <= 0:
			break
		var done := 1.0 - float(remaining) / float(maxi(initial, remaining))
		_exit_bar.visible = true
		_exit_label.text = "%s
%d blocs a ranger" % [message, remaining]
		_exit_fill.anchor_right = clampf(done, 0.0, 1.0)
		await get_tree().process_frame

	await get_tree().process_frame


# Taches de generation et de maillage encore en attente, tous terrains
# confondus. C'est ce compteur qu'attend la destruction du terrain.
func _pending_voxel_tasks() -> int:
	var tasks: Dictionary = VoxelEngine.get_stats().get("tasks", {})
	return int(tasks.get("generation", 0)) + int(tasks.get("meshing", 0))


# Voile de transition : fond plein, message, barre. Palette de l'ecran de
# carte, pour que les deux ecrans se repondent.
#
# Il COUVRE la vue, et ce n'est pas qu'une question de gout. Vider la file
# suppose de couper la demande de blocs, ce qui decharge aussi ceux qui sont
# affiches : sans voile, on regarde l'ile s'effacer pendant dix secondes, ce
# qui se lit comme une panne et non comme un depart.
func _build_exit_bar() -> void:
	_exit_bar = Control.new()
	_exit_bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	_exit_bar.visible = false

	var veil := ColorRect.new()
	veil.color = Color("#0b1a1f")
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	_exit_bar.add_child(veil)

	# Centrage par CONTENEUR et non par ancres calculees : le libelle fait une
	# ou deux lignes selon l'etape, et des decalages fixes le faisaient
	# chevaucher la barre des qu'il en gagnait une.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_exit_bar.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", IslandUI.SPACE_ROW)
	center.add_child(box)

	_exit_label = Label.new()
	_exit_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_exit_label.add_theme_font_size_override("font_size", 18)
	_exit_label.add_theme_color_override("font_color", Color("#f0e6d2"))
	box.add_child(_exit_label)

	var track := Control.new()
	track.custom_minimum_size = Vector2(340, 4)

	var groove := ColorRect.new()
	groove.color = Color(1, 1, 1, 0.14)
	groove.set_anchors_preset(Control.PRESET_FULL_RECT)
	track.add_child(groove)

	_exit_fill = ColorRect.new()
	_exit_fill.color = Color("#e0a542")
	_exit_fill.set_anchors_preset(Control.PRESET_FULL_RECT)
	_exit_fill.anchor_right = 0.0
	track.add_child(_exit_fill)

	box.add_child(track)
	$Hud.add_child(_exit_bar)


func _on_edit_refused(reason: String) -> void:
	_notify(reason)


# Message fugace dans la ligne d'etat. C'est le seul canal dont dispose la
# partie pour dire quelque chose au joueur, et il sert autant au refus d'un
# creusement qu'aux arrivees et departs sur le reseau.
func _notify(text: String) -> void:
	_message = text
	_message_timer = MESSAGE_DURATION


func _process(delta: float) -> void:
	if map == null:
		return

	_share_clock(delta)

	if _sky != null and _local_player != null:
		_update_immersion()

	if _message_timer > 0.0:
		_message_timer -= delta
		status_label.text = _message
		return
	# Le corps peut n'etre pas encore arrive : chez un client, il vient du
	# serveur, donc quelques images apres l'ouverture de la scene.
	if _local_player == null:
		status_label.text = "Entree dans le monde..."
		return
	var here := _local_player.position
	var cell := Vector3i(floori(here.x), 0, floori(here.z))
	status_label.text = "seed %d · %s · %d FPS · %s · %s · alt %d%s" % [
		world_seed,
		_sky.clock(),
		Engine.get_frames_per_second(),
		"vol" if _local_player.flying else "marche",
		map.biome_name(map.biome_at(cell.x, cell.z)),
		int(here.y),
		_company(),
	]
	_hotbar.refresh(_local_player.inventory)


# Qui est la. RIEN NE LE DISAIT NULLE PART : on hebergeait une partie sans
# jamais apprendre que quelqu'un l'avait rejointe, ni qu'il en etait reparti.
#
# En solo la mention disparait, plutot que d'afficher « 1 joueur » — un chiffre
# qui ne varie jamais n'est pas une information, c'est du bruit dans une ligne
# qui en a deja six.
func _company() -> String:
	# `Network.is_online()` et non `multiplayer.has_multiplayer_peer()`, qui rend
	# vrai meme en solo — voir la note sur le pair hors ligne dans `network.gd`.
	if not Network.is_online():
		return ""
	return " · %d joueurs" % Network.players.size()


# Premiere terre emergee en spirale depuis le centre de l'ile.
#
# `rank` ecarte les joueurs les uns des autres : ils apparaissent ensemble, donc
# assez pres pour se voir et se rejoindre, mais pas dans la meme capsule — deux
# corps confondus se repoussent violemment a la premiere image de physique.
func _spawn_position(rank: int = 0) -> Vector3:
	var center := int(float(map_size) / 2.0)
	var shift := rank * SPAWN_SPACING
	for radius in range(0, map_size / 2, 2):
		for step in 16:
			var angle := TAU * float(step) / 16.0
			var x := center + shift + int(round(cos(angle) * float(radius)))
			var z := center + int(round(sin(angle) * float(radius)))
			if map.terrain_height(x, z) > WorldMap.SEA_LEVEL:
				return Vector3(float(x) + 0.5, float(map.terrain_height(x, z)) + 3.0, float(z) + 0.5)
	return Vector3(float(center + shift), float(map_height), float(center))


# Nombre de cailloux disperses autour du spawn : modeste plutot que
# ratissable a l'oeil, juste assez pour en croiser quelques-uns sans devoir
# peigner toute l'ile pour remplir son inventaire.
const ROCK_COUNT := 15
# Rayon de dispersion des cailloux, en metres : accessible en une session
# normale de jeu.
const ROCK_SCATTER_RADIUS := 100.0
# Le sac a dos est une trouvaille rare, dans l'esprit des artefacts deja
# decrits dans DESIGN.md : plus loin que les cailloux, mais toujours a
# portee raisonnable d'une exploration.
const BACKPACK_SCATTER_RADIUS := 180.0


# Seed FIXE (derivee de `world_seed`, pas de `randi()`) pour que la
# dispersion reste identique d'une partie a l'autre sur la meme graine -
# testable, et coherente entre pairs le jour ou ce sera reseaute (voir
# `_scatter_items`).
func _scatter_items() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed + 5000

	for _i in ROCK_COUNT:
		_spawn_pickup_near_spawn(rng, ItemCatalog.Id.ROCK, ROCK_SCATTER_RADIUS)
	_spawn_pickup_near_spawn(rng, ItemCatalog.Id.BACKPACK, BACKPACK_SCATTER_RADIUS)


# Tire une colonne de terre valide (au-dessus du niveau marin, meme critere
# que `_spawn_position`) dans un disque de `radius` metres autour du spawn,
# et y pose un `ItemPickup`. Abandonne apres un nombre d'essais borne plutot
# que boucler indefiniment si le disque tombe surtout en mer.
func _spawn_pickup_near_spawn(rng: RandomNumberGenerator, item_id: int, radius: float) -> void:
	var spawn := _spawn_position()
	const MAX_ATTEMPTS := 40
	for _attempt in MAX_ATTEMPTS:
		var angle := rng.randf_range(0.0, TAU)
		var distance := rng.randf_range(radius * 0.2, radius)
		var x := int(round(spawn.x + cos(angle) * distance))
		var z := int(round(spawn.z + sin(angle) * distance))
		if x < 0 or x >= map_size or z < 0 or z >= map_size:
			continue
		if map.terrain_height(x, z) <= WorldMap.SEA_LEVEL:
			continue

		var pickup := ItemPickup.new()
		pickup.item_id = item_id
		pickup.position = Vector3(
			float(x) + 0.5, float(map.terrain_height(x, z)) + 0.5, float(z) + 0.5)
		pickup.picked_up.connect(func(_id): _notify("Ramasse : %s." % ItemCatalog.display_name(item_id)))
		pickup.pickup_refused.connect(_notify)
		add_child(pickup)
		return


# Ou se trouve l'oeil : sous terre, sous l'eau, ou a l'air libre.
#
# LES DEUX SE DECIDENT SUR LA MEME LECTURE, et c'est ce qui empeche les
# galeries d'etre immergees. Etre sous le niveau de la mer ne suffit pas a
# etre dans l'eau : une salle a vingt metres de profondeur est sous ce niveau
# et parfaitement seche. Ce qui tranche, c'est la colonne au-dessus — si le
# sol y emerge, on est dans la roche ; s'il est noye, on est dans la mer.
#
# Le reseau de grottes garantit d'ailleurs le cas : ses salles ne sont placees
# que sous des colonnes emergees, et `verify_voxel_rules.gd` le verifie.
#
# La position prise est celle de la CAMERA et non du corps : c'est l'oeil qui
# passe sous la surface, et il le fait une seconde avant les pieds.
func _update_immersion() -> void:
	var eye := _camera.global_position if _camera != null else _local_player.global_position
	var column := map.terrain_height(floori(eye.x), floori(eye.z))

	# Voir la note en tete de SkyCycle : l'ambiante et la perspective aerienne
	# traversent la roche, et c'est le seul moyen de les eteindre sous terre.
	_sky.underground = smoothstep(0.0, 6.0, float(column) - eye.y)
	# PROVISOIRE : cf. la section LAMPE DE GROTTE.
	if _cave_lamp != null:
		_cave_lamp.light_energy = _sky.underground * CAVE_LAMP_ENERGY

	var submerged := eye.y < _water_surface_at(eye)
	_sky.underwater = 1.0 if submerged else 0.0
	_water_veil.visible = submerged

	# LA CAMERA NE SE MOUILLE PAS TOUTE SEULE.
	#
	# En vue d'epaule, l'objectif traine jusqu'a huit metres derriere le
	# personnage : longer un chenal suffit a le faire passer sous la surface
	# alors qu'on a les pieds sur la berge, et le voile bleu se declencherait
	# la. On donne donc au rig l'altitude de l'eau sous le PERSONNAGE, et il
	# maintient l'objectif au-dessus — sauf quand le personnage est lui-meme
	# immerge, ou la camera doit bien le suivre sous l'eau.
	#
	# C'est ce qui permet au test ci-dessus de rester branche sur la seule
	# camera, sans une ligne de plus.
	var shoulder := _local_player.global_position + Vector3.UP * PlayerCamera.PIVOT_Y
	var surface := _water_surface_at(shoulder)
	_local_player.water_surface_y = -INF if shoulder.y < surface else surface


# Altitude de la surface d'eau au-dessus de ce point, ou -INF s'il n'y en a
# aucune.
#
# DEUX EAUX, UNE SEULE REPONSE. La mer tient a une seule altitude, donc « sous
# la mer » se decide en comparant a `SEA_LEVEL`. Une riviere, elle, descend de
# quarante metres : il faut lui demander SON altitude a CETTE colonne — ce que
# la nappe sait repondre, et qui est la raison pour laquelle elle garde son
# champ de niveau apres avoir bati son maillage.
#
# ETRE SOUS LE NIVEAU DE L'EAU NE SUFFIT PAS, IL FAUT ETRE DEDANS.
#
# Une galerie passe des dizaines de metres sous une riviere : comparer la seule
# altitude y declenchait le voile bleu en pleine roche seche. La mer echappait
# au piege par accident — sa condition `column <= SEA_LEVEL` exclut toute
# colonne de terre ferme, donc toute grotte.
#
# On exige donc que le point soit AU-DESSUS DU SOL de sa colonne : dans un
# chenal, le sol est le lit, et on y est bien ; sous terre, on est dessous.
func _water_surface_at(point: Vector3) -> float:
	var column := map.terrain_height(floori(point.x), floori(point.z))
	if column <= WorldMap.SEA_LEVEL:
		return float(WorldMap.SEA_LEVEL)
	if _river_splines == null or point.y < float(column):
		return -INF
	var level := _river_splines.water_level_at(floori(point.x), floori(point.z))
	return level if level > float(column) else -INF


# Voile plein ecran de l'immersion. Repris de terrain-3d, qui n'a pas de shader
# pour cela : une teinte bleu-vert par-dessus l'image suffit, le reste de
# l'effet venant du brouillard (voir SkyCycle).
#
# Il est place SOUS la barre de sortie : quand on quitte la partie depuis l'eau,
# c'est le voile de transition qu'on doit voir, pas du bleu par-dessus.
func _build_water_veil() -> void:
	_water_veil = ColorRect.new()
	_water_veil.color = SkyCycle.WATER_TINT
	_water_veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	_water_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_water_veil.visible = false
	$Hud.add_child(_water_veil)
	$Hud.move_child(_water_veil, 0)


# ===========================================================================
# LAMPE DE GROTTE — PROVISOIRE, A SUPPRIMER
# ===========================================================================
#
# Une galerie est d'un noir complet : la roche occulte le soleil, et l'ambiante
# y est volontairement eteinte (voir SkyCycle). C'est physiquement juste et
# injouable — on ne voit litteralement rien.
#
# Cette lampe est un ECHAFAUDAGE, pas une mecanique. Elle suit le joueur, ne
# coute rien, et n'a aucune justification dans la fiction : personne ne
# rayonne. Elle disparait le jour ou le jeu aura de quoi s'eclairer — torche,
# lanterne, feu de camp — et c'est `DESIGN.md` qui les prevoit deja
# ("artisanat de base : outils, briquet, feu"), voir issue #10 et issue #41.
#
# Ce qu'il faudra retirer : cette section, l'appel dans `_ready`, et la ligne
# qui regle son energie dans `_update_immersion`.
#
# Elle ne projette PAS d'ombre, ce qui la fait traverser les parois minces.
# C'est assume : une omni a ombres portees suivant le joueur dans un terrain
# qui se remaille en permanence coute cher, et l'echafaudage ne merite pas
# cette depense.
const CAVE_LAMP_RANGE := 20.0
const CAVE_LAMP_ENERGY := 3.4
const CAVE_LAMP_COLOR := Color(1.0, 0.87, 0.68)


func _build_cave_lamp(body: CharacterBody3D) -> void:
	_cave_lamp = OmniLight3D.new()
	_cave_lamp.name = "LampeProvisoire"
	_cave_lamp.omni_range = CAVE_LAMP_RANGE
	_cave_lamp.omni_attenuation = 0.9
	_cave_lamp.light_color = CAVE_LAMP_COLOR
	_cave_lamp.light_energy = 0.0
	_cave_lamp.shadow_enabled = false
	# Un peu au-dessus des pieds, pour eclairer le sol devant plutot que de
	# poser le joueur au centre d'une bulle.
	_cave_lamp.position = Vector3(0.0, 1.2, 0.0)
	body.add_child(_cave_lamp)
