class_name SkyCycle
extends Node

# Cycle jour/nuit : fait decrire au soleil un arc selon l'heure, et fait suivre
# le ciel, la lumiere, l'ambiante et le brouillard.
#
# Le ciel est `assets/sky/atmosphere.gdshader`, repris du projet terrain-3d de
# Guillaume (voir assets/sky/SOURCE.md) : diffusion de Rayleigh/Mie/ozone
# calculee sur une atmosphere spherique, nuages cumulus en ray-marching,
# cirrus, et surtout des ASTRES.
#
# Un `shader_type sky` lit les lumieres directionnelles de la scene sous les
# noms LIGHT0..LIGHT3. Il suffit donc d'ajouter trois DirectionalLight3D pour
# obtenir une lune et deux planetes : le shader dessine leur disque, a la
# taille que donne `light_angular_distance`. C'est pour ca qu'elles sont creees
# ici et pas dans la scene — leur ORDRE decide de leur indice, et le ciel n'a
# aucun autre moyen de les distinguer.
#
# Trois points valent d'etre releves, parce qu'ils ne se devinent pas :
#
# - le soleil n'est JAMAIS cache. On met son energie a zero la nuit, mais le
#   masquer le retirerait de LIGHT0 et le ciel perdrait la direction qui lui
#   sert a calculer le couchant.
# - l'ambiante est en mode COULEUR, pas SKY. Ce ciel est HDR : sa radiance de
#   nuit reste assez forte pour eclairer le monde comme en plein jour.
# - l'ambiante suit la clarte du CIEL, pas le soleil direct. La diffusion
#   atmospherique garde le ciel clair bien apres que le soleil direct s'est
#   eteint ; indexer l'ambiante sur le soleil donnait un ciel clair au-dessus
#   d'un terrain deja noir.

const SKY_SHADER := "res://assets/sky/atmosphere.gdshader"
const MOON_TEXTURE := "res://assets/sky/moon.png"

# Palette reprise de la direction artistique de terrain-3d.
const SUN_COLOR := Color(1.000, 0.945, 0.855)
const SUN_HORIZON := Color(1.0, 0.6, 0.35)
const AMBIENT_DAY := Color(0.545, 0.590, 0.665)
const AMBIENT_DUSK := Color(0.280, 0.200, 0.180)
const HORIZON := Color(0.700, 0.780, 0.855)
const NIGHT_AMBIENT := Color(0.135, 0.160, 0.235)
const NIGHT_FOG := Color(0.05, 0.07, 0.12)

const MAX_SUN_ENERGY := 1.35
# Azimut de l'arc solaire : oriente le lever et le coucher.
const AZIMUTH_DEG := 35.0

# Lune, grande planete, geante. La taille apparente vaut a peu pres
# `light_angular_distance / moon_dist` ; le plafond de 90 degres explique la
# distance courte de la troisieme.
const MOON_SIZES := [24.0, 46.0, 90.0]
const MOON_ENERGY := [0.55, 0.25, 0.25]
# Tableaux ORDINAIRES, convertis en Packed* au moment de les transmettre :
# `PackedFloat32Array(...)` n'est pas une expression constante en GDScript et
# ne peut donc pas etre un `const` (meme piege que dans terrain_textures.gd).
const MOON_DIST := [1400.0, 2600.0, 1000.0, 0.0]
# Decale la lecture de la texture : les trois astres partagent la meme image,
# et c'est ce decalage seul qui leur donne trois visages differents.
const MOON_UV_OFFSET := [0.62, 0.8, -0.435]

# Perspective aerienne : les plans lointains prennent la couleur du ciel. C'est
# ce reglage, plus que la distance de vue, qui donne sa profondeur au paysage
# de terrain-3d — et il vaut d'autant plus ici que le relief voxel se simplifie
# au loin avec le niveau de detail.
const FOG_DENSITY := 0.0016
const FOG_AERIAL := 0.85
const FOG_SUN_SCATTER := 0.30
const FOG_SKY_AFFECT := 0.8

# --- Sous terre ---
#
# L'ambiante de Godot est OMNIDIRECTIONNELLE et n'est occultee par rien. Une
# galerie a cinquante metres sous la roche recoit donc exactement la meme que
# la plage — teinte chaude du couchant comprise. C'est ce qu'on voyait dans les
# grottes, et ce n'est pas un bug d'eclairage : c'est la definition d'une
# lumiere ambiante sans occlusion.
#
# Le brouillard s'y ajoute, et pour la meme raison. `fog_aerial_perspective`
# prend la couleur du CIEL selon la direction du regard : sous terre, il repeint
# le fond du tunnel en bleu de plein jour.
#
# Le soleil, lui, n'est PAS attenue : la roche l'occulte deja par les ombres, et
# l'eteindre assombrirait la vue vers l'exterieur depuis une entree.
const CAVE_AMBIENT := Color(0.035, 0.038, 0.050)
const CAVE_FOG := Color(0.020, 0.020, 0.028)

# --- Sous l'eau ---
#
# Valeurs reprises de `world/underwater.gd` du projet terrain-3d, qui n'a pas
# de shader pour cela : l'effet y est un voile plein ecran teinte, double d'un
# brouillard dense. Le voile est pose par la scene ; ici on ne s'occupe que de
# l'environnement.
#
# Le brouillard passe a `fog_sky_affect = 1` : sous l'eau, le ciel doit etre
# noye comme le reste, sinon on apercoit un horizon clair a travers la masse
# d'eau.
const WATER_TINT := Color(0.06, 0.26, 0.40, 0.42)
const WATER_FOG := Color(0.04, 0.20, 0.30)
const WATER_AMBIENT := Color(0.10, 0.24, 0.30)
const WATER_FOG_DENSITY := 0.08

# 0 en surface, 1 des qu'on est franchement sous terre. Renseigne par la scene,
# qui seule connait la position du joueur.
var underground := 0.0
# 0 hors de l eau, 1 quand la camera est immergee. Meme origine : la scene.
var underwater := 0.0

# 0.0 = minuit, 0.25 = aube, 0.5 = midi, 0.75 = crepuscule.
var time_of_day := 0.30
var day_length_seconds := 900.0
var paused := false

var _sun: DirectionalLight3D
var _environment: Environment
var _sky_material: ShaderMaterial
var _moons: Array[DirectionalLight3D] = []


func setup(sun: DirectionalLight3D, environment: Environment) -> void:
	_sun = sun
	_environment = environment
	_sky_material = _build_sky_material()
	_create_moons()

	var sky := Sky.new()
	sky.sky_material = _sky_material
	_environment.background_mode = Environment.BG_SKY
	_environment.sky = sky
	# Ambiante par COULEUR : cf. l'entete. Le ciel sert au REFLET (l'eau en a
	# besoin), pas a l'eclairage ambiant.
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_environment.ambient_light_energy = 1.0
	_environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	_environment.fog_enabled = true
	_environment.fog_light_color = HORIZON
	_environment.fog_sun_scatter = FOG_SUN_SCATTER
	_environment.fog_density = FOG_DENSITY
	_environment.fog_aerial_perspective = FOG_AERIAL
	_environment.fog_sky_affect = FOG_SKY_AFFECT

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

	# Position du soleil sur son arc. A minuit il est sous l'horizon, a midi au
	# zenith ; l'azimut incline l'arc pour que le soleil ne passe pas par le
	# zenith exact, sans quoi les ombres disparaissent a midi.
	var angle := time_of_day * TAU - PI * 0.5
	var az := deg_to_rad(AZIMUTH_DEG)
	var ca := cos(angle)
	var sun_pos := Vector3(ca * cos(az), sin(angle), ca * sin(az))
	var up := Vector3.UP if absf(sun_pos.y) < 0.98 else Vector3(0.0, 0.0, 1.0)

	if _sun.is_inside_tree():
		_sun.look_at(_sun.global_position - sun_pos, up)
	# La lune est a l'OPPOSE du soleil : pleine et haute au milieu de la nuit.
	if _moons.size() > 0 and _moons[0].is_inside_tree():
		_moons[0].look_at(_moons[0].global_position + sun_pos, up)

	# Soleil DIRECT : s'eteint des que le disque passe sous l'horizon.
	var day := smoothstep(-0.08, 0.25, sun_pos.y)
	# Clarte du CIEL : s'etend plus bas sous l'horizon, parce que l'atmosphere
	# continue de diffuser apres le coucher. C'est elle qui pilote l'ambiante.
	var sky_light := smoothstep(-0.28, 0.15, sun_pos.y)

	_sun.light_energy = day * MAX_SUN_ENERGY
	var low := 1.0 - clampf(sun_pos.y * 2.5, 0.0, 1.0)
	_sun.light_color = SUN_COLOR.lerp(SUN_HORIZON, low * day)

	# La lune ne doit eclairer que la nuit. Sans cette modulation elle rasait le
	# monde au couchant, a pleine energie.
	if _moons.size() > 0:
		_moons[0].light_energy = MOON_ENERGY[0] * (1.0 - clampf(sky_light, 0.0, 1.0))

	# Ambiante : nuit bleutee -> jour. Puis une bosse chaude au crepuscule,
	# quand le ciel est encore clair mais le soleil direct deja eteint.
	var ambient := NIGHT_AMBIENT.lerp(AMBIENT_DAY, sky_light)
	ambient = ambient.lerp(AMBIENT_DUSK, sky_light * (1.0 - day) * 0.5)

	# Le brouillard suit le meme mouvement : le voile clair du jour flotterait
	# sur une scene nocturne sombre.
	var fog := NIGHT_FOG.lerp(HORIZON, sky_light)
	var density := lerpf(FOG_DENSITY * 0.5, FOG_DENSITY, sky_light)

	# Sous terre, on coupe tout ce que la roche ne peut pas occulter. Voir la
	# note en tete : ambiante et perspective aerienne traversent la pierre.
	var cave := clampf(underground, 0.0, 1.0)
	ambient = ambient.lerp(CAVE_AMBIENT, cave)
	fog = fog.lerp(CAVE_FOG, cave)
	density *= 1.0 - cave * 0.85
	var aerial := FOG_AERIAL * (1.0 - cave)
	var sky_affect := FOG_SKY_AFFECT * (1.0 - cave)

	# Sous l'eau, par-dessus tout le reste : c'est le milieu le plus proche de
	# l'oeil, donc c'est lui qui gagne.
	var water := clampf(underwater, 0.0, 1.0)
	if water > 0.0:
		ambient = ambient.lerp(WATER_AMBIENT, water)
		fog = fog.lerp(WATER_FOG, water)
		density = lerpf(density, WATER_FOG_DENSITY, water)
		aerial *= 1.0 - water
		sky_affect = lerpf(sky_affect, 1.0, water)

	_environment.ambient_light_color = ambient
	_environment.fog_light_color = fog
	_environment.fog_density = density
	_environment.fog_aerial_perspective = aerial
	_environment.fog_sky_affect = sky_affect


# Les trois astres. L'ordre de creation fixe leur indice LIGHT dans le shader.
func _create_moons() -> void:
	var texture := load(MOON_TEXTURE)
	_sky_material.set_shader_parameter("moon_textures", [texture, texture, texture])
	_sky_material.set_shader_parameter("moon_dist", PackedFloat32Array(MOON_DIST))
	_sky_material.set_shader_parameter("moon_uv_x_offset", PackedFloat32Array(MOON_UV_OFFSET))

	for i in 3:
		var moon := DirectionalLight3D.new()
		moon.name = "Moon%d" % (i + 1)
		moon.light_angular_distance = MOON_SIZES[i]
		moon.light_energy = MOON_ENERGY[i]
		# Seule la lune eclaire. Les deux planetes sont en SKY_ONLY : leur
		# energie ne fait que rendre leur disque visible, sans quoi on aurait
		# trois soleils.
		moon.sky_mode = (DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY if i == 0
			else DirectionalLight3D.SKY_MODE_SKY_ONLY)
		moon.shadow_enabled = false
		add_child(moon)
		_moons.append(moon)

	# Lumiere lunaire franchement froide : c'est ce qui fait lire la nuit comme
	# une nuit plutot que comme un jour sous-expose.
	_moons[0].light_color = Color(0.55, 0.66, 0.95)
	# Le speculaire de la lune sur la mer est le seul reflet que ce monde se
	# permette, mais bride : voir `grazing_roughness` dans sea.gdshader.
	_moons[0].light_specular = 0.25
	_moons[2].light_color = Color(0.62, 0.70, 0.86)
	# Orientations fixes, bien ecartees. Seule la lune suit le soleil.
	_moons[1].rotation_degrees = Vector3(-52.0, 55.0, 0.0)
	_moons[2].rotation_degrees = Vector3(-42.0, -120.0, 0.0)


# Les textures du ciel sont des bruits : les construire coute moins cher que de
# les versionner, et les reglages restent lisibles ici plutot que caches dans
# un .tres. Les valeurs sont celles de materials/sky_material.tres.
#
# La seule piece qui manque est le fond d'etoiles, une cubemap HDR de 48 Mo que
# je n'ai pas versionnee. L'uniforme est `hint_default_black` : sans elle le
# ciel de nuit est simplement depourvu d'etoiles, les astres restent la.
func _build_sky_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(SKY_SHADER)

	material.set_shader_parameter("atmosphere_sample_count", 24)
	material.set_shader_parameter("exposure", 13.0)
	material.set_shader_parameter("sundisc_intensity", 30.0)
	material.set_shader_parameter("stars_exposure", 3.0)

	# Nuages cumulus, en ray-marching.
	material.set_shader_parameter("coverage", 0.35)
	material.set_shader_parameter("cloud_smoothness", 0.05)
	material.set_shader_parameter("cloud_marches", 32)
	material.set_shader_parameter("density_coeff", 1.5)
	material.set_shader_parameter("light_strength", 25.0)
	material.set_shader_parameter("clouds_anisotropy_factor", 0.15)
	material.set_shader_parameter("cloud_base_color", Color(0.765, 0.789, 0.859))
	material.set_shader_parameter("cloud_overcast_color", Color(0.765, 0.788, 0.859))
	material.set_shader_parameter("cloud_color_texture", _noise_2d(0, 0.0))
	material.set_shader_parameter("cloud_noise_factor", 0.2)
	# `invert` sur la forme : le bruit cellulaire donne des cellules sombres
	# separees par des cretes claires, c'est l'inverse qu'on veut en nuage.
	material.set_shader_parameter("cloud_shape", _noise_3d(FastNoiseLite.TYPE_CELLULAR, 0.0231, true))
	material.set_shader_parameter("cloud_shape_size", 3.0)
	material.set_shader_parameter("cloud_noise", _noise_3d(FastNoiseLite.TYPE_SIMPLEX, 0.0285, false))
	material.set_shader_parameter("cloud_noise_size", 12.0)
	# Trou au zenith : sans lui la couche de nuages se referme juste au-dessus
	# du joueur et le ciel n'a plus de fond.
	material.set_shader_parameter("hole_in_center", true)
	material.set_shader_parameter("hole_radius", 5.0)
	material.set_shader_parameter("hole_feather", 10.0)

	# Cirrus : la couche haute, etiree par `cirrus_squish`.
	material.set_shader_parameter("use_cirrus", true)
	material.set_shader_parameter("cirrus_texture", _noise_2d(0, 0.3, 3))
	material.set_shader_parameter("cirrus_squish", Vector2(4.0, 1.0))
	material.set_shader_parameter("cirrus_scale", 0.2)
	material.set_shader_parameter("cirrus_treshold", 0.8)
	material.set_shader_parameter("cirrus_distortion_texture", _noise_2d(2, 0.3, 1))
	material.set_shader_parameter("cirrus_distortion_scale", 0.04)
	material.set_shader_parameter("cirrus_distortion_offset", Vector2(0.4, 0.0))
	material.set_shader_parameter("cirrus_mask_texture", _noise_2d(2, 0.3, 1))
	material.set_shader_parameter("cirrus_mask_scale", 0.05)
	material.set_shader_parameter("cirrus_opacity", 0.2)

	material.set_shader_parameter("moon_glow_boost", 1.7)
	return material


func _noise_2d(seed_value: int, skirt: float, octaves: int = 0) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	if octaves > 0:
		noise.fractal_octaves = octaves
	var texture := NoiseTexture2D.new()
	texture.seamless = true
	if skirt > 0.0:
		texture.seamless_blend_skirt = skirt
	texture.noise = noise
	return texture


func _noise_3d(type: int, frequency: float, invert: bool) -> NoiseTexture3D:
	var noise := FastNoiseLite.new()
	noise.noise_type = type
	noise.frequency = frequency
	var texture := NoiseTexture3D.new()
	texture.width = 128
	texture.height = 128
	texture.depth = 128
	texture.seamless = true
	texture.invert = invert
	texture.noise = noise
	return texture
