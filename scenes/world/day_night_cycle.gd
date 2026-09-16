class_name DayNightCycle
extends Node

# Fait tourner le soleil et derive les couleurs du ciel/de la lumiere en
# fonction de l'heure. Chaque pair (hote/client) fait tourner son propre
# cycle independamment, a la meme vitesse, a partir du meme point de depart
# (voir time_of_day) : purement cosmetique pour l'instant, donc pas besoin
# de synchroniser en reseau - un ecart de quelques secondes entre deux
# joueurs ne se voit pas. Si la meteo/le jour-nuit finissent par influer sur
# des jauges de survie partagees, il faudra revoir ça (voir TASKS.md).

@export var day_length_seconds: float = 900.0 # duree d'un cycle complet (~15 min)
@export var sun_path: NodePath
@export var environment_path: NodePath

# 0.0 = minuit, 0.25 = aube, 0.5 = midi, 0.75 = crepuscule. On demarre juste
# apres l'aube pour une premiere impression agreable en debut de partie.
var time_of_day: float = 0.3

var _sun: DirectionalLight3D
var _world_environment: WorldEnvironment
var _environment: Environment


func _ready() -> void:
	_sun = get_node(sun_path)
	_world_environment = get_node(environment_path)

	_environment = Environment.new()
	var sky_material := ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_material
	_environment.background_mode = Environment.BG_SKY
	_environment.sky = sky
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_world_environment.environment = _environment

	_update()


func _process(delta: float) -> void:
	time_of_day = fmod(time_of_day + delta / day_length_seconds, 1.0)
	_update()


func _update() -> void:
	# hauteur du soleil : -1 (minuit) a 1 (midi), 0 pile a l'horizon
	var sun_height := -cos(time_of_day * TAU)
	var day_amount := clampf(sun_height, 0.0, 1.0)
	var horizon_amount := 1.0 - clampf(absf(sun_height) * 3.0, 0.0, 1.0)

	_sun.rotation_degrees = Vector3((time_of_day - 0.25) * 360.0, -30.0, 0.0)

	var day_color := Color(1.0, 0.95, 0.85)
	var horizon_color := Color(1.0, 0.55, 0.25)
	var night_color := Color(0.4, 0.5, 0.8)
	_sun.light_color = day_color.lerp(horizon_color, horizon_amount).lerp(night_color, 1.0 - day_amount)
	_sun.light_energy = lerp(0.05, 1.2, day_amount)

	var sky_material := _environment.sky.sky_material as ProceduralSkyMaterial
	var day_top := Color(0.35, 0.55, 0.85)
	var night_top := Color(0.02, 0.02, 0.08)
	var day_horizon := Color(0.75, 0.8, 0.85)
	var night_horizon := Color(0.05, 0.05, 0.15)
	sky_material.sky_top_color = day_top.lerp(night_top, 1.0 - day_amount)
	sky_material.sky_horizon_color = day_horizon.lerp(night_horizon, 1.0 - day_amount).lerp(horizon_color, horizon_amount * 0.6)
	_environment.ambient_light_energy = lerp(0.15, 1.0, day_amount)
