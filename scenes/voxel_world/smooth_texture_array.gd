class_name SmoothTextureArray
extends RefCounted

# Tableau de textures BOUCHON pour le terrain lisse.
#
# Le shader lisse echantillonne un `Texture2DArray` en projection triplanaire,
# une couche par matiere. On n'a pas encore ces matieres : la palette dont
# le projet est parti est un nuancier d'aplats, pas un jeu de textures
# carrelables (voir issue #30).
#
# En attendant, chaque couche est l'aplat de la matiere, avec un
# tramage par pixel de quelques pourcents. Ce tramage est volontairement du
# bruit blanc et non un motif : il accroche la lumiere sans introduire de
# basse frequence, donc il reste raccordable sans couture visible — ce qui
# compte en triplanaire, ou la meme texture est projetee selon trois axes.
#
# Le but est de pouvoir juger la FORME du terrain lisse (silhouette, pentes,
# ombrage) avant d'investir dans de vraies matieres. La liste des textures a
# fournir est dans l'ordre de `TerrainGenerator.Layer`.

const SIZE := 64
const DITHER := 0.05


static func build() -> Texture2DArray:
	var layers: Array[Image] = []
	for type in [
		TerrainMaterials.Type.GRASS,
		TerrainMaterials.Type.DIRT,
		TerrainMaterials.Type.STONE,
		TerrainMaterials.Type.STONE_DARK,
		TerrainMaterials.Type.SAND,
		TerrainMaterials.Type.SAND_PALE,
		TerrainMaterials.Type.GRAVEL,
		TerrainMaterials.Type.SNOW,
	]:
		layers.append(_flat_layer(TerrainMaterials.COLOR[type]))

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
