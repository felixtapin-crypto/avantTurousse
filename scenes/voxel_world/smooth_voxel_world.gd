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

@export var world_seed: int = 1
@export var map_size: int = 600
@export var map_height: int = 64
@export var view_distance: int = 384

const MESSAGE_DURATION := 2.5

var map: WorldMap
var terrain: VoxelTerrain
var _tool: VoxelTool
var _message := ""
var _message_timer := 0.0


func _ready() -> void:
	help_label.text = "ZQSD deplacer · Souris regarder · F vol/marche · Maj descendre (vol) ou courir\nClic gauche creuser · Clic droit ajouter · Echap liberer la souris"
	status_label.text = "Calcul de la carte..."

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

	_add_sea()

	status_label.text = "Carte calculee en %d ms — streaming en cours..." % map_ms


# En lisse, l'eau ne peut pas etre un voxel : la surface d'isovaleur est
# unique, elle ne sait pas representer un volume translucide distinct. Un
# simple plan a hauteur de mer suffit — et c'est exactement le point
# d'accroche ou brancher le shader d'ocean deja disponible dans les autres
# projets, qui gere la profondeur et l'ecume de rivage.
func _add_sea() -> void:
	var plane := MeshInstance3D.new()
	plane.name = "Sea"
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(float(map_size), float(map_size))
	plane.mesh = mesh

	var material := StandardMaterial3D.new()
	material.albedo_color = TerrainMaterials.COLOR[TerrainMaterials.Type.WATER]
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 0.1
	plane.material_override = material
	plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	plane.position = Vector3(float(map_size) / 2.0, float(WorldMap.SEA_LEVEL), float(map_size) / 2.0)
	add_child(plane)


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
	mesher.textures_ignore_air_voxels = true
	return mesher


func _terrain_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://scenes/voxel_world/smooth_terrain.gdshader")
	material.set_shader_parameter("u_albedo_array", TexturePacks.build(WorldSettings.texture_pack))
	material.set_shader_parameter("u_texture_scale", 0.15)
	material.set_shader_parameter("u_roughness", 1.0)
	material.set_shader_parameter("u_tint_strength", 1.0)
	return material


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
	status_label.text = "lisse (Transvoxel) · seed %d · %d FPS · %s · %s · alt %d" % [
		world_seed,
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
