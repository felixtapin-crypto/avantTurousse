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

@onready var player: CharacterBody3D = $Player
@onready var status_label: Label = $Hud/StatusLabel

var _exit_bar: Control
var _exit_fill: ColorRect
var _exit_label: Label
var _water_veil: ColorRect
var _camera: Camera3D
var _pause_menu: PauseMenu
var _settings_screen: SettingsScreen
var _crosshair: Crosshair
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
	# ORDRE D'EMPILEMENT, du fond vers le dessus : le voile d'immersion, le menu
	# de pause, puis la barre de sortie. Quitter depuis le menu de pause doit
	# montrer le voile de transition, et non le menu par-dessus.
	_build_water_veil()
	_build_crosshair()
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

	_viewer = VoxelViewer.new()
	_viewer.name = "VoxelViewer"
	_viewer.view_distance = view_distance
	_viewer.requires_visuals = true
	_viewer.requires_collisions = true
	player.add_child(_viewer)

	player.voxel_tool = _tool
	player.edit_refused.connect(_on_edit_refused)
	player.flying = true
	player.position = _spawn_position()
	# La camera est en `top_level` : elle ne suit pas un saut de position, il
	# faut la recoller apres l'apparition. Voir `PlayerCamera.snap`.
	player.snap_camera()

	# C est l OEIL qui passe sous la surface, et il le fait avant les pieds.
	var cameras := player.find_children("*", "Camera3D", true, false)
	if not cameras.is_empty():
		_camera = cameras[0] as Camera3D

	_build_cave_lamp()

	_add_sky()
	_add_sea()
	_add_rivers()

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
	# La souris est capturee en permanence pendant le jeu (voir
	# `VoxelDebugPlayer._ready`) : sans ca, le menu s'afficherait sans curseur
	# pour le cliquer.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_crosshair.visible = false
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
# Ce que ces branchements NE FONT PAS : synchroniser la partie. Les positions et
# le creusement ne traversent toujours pas le fil (voir issue #31). Seule la
# graine voyage, ce qui suffit a ce que les deux joueurs soient dans la meme
# ile — mais chacun y est encore seul.
func _watch_network() -> void:
	Network.player_connected.connect(_on_player_connected)
	Network.player_disconnected.connect(_on_player_disconnected)
	Network.server_disconnected.connect(_on_server_disconnected)


func _on_player_connected(id: int, player_name: String) -> void:
	# Le pair recoit aussi sa propre arrivee ; se l'annoncer n'aurait pas de
	# sens.
	if id == multiplayer.get_unique_id():
		return
	_notify("%s a rejoint la partie." % player_name)


func _on_player_disconnected(_id: int) -> void:
	_notify("Un joueur a quitte la partie.")


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

	if _sky != null:
		_update_immersion()

	if _message_timer > 0.0:
		_message_timer -= delta
		status_label.text = _message
		return
	var cell := Vector3i(floori(player.position.x), 0, floori(player.position.z))
	status_label.text = "seed %d · %s · %d FPS · %s · %s · alt %d%s" % [
		world_seed,
		_sky.clock(),
		Engine.get_frames_per_second(),
		"vol" if player.flying else "marche",
		map.biome_name(map.biome_at(cell.x, cell.z)),
		int(player.position.y),
		_company(),
	]


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


func _spawn_position() -> Vector3:
	var center := int(float(map_size) / 2.0)
	for radius in range(0, map_size / 2, 2):
		for step in 16:
			var angle := TAU * float(step) / 16.0
			var x := center + int(round(cos(angle) * float(radius)))
			var z := center + int(round(sin(angle) * float(radius)))
			if map.terrain_height(x, z) > WorldMap.SEA_LEVEL:
				return Vector3(float(x) + 0.5, float(map.terrain_height(x, z)) + 3.0, float(z) + 0.5)
	return Vector3(float(center), float(map_height), float(center))


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
	var eye := _camera.global_position if _camera != null else player.global_position
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
	var shoulder := player.global_position + Vector3.UP * PlayerCamera.PIVOT_Y
	var surface := _water_surface_at(shoulder)
	player.water_surface_y = -INF if shoulder.y < surface else surface


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


func _build_cave_lamp() -> void:
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
	player.add_child(_cave_lamp)
