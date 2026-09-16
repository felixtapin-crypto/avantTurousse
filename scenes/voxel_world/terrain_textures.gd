class_name TerrainTextures
extends RefCounted

# Textures du terrain : albedo et normales, une couche par matiere.
#
# Source ambientCG (CC0), voir assets/terrain_textures/SOURCE.md. L'ordre est
# celui de `TerrainGenerator.Layer` — c'est un contrat avec le shader, et s'en
# ecarter repeint le monde sans lever d'erreur.

const DIR := "res://assets/terrain_textures"

const NAMES: Array[String] = [
	"grass", "dirt", "stone", "stone_dark",
	"sand", "sand_pale", "gravel", "snow",
]

# Etendue reelle representee par chaque texture, en metres.
#
# C'est le reglage qui decide si un galet a la taille d'un galet ou d'un
# rocher. Ces textures vont de 1,4 m a 3,5 m de cote : un facteur 2,5 entre
# elles, donc une echelle globale unique ne peut pas convenir — a repetition
# constante, le sable sec paraitrait deux fois et demie plus gros que la
# terre.
#
# Les valeurs viennent du champ `dimensionX` de l'API ambientCG, exprime en
# centimetres. Trois assets ne le renseignent pas (Rock030, Rock035,
# Ground057) : les valeurs marquees "estime" sont a ajuster a l'oeil, ce sont
# les seules qui ne reposent pas sur une mesure.
const METERS: Array[float] = [
	2.1,  # grass      — Ground037, mesure
	1.4,  # dirt       — Ground048, mesure
	2.5,  # stone      — Rock030, estime
	2.5,  # stone_dark — Rock035, estime
	1.5,  # sand       — Ground057, estime
	3.5,  # sand_pale  — Ground054, mesure
	1.5,  # gravel     — Ground108, mesure
	2.5,  # snow       — Snow006, mesure
]

# Rugosite par matiere, moyenne relevee sur la carte de rugosite d'ambientCG.
#
# Une carte par texel aurait demande un troisieme tableau, donc douze lectures
# de texture de plus par fragment, pour des cartes assez uniformes d'une
# matiere a l'autre. Une constante par couche rend l'essentiel de l'effet
# gratuitement : l'herbe et le sable humide accrochent la lumiere, la roche et
# la terre seche la diffusent.
const ROUGHNESS: Array[float] = [
	0.46,  # grass
	0.67,  # dirt
	0.69,  # stone
	0.69,  # stone_dark
	0.45,  # sand
	0.67,  # sand_pale
	0.52,  # gravel
	0.51,  # snow
]


static func albedo_array() -> Texture2DArray:
	return _array("color")


static func normal_array() -> Texture2DArray:
	return _array("normal")


# Hauteurs (carte `Displacement` d'ambientCG). Elles ne deplacent aucun sommet :
# elles servent a departager deux matieres qui se recouvrent, pour que la plus
# haute perce l'autre au lieu de se fondre avec elle.
static func height_array() -> Texture2DArray:
	return _array("height")


static func _array(suffix: String) -> Texture2DArray:
	var images: Array[Image] = []
	for name in NAMES:
		var image := _load("%s/%s_%s.jpg" % [DIR, name, suffix])
		if image == null:
			# Repli sur les aplats generes : un depot incomplet doit rester
			# jouable plutot que de refuser de demarrer.
			push_warning("Texture %s_%s absente, retour aux couleurs generees" % [name, suffix])
			return ProceduralTextures.build()
		images.append(image)

	var size := images[0].get_size()
	for i in images.size():
		if images[i].get_size() != size:
			push_warning("%s_%s fait %v au lieu de %v" % [NAMES[i], suffix, images[i].get_size(), size])
			return ProceduralTextures.build()
		images[i].generate_mipmaps()

	var array := Texture2DArray.new()
	array.create_from_images(images)
	return array


static func _load(path: String) -> Image:
	if not ResourceLoader.exists(path):
		return null
	var texture := load(path) as Texture2D
	if texture == null:
		return null
	return texture.get_image()


# Les uniformes de tableau du shader attendent des Packed*Array. La conversion
# se fait ici plutot que dans une constante : une constante initialisee par un
# constructeur n'est pas resolue comme expression constante depuis un autre
# script, et echoue au chargement.
static func meters() -> PackedFloat32Array:
	return PackedFloat32Array(METERS)


static func roughness() -> PackedFloat32Array:
	return PackedFloat32Array(ROUGHNESS)
