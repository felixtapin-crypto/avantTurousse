extends Control

# Ecran d'apercu de carte, avant lancement de la partie.
#
# Le but n'est pas decoratif. Toute la generation a ete calibree a l'aveugle,
# en comptant des colonnes dans un script de verification : c'est ainsi qu'on
# a decouvert que le desert etait litteralement impossible (temperature et
# humidite anti-correlees) et que la neige ne sortait jamais. Un rendu 2D des
# champs rend ces reglages VISIBLES, et permet de juger une seed avant d'y
# passer une partie.
#
# C'est aussi ce que reclame le pilier "chaque partie est differente" de
# DESIGN.md : pouvoir regarder le monde tire avant de s'y engager.

const RENDER = preload("res://scenes/voxel_world/map_render.gd")

@onready var _preview: TextureRect = %Preview
@onready var _layer_list: ItemList = %LayerList
@onready var _seed_spin: SpinBox = %SeedSpin
@onready var _size_option: OptionButton = %SizeOption
@onready var _stats: RichTextLabel = %Stats
@onready var _legend: RichTextLabel = %Legend
@onready var _status: Label = %Status

const SIZES := [300, 450, 600, 800]

var _map: WorldMap
var _layer := 0


func _ready() -> void:
	for size in SIZES:
		_size_option.add_item("%d x %d" % [size, size])
	_size_option.select(SIZES.find(WorldSettings.size))
	_seed_spin.value = WorldSettings.seed_value

	for entry in RENDER.LAYERS:
		_layer_list.add_item(entry["name"])
	_layer_list.select(0)

	_regenerate()


func _on_generate_pressed() -> void:
	_regenerate()


func _on_random_seed_pressed() -> void:
	_seed_spin.value = randi() % 1000000
	_regenerate()


func _on_layer_list_item_selected(index: int) -> void:
	_layer = index
	_refresh_image()


func _on_play_blocky_pressed() -> void:
	_play("res://scenes/voxel_world/godot_voxel_world.tscn")


func _on_play_smooth_pressed() -> void:
	_play("res://scenes/voxel_world/smooth_voxel_world.tscn")


func _play(scene_path: String) -> void:
	if _map == null:
		return
	WorldSettings.seed_value = int(_seed_spin.value)
	WorldSettings.size = SIZES[_size_option.selected]
	# La carte affichee est passee telle quelle a la scene de jeu : elle a
	# deja coute son temps de calcul, et la regenerer donnerait exactement le
	# meme resultat pour rien.
	WorldSettings.prepared_map = _map
	get_tree().change_scene_to_file(scene_path)


func _regenerate() -> void:
	var size: int = SIZES[_size_option.selected]
	_status.text = "Generation de la carte %d x %d..." % [size, size]
	# Laisse une frame au libelle pour s'afficher : la generation est
	# synchrone et fige la fenetre plusieurs secondes.
	await get_tree().process_frame

	var started := Time.get_ticks_msec()
	_map = WorldMap.new(size, WorldSettings.height)
	_map.generate(int(_seed_spin.value))
	var elapsed := Time.get_ticks_msec() - started

	_refresh_image()
	_refresh_stats(elapsed)
	_status.text = "Carte generee en %d ms" % elapsed


func _refresh_image() -> void:
	if _map == null:
		return
	_preview.texture = ImageTexture.create_from_image(RENDER.render(_map, _layer))
	_legend.text = RENDER.legend(_layer)


func _refresh_stats(elapsed_ms: int) -> void:
	var counts := {}
	var land := 0
	var t_min := INF
	var t_max := -INF
	var m_min := INF
	var m_max := -INF

	for z in _map.size_xz:
		for x in _map.size_xz:
			var b := _map.biome_at(x, z)
			counts[b] = int(counts.get(b, 0)) + 1
			if _map.terrain_height(x, z) <= WorldMap.SEA_LEVEL:
				continue
			land += 1
			var t := _map.temperature_at(x, z)
			var m := _map.moisture_at(x, z)
			t_min = minf(t_min, t)
			t_max = maxf(t_max, t)
			m_min = minf(m_min, m)
			m_max = maxf(m_max, m)

	var total := _map.size_xz * _map.size_xz
	var lines := PackedStringArray()
	lines.append("[b]Carte[/b]  %d x %d · seed %d · %d ms" % [
		_map.size_xz, _map.size_xz, int(_seed_spin.value), elapsed_ms])
	lines.append("[b]Terres emergees[/b]  %.1f %% (%d colonnes)" % [
		100.0 * float(land) / float(total), land])
	if land > 0:
		lines.append("[b]Temperature[/b]  %.2f .. %.2f" % [t_min, t_max])
		lines.append("[b]Humidite[/b]  %.2f .. %.2f" % [m_min, m_max])
	lines.append("")
	lines.append("[b]Biomes[/b] (part des terres)")

	var ordered := counts.keys()
	ordered.sort_custom(func(a, b): return counts[a] > counts[b])
	for b in ordered:
		if b == WorldMap.Biome.DEEP_SEA or b == WorldMap.Biome.SHALLOW_SEA:
			continue
		var share := 100.0 * float(counts[b]) / float(maxi(land, 1))
		lines.append("  %-12s %5.1f %%" % [_map.biome_name(b), share])

	# Un biome present dans le code mais absent de la carte est un seuil mal
	# calibre, pas une fonctionnalite : autant le dire ici plutot que de le
	# decouvrir en jeu.
	var missing := PackedStringArray()
	for required in [WorldMap.Biome.BEACH, WorldMap.Biome.DESERT,
			WorldMap.Biome.SNOW, WorldMap.Biome.RIVER, WorldMap.Biome.FOREST]:
		if int(counts.get(required, 0)) == 0:
			missing.append(_map.biome_name(required))
	if missing.size() > 0:
		lines.append("")
		lines.append("[color=#e08040][b]Absents de cette carte :[/b] %s[/color]"
			% ", ".join(missing))

	_stats.text = "\n".join(lines)
