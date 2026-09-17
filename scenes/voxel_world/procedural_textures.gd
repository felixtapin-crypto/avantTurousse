class_name ProceduralTextures
extends RefCounted

# Textures de terrain generees a partir de la palette du projet, en attendant
# de vraies matieres (voir le nuancier des textures a fournir).
#
# ---------------------------------------------------------------------------
# LA CONTRAINTE DURE : LE RACCORD
# ---------------------------------------------------------------------------
#
# Le shader projette la MEME image depuis les trois axes (projection
# triplanaire), et la repete tous les 6,7 metres. Une texture qui ne se
# raccorde pas parfaitement affiche donc sa couture partout sur la carte, sur
# trois orientations a la fois.
#
# `FastNoiseLite` ne sait pas boucler. On implemente donc un bruit de valeur
# dont le RESEAU boucle : les coordonnees de cellule sont prises modulo la
# periode, si bien que le bord droit retombe exactement sur le bord gauche.
# C'est exact, pas approche — contrairement aux methodes par fondu en miroir,
# qui laissent un fantome au milieu de l'image.
#
# La version precedente contournait le probleme avec du bruit blanc par
# pixel : raccordable par construction, mais sans aucune structure. On voyait
# la forme du relief, jamais la matiere.

const SIZE := 128

# Ordre impose par `TerrainGenerator.Layer` : l'index dans le tableau est
# l'identifiant de matiere lu par le shader.
const LAYER_ORDER: Array[int] = [
	TerrainMaterials.Type.GRASS,
	TerrainMaterials.Type.DIRT,
	TerrainMaterials.Type.STONE,
	TerrainMaterials.Type.STONE_DARK,
	TerrainMaterials.Type.SAND,
	TerrainMaterials.Type.SAND_PALE,
	TerrainMaterials.Type.GRAVEL,
	TerrainMaterials.Type.SNOW,
]


static func layer_images() -> Array[Image]:
	var layers: Array[Image] = []
	for type in LAYER_ORDER:
		layers.append(_build_layer(type))
	return layers


static func build() -> Texture2DArray:
	var array := Texture2DArray.new()
	array.create_from_images(layer_images())
	return array


static func _build_layer(type: int) -> Image:
	var base: Color = TerrainMaterials.COLOR[type]
	var image := Image.create(SIZE, SIZE, true, Image.FORMAT_RGB8)
	# Une graine par matiere : deux couches voisines ne doivent pas partager
	# le meme motif, sinon la transition entre biomes se voit comme un simple
	# changement de teinte sur un relief identique.
	var seed_value := type * 7919

	for y in SIZE:
		var v := float(y) / float(SIZE)
		for x in SIZE:
			var u := float(x) / float(SIZE)
			image.set_pixel(x, y, _pixel(type, base, u, v, seed_value))

	image.generate_mipmaps()
	return image


static func _pixel(type: int, base: Color, u: float, v: float, s: int) -> Color:
	match type:
		TerrainMaterials.Type.GRASS:
			# Touffes larges, puis brins fins. Les creux sont plus sombres et
			# plus satures, les sommets tirent vers le jaune : c'est ce qui
			# distingue une prairie d'un aplat vert.
			var clumps := _fbm(u, v, 6, 4, s)
			var blades := _fbm(u, v, 28, 2, s + 31)
			var lift := clumps * 0.75 + blades * 0.25
			return _vary(base, 0.70 + lift * 0.62, lift * 0.035 - 0.012, 1.18 - lift * 0.42)

		TerrainMaterials.Type.DIRT:
			# Mottes contrastees et quelques cailloux sombres.
			var lumps := _contrast(_fbm(u, v, 8, 4, s), 1.7)
			var grit := _fbm(u, v, 40, 1, s + 17)
			var shade := 0.68 + lumps * 0.55
			if grit > 0.78:
				shade *= 0.82
			return _vary(base, shade, lumps * 0.02 - 0.008, 1.0 + lumps * 0.2)

		TerrainMaterials.Type.STONE:
			return _rock(base, u, v, s, 0.86, 1.16, 0.55)

		TerrainMaterials.Type.STONE_DARK:
			# Meme matiere, plus serree et plus sourde : c'est la bedrock, elle
			# doit se lire comme une roche plus ancienne et plus dense.
			return _rock(base, u, v, s, 0.88, 1.08, 0.68)

		TerrainMaterials.Type.SAND:
			return _sand(base, u, v, s, 0.88, 1.10)

		TerrainMaterials.Type.SAND_PALE:
			# Le sable sec accroche plus la lumiere et garde des ondulations
			# plus amples que le sable mouille du rivage.
			return _sand(base, u, v, s, 0.86, 1.16)

		TerrainMaterials.Type.GRAVEL:
			# Galets : on isole les bords de cellules du bruit et on les
			# assombrit, ce qui donne des contours plutot qu'un moutonnement.
			var cells := _fbm(u, v, 14, 2, s)
			var edge := 1.0 - smoothstep(0.0, 0.10, absf(cells - 0.5))
			var speck := _fbm(u, v, 34, 1, s + 53)
			var value := 0.80 + cells * 0.42 + speck * 0.12
			return _vary(base, value * (1.0 - edge * 0.38), 0.0, 1.0)

		TerrainMaterials.Type.SNOW:
			# Tres peu de contraste — la neige se lit par son ombrage, pas par
			# sa texture — et un bleu leger dans les creux.
			var drifts := _fbm(u, v, 5, 3, s)
			var sparkle := _fbm(u, v, 45, 1, s + 11)
			var value := 0.93 + drifts * 0.09 + sparkle * 0.04
			return _vary(base, value, (1.0 - drifts) * 0.012, 1.0 + (1.0 - drifts) * 0.9)

	return base


static func _rock(base: Color, u: float, v: float, s: int, low: float, high: float, crack: float) -> Color:
	var grain := _fbm(u, v, 10, 4, s)
	# Bruit ridge : les lignes de crete du bruit font des fissures credibles,
	# la ou un simple seuil donnerait des taches.
	var ridge := pow(1.0 - absf(_fbm(u, v, 7, 3, s + 23) * 2.0 - 1.0), 6.0)
	var value := lerpf(low, high, grain) * lerpf(1.0, crack, ridge)
	return _vary(base, value, 0.0, 1.0 - grain * 0.15)


static func _sand(base: Color, u: float, v: float, s: int, low: float, high: float) -> Color:
	# Ondulations isotropes, sans direction marquee : une ride orientee
	# apparaitrait tournee d'une pente a l'autre, la projection triplanaire
	# plaquant la meme image selon trois axes.
	var dunes := _fbm(u, v, 6, 2, s)
	var grain := _fbm(u, v, 48, 2, s + 41)
	var value := lerpf(low, high, dunes * 0.72 + grain * 0.28)
	return _vary(base, value, (dunes - 0.5) * 0.012, 1.0 + (0.5 - dunes) * 0.18)


# --- Bruit raccordable ------------------------------------------------------

# Bruit de valeur dont le reseau boucle sur `period` cellules : les indices de
# cellule sont pris modulo la periode, donc la colonne de droite partage ses
# gradients avec celle de gauche. L'image se raccorde exactement.
static func _value_noise(u: float, v: float, period: int, s: int) -> float:
	var x := u * float(period)
	var y := v * float(period)
	var x0 := int(floor(x))
	var y0 := int(floor(y))
	var fx := x - float(x0)
	var fy := y - float(y0)
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)

	var x1 := (x0 + 1) % period
	var y1 := (y0 + 1) % period
	x0 = x0 % period
	y0 = y0 % period

	var a := _hash(x0, y0, s)
	var b := _hash(x1, y0, s)
	var c := _hash(x0, y1, s)
	var d := _hash(x1, y1, s)
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)


# Octaves successives, chacune de periode double. Toutes bouclent, donc leur
# somme boucle aussi.
static func _fbm(u: float, v: float, base_period: int, octaves: int, s: int) -> float:
	var total := 0.0
	var amplitude := 1.0
	var norm := 0.0
	var period := base_period
	for i in octaves:
		total += _value_noise(u, v, period, s + i * 101) * amplitude
		norm += amplitude
		amplitude *= 0.5
		period *= 2
	return total / norm


static func _hash(ix: int, iy: int, s: int) -> float:
	var h := ix * 374761393 + iy * 668265263 + s * 1442695041
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xffff) / 65535.0


static func _contrast(value: float, amount: float) -> float:
	return clampf((value - 0.5) * amount + 0.5, 0.0, 1.0)


static func _vary(base: Color, value_mul: float, hue_shift: float, sat_mul: float) -> Color:
	return Color.from_hsv(
		fposmod(base.h + hue_shift, 1.0),
		clampf(base.s * sat_mul, 0.0, 1.0),
		clampf(base.v * value_mul, 0.0, 1.0))
