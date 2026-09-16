extends SceneTree

# Importe une matiere ambientCG dans assets/terrain_textures.
#
#   godot --headless --path . --script res://scripts/import_texture.gd \
#     -- <dossier_extrait> <nom_de_couche>
#
# Le dossier est celui d'une archive ambientCG decompressee ; le nom de couche
# est celui de `TerrainTextures.NAMES` (grass, dirt, gravel...).
#
# Cet outil existe parce que les reglages d'encodage etaient decrits dans
# SOURCE.md sans que rien ne les applique : les deux premieres matieres
# importees a la main ont donne des fichiers trois fois plus gros que les
# suivantes. Il reprend donc les memes qualites pour tout le monde, et
# recalcule au passage la rugosite moyenne, qui est une CONSTANTE dans
# `terrain_textures.gd` et qu'on oublierait volontiers de mettre a jour.

const OUT_DIR := "res://assets/terrain_textures"
# Qualites relevees dans SOURCE.md. La normale est encodee plus finement : un
# artefact de compression sur une couleur d'albedo se voit a peine, sur un
# vecteur de normale il fait scintiller tout un versant.
const COLOR_QUALITY := 0.82
const NORMAL_QUALITY := 0.88
# La hauteur ne sert qu'a departager deux matieres qui se recouvrent : elle
# supporte tres bien d'etre compressee.
const HEIGHT_QUALITY := 0.80


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("usage: -- <dossier_extrait> <nom_de_couche>")
		quit(1)
		return

	var source_dir: String = args[0]
	var layer_name: String = args[1]
	if not TerrainTextures.NAMES.has(layer_name):
		printerr("couche inconnue : %s (attendu %s)" % [layer_name, TerrainTextures.NAMES])
		quit(1)
		return

	# NormalGL, jamais NormalDX : la convention DirectX inverse le vert et
	# creuse les reliefs au lieu de les faire ressortir.
	var ok := _convert(source_dir, "_Color.jpg", layer_name, "color", COLOR_QUALITY)
	ok = _convert(source_dir, "_NormalGL.jpg", layer_name, "normal", NORMAL_QUALITY) and ok
	# La carte de deplacement sert de HAUTEUR au melange : c'est elle qui fait
	# que les galets du gravier percent le sable au lieu de s'y fondre.
	ok = _convert(source_dir, "_Displacement.jpg", layer_name, "height", HEIGHT_QUALITY) and ok
	_report_roughness(source_dir)
	quit(0 if ok else 1)


func _convert(dir: String, suffix: String, layer_name: String, kind: String, quality: float) -> bool:
	var path := _find(dir, suffix)
	if path == "":
		printerr("pas de fichier %s dans %s" % [suffix, dir])
		return false

	var image := Image.load_from_file(path)
	if image == null:
		printerr("lecture impossible : %s" % path)
		return false

	var out_path := "%s/%s_%s.jpg" % [OUT_DIR, layer_name, kind]
	var error := image.save_jpg(out_path, quality)
	if error != OK:
		printerr("ecriture impossible (%d) : %s" % [error, out_path])
		return false

	print("%s  %dx%d  -> %s" % [suffix, image.get_width(), image.get_height(), out_path])
	return true


# La rugosite n'est pas versionnee : seule sa moyenne l'est, en constante. On
# la calcule ici pour n'avoir pas a l'estimer a l'oeil.
func _report_roughness(dir: String) -> void:
	var path := _find(dir, "_Roughness.jpg")
	if path == "":
		print("pas de carte de rugosite — laisser la constante en place")
		return
	var image := Image.load_from_file(path)
	if image == null:
		return

	# Un echantillonnage regulier suffit largement pour une moyenne, et evite
	# de parcourir le million de pixels d'une carte 1024.
	var total := 0.0
	var count := 0
	var stride := maxi(image.get_width() / 64, 1)
	for y in range(0, image.get_height(), stride):
		for x in range(0, image.get_width(), stride):
			total += image.get_pixel(x, y).r
			count += 1
	print("rugosite moyenne : %.2f  (a reporter dans TerrainTextures.ROUGHNESS)"
		% (total / maxf(float(count), 1.0)))


func _find(dir: String, suffix: String) -> String:
	var listing := DirAccess.get_files_at(dir)
	if listing.is_empty():
		printerr("dossier illisible ou vide : %s" % dir)
		return ""
	for name in listing:
		if name.ends_with(suffix):
			return dir.path_join(name)
	return ""
