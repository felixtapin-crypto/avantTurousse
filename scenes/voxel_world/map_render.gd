extends RefCounted

# Rendu 2D des champs de `WorldMap`, pour l'ecran d'apercu.
#
# Chaque couche montre UNE etape de la chaine de generation. C'est ce qui
# permet de diagnostiquer un biome absent sans relire la table des seuils :
# on regarde ou il fait chaud, ou il fait sec, et on voit tout de suite si
# l'intersection existe quelque part.
#
# L'image est construite dans un PackedByteArray puis passee d'un bloc a
# `Image.create_from_data`. Une carte de 600 fait 360 000 pixels, et autant
# d'appels a `set_pixel` couteraient plusieurs secondes.

const LAYERS: Array[Dictionary] = [
	{"name": "Biomes", "id": "biomes"},
	{"name": "Relief", "id": "relief"},
	{"name": "Temperature", "id": "temperature"},
	{"name": "Humidite", "id": "moisture"},
	{"name": "Latitude / equateur", "id": "latitude"},
	{"name": "Ombre pluviometrique", "id": "shadow"},
	{"name": "Hydrologie", "id": "flow"},
	{"name": "Continentalite", "id": "continentality"},
]

const SEA_DEEP := Color(0.05, 0.13, 0.28)
const SEA_SHALLOW := Color(0.16, 0.40, 0.62)

# Teintes du jeu pour les biomes emerges, afin que la carte et le monde se
# ressemblent. La foret est assombrie pour se distinguer de la prairie, que
# les blocs rendent pourtant identiques.
const BIOME_COLOR: Dictionary = {
	WorldMap.Biome.DEEP_SEA: SEA_DEEP,
	WorldMap.Biome.SHALLOW_SEA: SEA_SHALLOW,
	WorldMap.Biome.BEACH: Color(0.808, 0.600, 0.396),
	WorldMap.Biome.RIVER: Color(0.30, 0.68, 0.92),
	WorldMap.Biome.DESERT: Color(0.890, 0.745, 0.557),
	WorldMap.Biome.PLAINS: Color(0.20, 0.62, 0.36),
	WorldMap.Biome.FOREST: Color(0.09, 0.38, 0.21),
	WorldMap.Biome.ROCK: Color(0.365, 0.392, 0.408),
	WorldMap.Biome.SCREE: Color(0.52, 0.53, 0.52),
	WorldMap.Biome.SNOW: Color(0.90, 0.92, 0.94),
}


static func render(map: WorldMap, layer_index: int) -> Image:
	var size := map.size_xz
	var data := PackedByteArray()
	data.resize(size * size * 3)

	var layer: String = LAYERS[layer_index]["id"]
	var max_log_flow := _max_log_flow(map) if layer == "flow" else 1.0

	var i := 0
	for z in size:
		for x in size:
			var color := _color_at(map, layer, x, z, max_log_flow)
			data[i] = int(clampf(color.r, 0.0, 1.0) * 255.0)
			data[i + 1] = int(clampf(color.g, 0.0, 1.0) * 255.0)
			data[i + 2] = int(clampf(color.b, 0.0, 1.0) * 255.0)
			i += 3

	return Image.create_from_data(size, size, false, Image.FORMAT_RGB8, data)


static func _color_at(map: WorldMap, layer: String, x: int, z: int, max_log_flow: float) -> Color:
	var height := map.terrain_height(x, z)
	var submerged := height <= WorldMap.SEA_LEVEL

	match layer:
		"biomes":
			return BIOME_COLOR.get(map.biome_at(x, z), Color.MAGENTA)

		"relief":
			if submerged:
				# Profondeur : plus c'est creux, plus c'est sombre.
				var depth := clampf(float(WorldMap.SEA_LEVEL - height) / 14.0, 0.0, 1.0)
				return SEA_SHALLOW.lerp(SEA_DEEP, depth)
			# Ombrage porte : on eclaire la pente depuis le nord-ouest. Sans
			# lui, une carte d'altitude en niveaux de gris ne laisse pas lire
			# les vallees creusees par l'erosion.
			var dx := map.terrain_height_f(x + 1, z) - map.terrain_height_f(x - 1, z)
			var dz := map.terrain_height_f(x, z + 1) - map.terrain_height_f(x, z - 1)
			var shade := clampf(0.5 + (-dx - dz) * 0.18, 0.15, 1.0)
			var band := clampf(float(height - WorldMap.SEA_LEVEL) / 26.0, 0.0, 1.0)
			return Color(0.32, 0.45, 0.26).lerp(Color(0.92, 0.88, 0.80), band) * shade

		"temperature":
			if submerged:
				return SEA_DEEP * 0.6
			return _ramp(map.temperature_at(x, z), [
				Color(0.20, 0.30, 0.75), Color(0.25, 0.70, 0.85),
				Color(0.95, 0.90, 0.40), Color(0.85, 0.25, 0.15)])

		"moisture":
			if submerged:
				return SEA_DEEP * 0.6
			return _ramp(map.moisture_at(x, z), [
				Color(0.82, 0.70, 0.42), Color(0.75, 0.78, 0.35),
				Color(0.25, 0.65, 0.40), Color(0.12, 0.35, 0.70)])

		"latitude":
			var lat := map.latitude_temperature(z)
			var normalized := 0.5 + lat / maxf(WorldMap.TEMP_LATITUDE, 0.0001)
			var base := _ramp(clampf(normalized, 0.0, 1.0), [
				Color(0.20, 0.30, 0.75), Color(0.95, 0.90, 0.40), Color(0.85, 0.25, 0.15)])
			# Isolignes tous les 0,05 de contribution, pour lire le gradient.
			if absf(fmod(lat, 0.05)) < 0.004:
				base = base.darkened(0.45)
			if submerged:
				base = base.lerp(SEA_DEEP, 0.55)
			return base

		"shadow":
			var shadow := map.rain_shadow_at(x, z)
			if submerged:
				return SEA_DEEP * 0.6
			return Color(0.30, 0.55, 0.85).lerp(Color(0.75, 0.55, 0.25), shadow)

		"flow":
			if submerged:
				return SEA_DEEP * 0.7
			var intensity := clampf(log(1.0 + map.flow_at(x, z)) / max_log_flow, 0.0, 1.0)
			# Racine : sans elle, seuls les tres gros collecteurs ressortent et
			# le reseau ramifie reste invisible.
			intensity = sqrt(intensity)
			return Color(0.10, 0.12, 0.10).lerp(Color(0.35, 0.80, 1.0), intensity)

		"continentality":
			if submerged:
				return SEA_DEEP * 0.6
			return Color(0.20, 0.55, 0.60).lerp(Color(0.85, 0.65, 0.30),
				map.continentality_at(x, z))

	return Color.MAGENTA


static func _ramp(t: float, stops: Array) -> Color:
	var clamped := clampf(t, 0.0, 1.0) * float(stops.size() - 1)
	var index := int(floor(clamped))
	if index >= stops.size() - 1:
		return stops[stops.size() - 1]
	return stops[index].lerp(stops[index + 1], clamped - float(index))


static func _max_log_flow(map: WorldMap) -> float:
	var highest := 0.0
	for z in map.size_xz:
		for x in map.size_xz:
			highest = maxf(highest, map.flow_at(x, z))
	return maxf(log(1.0 + highest), 1.0)


static func legend(layer_index: int) -> String:
	match LAYERS[layer_index]["id"]:
		"biomes":
			var parts := PackedStringArray()
			for biome in BIOME_COLOR.keys():
				var color: Color = BIOME_COLOR[biome]
				parts.append("[color=#%s]■[/color] %s" % [color.to_html(false), _biome_label(biome)])
			return "  ".join(parts)
		"relief":
			return "Altitude du sol, eclairee depuis le nord-ouest. Les vallees en arete de poisson sont l'oeuvre de l'incision fluviale, pas du bruit."
		"temperature":
			return "[color=#3344bf]■[/color] froid  →  [color=#d94026]■[/color] chaud. Combine la latitude et le refroidissement par l'altitude."
		"moisture":
			return "[color=#d1b26b]■[/color] sec  →  [color=#1f59b3]■[/color] humide. Vient de la mer, des rivieres, et de l'ombre pluviometrique."
		"latitude":
			return "Contribution de la seule latitude. Equateur place a %.2f de la carte : a 1.00 il tombe sur le bord sud, donc le gradient est monotone du nord froid au sud chaud." % WorldMap.TEMP_EQUATOR
		"shadow":
			return "[color=#4d8cd9]■[/color] au vent (humide)  →  [color=#bf8c40]■[/color] sous le vent (sec). C'est ce champ qui rend le desert possible."
		"flow":
			return "Debit accumule : nombre de colonnes qui s'ecoulent a travers chaque point. Les branches claires sont le reseau hydrographique."
		"continentality":
			return "[color=#338c99]■[/color] littoral  →  [color=#d9a64d]■[/color] coeur des terres. Mesuree sur le masque continental, pas sur la distance au centre."
	return ""


static func _biome_label(biome: int) -> String:
	match biome:
		WorldMap.Biome.DEEP_SEA: return "mer profonde"
		WorldMap.Biome.SHALLOW_SEA: return "mer cotiere"
		WorldMap.Biome.BEACH: return "plage"
		WorldMap.Biome.RIVER: return "riviere"
		WorldMap.Biome.DESERT: return "desert"
		WorldMap.Biome.PLAINS: return "prairie"
		WorldMap.Biome.FOREST: return "foret"
		WorldMap.Biome.ROCK: return "rocaille"
		WorldMap.Biome.SCREE: return "eboulis"
		WorldMap.Biome.SNOW: return "neige"
	return "?"
