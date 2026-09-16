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
@onready var help_label: Label = $Hud/HelpLabel

var _exit_bar: Control
var _exit_fill: ColorRect
var _exit_label: Label
var _water_veil: ColorRect
var _camera: Camera3D
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


func _ready() -> void:
	help_label.text = "ZQSD deplacer · Souris regarder · F vol/marche · Maj descendre (vol) ou courir\nClic gauche creuser · Clic droit ajouter · Echap liberer la souris · M nouvelle carte · F10 quitter"
	status_label.text = "Calcul de la carte..."
	_build_exit_bar()
	_build_water_veil()

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

	var viewer := VoxelViewer.new()
	viewer.name = "VoxelViewer"
	viewer.view_distance = view_distance
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	player.add_child(viewer)

	player.voxel_tool = _tool
	player.edit_refused.connect(_on_edit_refused)
	player.flying = true
	player.position = _spawn_position()

	# C est l OEIL qui passe sous la surface, et il le fait avant les pieds.
	var cameras := player.find_children("*", "Camera3D", true, false)
	if not cameras.is_empty():
		_camera = cameras[0] as Camera3D

	_build_cave_lamp()

	_add_sky()
	_add_sea()

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
	# Centre de la carte : le terrain occupe [0, map_size] en X et en Z.
	var center := Vector3(float(map_size) * 0.5, 0.0, float(map_size) * 0.5)
	_sea.setup(center, float(WorldMap.SEA_LEVEL))


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


# Sortie du monde : retour a l'ecran de carte, ou fermeture.
#
# Ni l'un ni l'autre n'est sur Echap, qui sert deja a rendre la souris — et
# c'est justement la touche qu'on presse quand on est perdu. Lui donner en plus
# la fermeture du jeu ferait quitter une partie a chacun de ces reflexes.
#
# `M` repasse par l'ecran de configuration, donc par le CACHE : revenir sur la
# meme graine et la meme taille ne recalcule rien.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	if not (event is InputEventKey):
		return

	match (event as InputEventKey).keycode:
		KEY_M:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			await _announce_exit("Retour a la carte...")
			get_tree().change_scene_to_file("res://scenes/voxel_world/map_preview.tscn")
		KEY_F10:
			await _announce_exit("Fermeture...")
			get_tree().quit()


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
	box.add_theme_constant_override("separation", 14)
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
	_message = reason
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
	status_label.text = "seed %d · %s · %d FPS · %s · %s · alt %d" % [
		world_seed,
		_sky.clock(),
		Engine.get_frames_per_second(),
		"vol" if player.flying else "marche",
		map.biome_name(map.biome_at(cell.x, cell.z)),
		int(player.position.y),
	]


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

	var submerged := eye.y < float(WorldMap.SEA_LEVEL) and column <= WorldMap.SEA_LEVEL
	_sky.underwater = 1.0 if submerged else 0.0
	_water_veil.visible = submerged


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
