class_name SmoothTextureArray
extends RefCounted

# Tableau de textures BOUCHON pour le terrain lisse.
#
# Le shader lisse echantillonne un `Texture2DArray` en projection triplanaire,
# une couche par matiere. On n'a pas encore ces textures : le pack KayKit est
# un nuancier d'aplats, pas un jeu de matieres carrelables (voir issue #30).
#
# En attendant, chaque couche est l'aplat KayKit de la matiere, avec un
# tramage par pixel de quelques pourcents. Ce tramage est volontairement du
# bruit blanc et non un motif : il accroche la lumiere sans introduire de
# basse frequence, donc il reste raccordable sans couture visible — ce qui
# compte en triplanaire, ou la meme texture est projetee selon trois axes.
#
# Le but est de pouvoir juger la FORME du terrain lisse (silhouette, pentes,
# ombrage) avant d'investir dans de vraies matieres. La liste des textures a
# fournir est dans l'ordre de `KayKitSmoothGenerator.Layer`.

const SIZE := 64
const DITHER := 0.05


static func build() -> Texture2DArray:
	var layers: Array[Image] = []
	for type in [
		BlockLibrary.Type.GRASS,
		BlockLibrary.Type.DIRT,
		BlockLibrary.Type.STONE,
		BlockLibrary.Type.STONE_DARK,
		BlockLibrary.Type.SAND,
		BlockLibrary.Type.SAND_PALE,
		BlockLibrary.Type.GRAVEL,
		BlockLibrary.Type.SNOW,
	]:
		layers.append(_flat_layer(BlockLibrary.COLOR[type]))

	var array := Texture2DArray.new()
	array.create_from_images(layers)
	return array


static func _flat_layer(color: Color) -> Image:
	var image := Image.create(SIZE, SIZE, true, Image.FORMAT_RGB8)
	# Graine fixe par couche : deux lancements donnent la meme texture, donc
	# une capture d'ecran reste comparable d'une session a l'autre.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(color)
	for y in SIZE:
		for x in SIZE:
			var jitter := rng.randf_range(-DITHER, DITHER)
			image.set_pixel(x, y, Color(
				clampf(color.r + jitter, 0.0, 1.0),
				clampf(color.g + jitter, 0.0, 1.0),
				clampf(color.b + jitter, 0.0, 1.0)))
	image.generate_mipmaps()
	return image
