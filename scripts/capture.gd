extends SceneTree

# Capture d'ecran automatique, pour diagnostiquer le rendu sans avoir a
# decrire ce qu'on voit.
#
#   godot --path . --script res://scripts/capture.gd -- <scene> <secondes> <sortie>
#
# Outil de mise au point, pas de production : il instancie la scene demandee,
# laisse le streaming remplir le terrain, puis enregistre le tampon d'image.

const DEFAULT_SCENE := "res://scenes/voxel_world/smooth_voxel_world.tscn"
const DEFAULT_DELAY := 14.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var scene_path: String = args[0] if args.size() > 0 else DEFAULT_SCENE
	var delay: float = float(args[1]) if args.size() > 1 else DEFAULT_DELAY
	var out_path: String = args[2] if args.size() > 2 else "user://capture.png"

	var packed := load(scene_path)
	if packed == null:
		printerr("scene introuvable : %s" % scene_path)
		quit(1)
		return
	root.add_child(packed.instantiate())
	_capture(delay, out_path)


func _capture(delay: float, out_path: String) -> void:
	await create_timer(delay).timeout
	# Une frame de plus apres le reveil : le tampon lu doit etre celui d'une
	# image entierement dessinee.
	await process_frame
	var image := root.get_texture().get_image()
	var error := image.save_png(out_path)
	if error == OK:
		print("capture -> %s" % ProjectSettings.globalize_path(out_path))
	else:
		printerr("echec d'ecriture (%d)" % error)
	quit(0)
