extends Node3D

# Scene du monde voxel, rendue par godot_voxel (issue #34).
#
# Tout ce qui fait le monde — relief erode, hydrologie, climat, biomes — vient
# de `WorldMap`, qui ne depend d'aucun moteur de rendu. C'est ce qui a permis
# de remplacer la couche voxel ecrite a la main par l'extension sans toucher
# une ligne de la generation : seul le remplissage 3D, local par nature, a ete
# reecrit selon l'API du moteur (`kaykit_voxel_generator.gd`).
#
# Le terrain est cable EN CODE et non dans le .tscn, pour une raison qui
# compte : `_generate_block()` tourne sur plusieurs threads et lit la carte.
# Il faut donc garantir que la carte est entierement calculee AVANT que le
# terrain ne commence a streamer. Un generateur pose dans la scene serait
# actif des l'ouverture, avec une carte vide.

@onready var player: CharacterBody3D = $Player
@onready var status_label: Label = $Hud/StatusLabel
@onready var help_label: Label = $Hud/HelpLabel

# TODO(#31) : meme remarque que pour l'autre scene, la seed doit venir de la
# sauvegarde et etre transmise par l'hote a la connexion.
@export var world_seed: int = 1
@export var map_size: int = 600
@export var map_height: int = 64
@export var view_distance: int = 384

const MESSAGE_DURATION := 2.5

var map: WorldMap
var _message := ""
var _message_timer := 0.0
var terrain: VoxelTerrain
var _tool: VoxelTool


func _ready() -> void:
	help_label.text = "ZQSD deplacer · Souris regarder · F vol/marche · Maj descendre (vol) ou courir\nClic gauche creuser · Clic droit poser · Echap liberer la souris"
	status_label.text = "Calcul de la carte..."

	# Reglages venus de l'ecran d'apercu, si la partie est passee par lui.
	world_seed = WorldSettings.seed_value
	map_size = WorldSettings.size

	var started := Time.get_ticks_msec()
	# L'apercu a deja calcule cette carte : la reprendre telle quelle evite de
	# refaire tout le travail pour retomber exactement sur le meme resultat.
	map = WorldSettings.take_map()
	if map == null:
		map = WorldMap.new(map_size, map_height)
		map.generate(world_seed)
	var map_ms := Time.get_ticks_msec() - started

	var generator := KayKitVoxelGenerator.new()
	generator.map = map

	terrain = VoxelTerrain.new()
	terrain.name = "VoxelTerrain"
	terrain.generator = generator
	terrain.mesher = KayKitBlockyLibrary.build_mesher()
	terrain.generate_collisions = true
	terrain.max_view_distance = view_distance
	# Le monde est fini : une ile, pas un terrain infini. godot_voxel sait
	# borner nativement, ce qui evite de generer de la mer a l'infini.
	terrain.bounds = AABB(
		Vector3.ZERO,
		Vector3(float(map_size), float(map_height), float(map_size)))
	add_child(terrain)
	_tool = terrain.get_voxel_tool()

	# Le VoxelViewer est ce qui definit le centre du streaming : les chunks se
	# chargent autour de lui, pas autour de l'origine.
	var viewer := VoxelViewer.new()
	viewer.name = "VoxelViewer"
	viewer.view_distance = view_distance
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	player.add_child(viewer)

	_tool.channel = VoxelBuffer.CHANNEL_TYPE
	player.voxel_tool = _tool
	player.edit_refused.connect(_on_edit_refused)
	player.flying = true
	player.position = _spawn_position()

	status_label.text = "Carte calculee en %d ms — streaming en cours..." % map_ms


func _on_edit_refused(reason: String) -> void:
	_message = reason
	_message_timer = MESSAGE_DURATION


func _process(delta: float) -> void:
	if map == null:
		return
	if _message_timer > 0.0:
		_message_timer -= delta
		status_label.text = _message
		return
	var cell := Vector3i(floori(player.position.x), 0, floori(player.position.z))
	status_label.text = "godot_voxel · seed %d · %d FPS · %s · %s · alt %d" % [
		world_seed,
		Engine.get_frames_per_second(),
		"vol" if player.flying else "marche",
		map.biome_name(map.biome_at(cell.x, cell.z)),
		int(player.position.y),
	]


# Terre ferme la plus proche du centre. On ne peut pas prendre le centre
# geometrique : rien ne garantit qu'il soit emerge une fois le relief tire.
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
