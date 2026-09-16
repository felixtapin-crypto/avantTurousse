extends SceneTree

# Capture d'ecran automatique, pour diagnostiquer le rendu sans avoir a
# decrire ce qu'on voit.
#
#   godot --path . --script res://scripts/capture.gd \
#     -- <scene> <secondes> <sortie> [heure] [site] [azimut]
#
# Outil de mise au point, pas de production : il instancie la scene demandee,
# laisse le streaming remplir le terrain, puis enregistre le tampon d'image.
#
# `heure` est facultative, en fraction de journee (0 = minuit, 0.5 = midi).
# Quand elle est donnee, le cycle est aussi FIGE : sans cela les secondes
# d'attente feraient deriver l'heure, et on ne capturerait pas celle qu'on a
# demandee.
#
# `site` et `azimut` orientent la camera, en degres (site positif = vers le
# haut). Sans eux on ne voit que l'horizon, ce qui suffit pour le terrain mais
# laisse hors cadre tout ce qui vit en hauteur — la lune et les planetes, par
# exemple, qui culminent au milieu de la nuit.

const DEFAULT_SCENE := "res://scenes/voxel_world/smooth_voxel_world.tscn"
const DEFAULT_DELAY := 14.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var scene_path: String = args[0] if args.size() > 0 else DEFAULT_SCENE
	var delay: float = float(args[1]) if args.size() > 1 else DEFAULT_DELAY
	var out_path: String = args[2] if args.size() > 2 else "user://capture.png"
	if args.size() > 3:
		WorldSettings.start_time_of_day = fposmod(float(args[3]), 1.0)
		WorldSettings.day_length_seconds = 1.0e9
	var pitch: float = float(args[4]) if args.size() > 4 else NAN
	var yaw: float = float(args[5]) if args.size() > 5 else 0.0
	# Position de depart, "x,y,z". Elle est posee AVANT l attente, pour que le
	# streaming remplisse le terrain autour du point vise et non autour du point
	# d apparition — c est le seul moyen de capturer l interieur d une grotte.
	var spawn: String = args[6] if args.size() > 6 else ""

	var packed := load(scene_path)
	if packed == null:
		printerr("scene introuvable : %s" % scene_path)
		quit(1)
		return
	var instance: Node = packed.instantiate()
	root.add_child(instance)
	_capture(delay, out_path, pitch, yaw, instance, spawn)


func _capture(delay: float, out_path: String, pitch: float, yaw: float,
		scene_root: Node, spawn: String) -> void:
	# Deux images d attente : la scene pose le joueur dans son `_ready`, et il
	# n est pas encore dans l arbre au retour d `add_child`.
	await process_frame
	await process_frame
	if spawn != "":
		_place(scene_root, spawn)
	await create_timer(delay).timeout
	# L'orientation est posee APRES l'attente : le joueur reprend la main sur sa
	# camera des qu'il recoit une entree, et rien ne garantit qu'il n'ait pas
	# initialise la sienne entre-temps.
	if not is_nan(pitch):
		_aim(pitch, yaw)
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


# Oriente la premiere camera trouvee. On ecrit la rotation GLOBALE parce que la
# camera est en general fille du joueur, qui porte deja son propre lacet : une
# rotation locale s'y ajouterait au lieu de la remplacer.
func _aim(pitch: float, yaw: float) -> void:
	var cameras := root.find_children("*", "Camera3D", true, false)
	if cameras.is_empty():
		printerr("aucune Camera3D dans la scene")
		return
	var camera := cameras[0] as Camera3D
	camera.global_rotation = Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0)


# Deplace le joueur. La scene l'a deja pose dans son `_ready`, appele par
# `add_child` : on ecrase donc sa position juste apres.
func _place(scene_root: Node, spec: String) -> void:
	var parts := spec.split(",")
	if parts.size() != 3:
		printerr("position attendue sous la forme x,y,z")
		return
	var bodies := scene_root.find_children("*", "CharacterBody3D", true, false)
	if bodies.is_empty():
		printerr("aucun CharacterBody3D a deplacer")
		return
	(bodies[0] as Node3D).global_position = Vector3(
		float(parts[0]), float(parts[1]), float(parts[2]))
