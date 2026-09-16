class_name TexturePacks
extends RefCounted

# Choix du jeu de textures du terrain.
#
# Un seul pack existe aujourd'hui, celui genere a partir de la palette du
# projet. Les suivants n'auront PAS besoin de code : il suffira de deposer un
# dossier d'images sous `res://assets/texture_packs/`, et il apparaitra dans
# la liste. C'est le sens de ce fichier — la liste est decouverte, pas ecrite
# en dur, pour qu'ajouter un pack reste une operation d'assets et non de
# programmation.
#
# Un pack sur disque contient huit images, nommees d'apres la matiere. L'ordre
# du tableau vient de `ProceduralTextures.LAYER_ORDER`, qui est lui-meme le
# contrat avec le shader : ce sont les noms, pas l'ordre alphabetique, qui
# decident de quelle couche est quoi.

const PACKS_DIR := "res://assets/texture_packs"
const PROCEDURAL_ID := "procedural"

const FILE_NAMES: Array[String] = [
	"grass", "dirt", "stone", "stone_dark",
	"sand", "sand_pale", "gravel", "snow",
]

const EXTENSIONS: Array[String] = ["png", "jpg", "webp"]


# Liste des packs utilisables : le procedural, puis tout dossier complet
# trouve sur disque. Un dossier auquel il manque une image est ignore plutot
# que charge a moitie — une couche manquante repeindrait silencieusement une
# matiere avec une autre.
static func available() -> Array[Dictionary]:
	var packs: Array[Dictionary] = [{
		"id": PROCEDURAL_ID,
		"name": "Couleurs par defaut",
		"note": "Textures generees a partir de la palette du projet.",
	}]

	var dir := DirAccess.open(PACKS_DIR)
	if dir == null:
		return packs

	for name in dir.get_directories():
		var missing := _missing_files(name)
		if missing.is_empty():
			packs.append({
				"id": name,
				"name": name.capitalize(),
				"note": "Pack d'images, dossier %s." % name,
			})
		else:
			push_warning("Pack de textures '%s' ignore, il manque : %s"
				% [name, ", ".join(missing)])

	return packs


static func display_name(id: String) -> String:
	for pack in available():
		if pack["id"] == id:
			return pack["name"]
	return "Couleurs par defaut"


# Les huit couches du pack, dans l'ordre impose par le shader. Retombe sur le
# procedural si l'identifiant n'existe plus — un pack peut avoir ete retire du
# disque entre deux lancements, et ce n'est pas une raison pour ne plus
# demarrer.
static func layer_images(id: String) -> Array[Image]:
	if id == PROCEDURAL_ID or id.is_empty():
		return ProceduralTextures.layer_images()

	var images: Array[Image] = []
	for file_name in FILE_NAMES:
		var image := _load_image(id, file_name)
		if image == null:
			push_warning("Pack '%s' incomplet (%s), retour aux couleurs par defaut"
				% [id, file_name])
			return ProceduralTextures.layer_images()
		images.append(image)

	# Le Texture2DArray impose des couches de dimensions identiques : on le
	# verifie ici pour donner un message clair, plutot que de laisser Godot
	# refuser le tableau sans dire laquelle des huit est en cause.
	var size := images[0].get_size()
	for i in images.size():
		if images[i].get_size() != size:
			push_warning("Pack '%s' : %s fait %v au lieu de %v" % [
				id, FILE_NAMES[i], images[i].get_size(), size])
			return ProceduralTextures.layer_images()
		images[i].generate_mipmaps()

	return images


static func build(id: String) -> Texture2DArray:
	var array := Texture2DArray.new()
	array.create_from_images(layer_images(id))
	return array


static func _missing_files(pack_id: String) -> PackedStringArray:
	var missing := PackedStringArray()
	for file_name in FILE_NAMES:
		if _resolve(pack_id, file_name).is_empty():
			missing.append(file_name)
	return missing


static func _resolve(pack_id: String, file_name: String) -> String:
	for extension in EXTENSIONS:
		var path := "%s/%s/%s.%s" % [PACKS_DIR, pack_id, file_name, extension]
		if ResourceLoader.exists(path):
			return path
	return ""


static func _load_image(pack_id: String, file_name: String) -> Image:
	var path := _resolve(pack_id, file_name)
	if path.is_empty():
		return null
	var texture := load(path) as Texture2D
	if texture == null:
		return null
	return texture.get_image()
