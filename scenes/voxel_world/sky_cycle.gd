class_name SkyCycle
extends Node

# Cycle jour/nuit : fait tourner le soleil, et fait suivre le ciel, la lumiere
# et l'ambiante.
#
# Le ciel est le shader stylise de GDQuest (MIT, voir assets/sky/SOURCE.md).
# Etant un `shader_type sky`, il lit la direction du soleil dans
# `LIGHT0_DIRECTION` : faire tourner la DirectionalLight3D suffit a faire
# tourner le ciel avec elle, sans rien lui transmettre.
#
# Les deux jeux de valeurs DAY et NIGHT sont repris des materiaux d'exemple du
# projet d'origine ; le cycle interpole entre les deux.
#
# La couleur de l'horizon est traitee a part, avec une troisieme teinte chaude
# au lever et au coucher. Sans elle, passer du jour a la nuit par simple
# interpolation donne un ciel qui s'assombrit sans jamais rougeoyer — c'est le
# reglage qui fait qu'on croit a l'heure qu'il est.
#
# Note : ce cycle est propre a la scene voxel. `scenes/world/day_night_cycle.gd`
# reste celui de l'ancienne scene, et n'est pas touche.

const SKY_SHADER := "res://assets/sky/stylized_sky.gdshader"
const SHOOTING_STAR := "res://assets/sky/shooting_star_sampler.png"

# Valeurs relevees dans day_sky.tres et night_sky.tres.
const DAY := {
	"clouds_smoothness": 0.03,
	"clouds_light_color": Color(1.0, 1.0, 1.0),
	"clouds_shadow_intensity": 3.5,
	"high_clouds_density": 0.2,
	"top_color": Color(0.349, 0.588, 1.0),
	"bottom_color": Color(0.0, 0.329, 0.969),
	"astro_tint": Color(0.906, 0.788, 0.627),
	"astro_scale": 9.0,
	"astro_intensity": 3.0,
	"stars_intensity": 0.0,
	"shooting_stars_intensity": 0.0,
}

const NIGHT := {
	"clouds_smoothness": 0.05,
	"clouds_light_color": Color(0.227, 0.447, 1.0),
	"clouds_shadow_intensity": 8.0,
	"high_clouds_density": 0.0,
	"top_color": Color(0.027, 0.102, 0.251),
	"bottom_color": Color(0.027, 0.102, 0.251),
	"astro_tint": Color(1.0, 1.0, 1.0),
	"astro_scale": 6.0,
	"astro_intensity": 1.2,
	"stars_intensity": 5.0,
	"shooting_stars_intensity": 4.0,
}

# Diffusion a l'horizon : grise en plein jour, violette la nuit, chaude au
# ras du soleil.
const SCATTER_DAY := Color(0.298, 0.298, 0.298)
const SCATTER_NIGHT := Color(0.125, 0.086, 0.373)
const SCATTER_HORIZON := Color(0.95, 0.42, 0.16)

const SUN_DAY := Color(1.0, 0.96, 0.89)
const SUN_HORIZON := Color(1.0, 0.62, 0.34)
const MOON := Color(0.52, 0.62, 0.85)

const SUN_ENERGY_DAY := 1.1
const SUN_ENERGY_NIGHT := 0.04
const AMBIENT_DAY := 0.85
const AMBIENT_NIGHT := 0.30
# Inclinaison de l'axe du soleil : sans elle il passe au zenith exact et les
# ombres disparaissent a midi.
const SUN_TILT := -38.0

# 0.0 = minuit, 0.25 = aube, 0.5 = midi, 0.75 = crepuscule.
var time_of_day := 0.30
var day_length_seconds := 900.0
var paused := false

var _sun: DirectionalLight3D
var _environment: Environment
var _sky_material: ShaderMaterial


func setup(sun: DirectionalLight3D, environment: Environment) -> void:
	_sun = sun
	_environment = environment
	_sky_material = _build_sky_material()

	var sky := Sky.new()
	sky.sky_material = _sky_material
	_environment.background_mode = Environment.BG_SKY
	_environment.sky = sky
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	apply()


func _process(delta: float) -> void:
	if _sun == null or paused:
		return
	time_of_day = fposmod(time_of_day + delta / maxf(day_length_seconds, 1.0), 1.0)
	apply()


# Heure lisible, au format 24 h.
func clock() -> String:
	var minutes := int(time_of_day * 24.0 * 60.0)
	@warning_ignore("integer_division")
	return "%02d:%02d" % [minutes / 60, minutes % 60]


func apply() -> void:
	if _sun == null:
		return

	# Hauteur du soleil : -1 a minuit, +1 a midi, 0 pile a l'horizon.
	var sun_height := -cos(time_of_day * TAU)
	# Le jour s'installe vite une fois le soleil leve : une interpolation
	# lineaire sur la hauteur du soleil laissait le monde dans la penombre
	# jusqu'a la mi-matinee, alors que l'horloge affichait sept heures.
	var day := smoothstep(-0.05, 0.28, sun_height)
	# Etroit autour de l'horizon : c'est la fenetre du lever et du coucher.
	var horizon := 1.0 - clampf(absf(sun_height) * 3.2, 0.0, 1.0)

	_sun.rotation_degrees = Vector3((time_of_day - 0.25) * 360.0, SUN_TILT, 0.0)
	_sun.light_energy = lerpf(SUN_ENERGY_NIGHT, SUN_ENERGY_DAY, day)
	_sun.light_color = MOON.lerp(SUN_DAY, day).lerp(SUN_HORIZON, horizon * 0.8)
	# Sous l'horizon, le soleil eclairerait le terrain par en dessous.
	_sun.visible = sun_height > -0.08

	_environment.ambient_light_energy = lerpf(AMBIENT_NIGHT, AMBIENT_DAY, day)

	for key in DAY.keys():
		var night_value = NIGHT[key]
		var day_value = DAY[key]
		if day_value is Color:
			_sky_material.set_shader_parameter(key, (night_value as Color).lerp(day_value, day))
		else:
			_sky_material.set_shader_parameter(key, lerpf(night_value, day_value, day))

	var scatter := SCATTER_NIGHT.lerp(SCATTER_DAY, day).lerp(SCATTER_HORIZON, horizon)
	_sky_material.set_shader_parameter("sun_scatter", scatter)


# Les textures du ciel (formes de nuages, nuages hauts, courbe de densite,
# disque solaire) sont des bruits et des degrades : les construire coute moins
# cher que de les versionner, et elles restent lisibles ici plutot que cachees
# dans un .tres.
func _build_sky_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(SKY_SHADER)

	material.set_shader_parameter("clouds_samples", 32)
	material.set_shader_parameter("shadow_sample", 4)
	material.set_shader_parameter("clouds_density", 0.4)
	material.set_shader_parameter("clouds_scale", 1.0)
	material.set_shader_parameter("cloud_shape_sampler", _noise(10, -1))
	material.set_shader_parameter("cloud_noise_sampler", _noise(5, -1))
	material.set_shader_parameter("high_clouds_sampler", _noise(5, FastNoiseLite.TYPE_PERLIN))
	material.set_shader_parameter("cloud_curves", _density_curve())
	material.set_shader_parameter("astro_sampler", _astro_disc())
	material.set_shader_parameter("shooting_star_sampler", load(SHOOTING_STAR))
	material.set_shader_parameter("shooting_star_tint", Color(1.0, 0.663, 0.42))
	return material


func _noise(octaves: int, type: int) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.fractal_octaves = octaves
	if type >= 0:
		noise.noise_type = type
	var texture := NoiseTexture2D.new()
	texture.seamless = true
	texture.noise = noise
	return texture


func _density_curve() -> CurveTexture:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.0), 0.0, 10.0)
	curve.add_point(Vector2(0.1, 1.0))
	curve.add_point(Vector2(1.0, 0.8), -0.222, 0.0)
	var texture := CurveTexture.new()
	texture.texture_mode = CurveTexture.TEXTURE_MODE_RED
	texture.curve = curve
	return texture


func _astro_disc() -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.48, 0.6])
	gradient.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	return texture
