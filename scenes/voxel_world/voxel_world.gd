extends Node3D

# Scene de la carte voxel (issue #4).
#
# Volontairement SEPAREE de `scenes/world/world.tscn`, qui reste intacte et
# jouable : la refonte se fait a cote plutot qu'en place. Deux raisons,
# au-dela du confort :
#
# - `master` exige une PR relue, et une refonte in-place de world.tscn
#   donnerait une PR illisible ;
# - la PR #29 modifie deja world.gd, world.tscn, vegetation.gd, player.gd et
#   collectible.gd. `TASKS.md` demande de prevenir avant de toucher a un
#   systeme deja pris — donc on n'y touche pas.
#
# Cette scene n'est pas encore branchee au reseau ni au menu : c'est un banc
# d'essai pour le terrain. Le portage du vrai joueur, du reseau et de la
# vegetation viendra une fois #29 mergee.

@onready var terrain: VoxelTerrain = $VoxelTerrain
@onready var player: CharacterBody3D = $Player
@onready var status_label: Label = $Hud/StatusLabel
@onready var help_label: Label = $Hud/HelpLabel

# TODO(#31) : cette seed doit venir de la sauvegarde / d'un ecran "nouvelle
# partie", ET etre transmise par l'hote au client a la connexion. Tant
# qu'elle est une constante compilee, les deux pairs generent la meme ile
# par accident (parce qu'ils executent le meme code), pas par accord.
@export var world_seed: int = 1

const MESSAGE_DURATION := 2.5

var _message := ""
var _message_timer := 0.0


func _ready() -> void:
	terrain.generation_progress.connect(_on_generation_progress)
	terrain.generation_finished.connect(_on_generation_finished)
	player.edit_refused.connect(_on_edit_refused)

	player.terrain = terrain
	# Le joueur attend en vol au-dessus du vide le temps que les chunks
	# apparaissent : le poser au sol avant que la collision existe le ferait
	# traverser le terrain, exactement le bug de spawn deja rencontre sur la
	# heightmap.
	player.flying = true
	player.position = Vector3(float(terrain.size_xz) / 2.0, float(terrain.size_y) + 20.0, float(terrain.size_xz) / 2.0)

	status_label.text = "Generation de l'ile..."
	help_label.text = "ZQSD deplacer · Souris regarder · F vol/marche · Maj descendre (vol) ou courir\nClic gauche creuser · Clic droit poser · Echap liberer la souris"

	terrain.generate(world_seed)


func _on_generation_progress(done: int, total: int) -> void:
	status_label.text = "Maillage des chunks : %d / %d" % [done, total]


func _on_generation_finished() -> void:
	player.position = terrain.spawn_position() + Vector3(0.0, 1.0, 0.0)
	player.flying = false
	status_label.text = "Ile generee (seed %d)" % world_seed


func _on_edit_refused(reason: String) -> void:
	_message = reason
	_message_timer = MESSAGE_DURATION


func _process(delta: float) -> void:
	if terrain.is_building():
		return
	if _message_timer > 0.0:
		_message_timer -= delta
		status_label.text = _message
		return
	# Le biome sous les pieds est affiche pour pouvoir verifier a l'oeil que
	# la carte est coherente : une plage doit annoncer "plage", un desert
	# doit se trouver au chaud et au sec, pas au bord de l'eau.
	var biome := "?"
	if terrain.data != null:
		var cell := Vector3i(floori(player.position.x), 0, floori(player.position.z))
		biome = terrain.data.biome_name(terrain.data.biome_at(cell.x, cell.z))

	status_label.text = "Seed %d · %d FPS · %s · %s · alt %d" % [
		world_seed,
		Engine.get_frames_per_second(),
		"vol" if player.flying else "marche",
		biome,
		int(player.position.y),
	]
