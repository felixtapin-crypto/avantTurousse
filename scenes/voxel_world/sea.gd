class_name Sea
extends Node3D

# La mer : un plan a hauteur du niveau marin, avec le shader d'eau.
#
# Le plan SUIT le joueur au lieu de couvrir toute la carte d'un bloc. La
# raison est la resolution : le shader deplace les sommets pour faire des
# vagues, mais seulement dans les 85 premiers metres autour du joueur. Un plan
# fixe de 600 m devrait etre subdivise a l'extreme pour que ces 85 metres-la
# aient assez de sommets ; un plan qui suit concentre sa subdivision la ou
# elle sert.
#
# Il est cale sur la grille de ses propres quads : sans ca, les sommets
# glissent sous les vagues a chaque pas et la surface fremit.

const SEA_SHADER := "res://scenes/voxel_world/sea.gdshader"

# Doit depasser la distance de vue, sinon on voit le bord du plan a l'horizon.
const EXTENT := 1000.0
const SUBDIVISIONS := 199

var _mesh: MeshInstance3D
var _material: ShaderMaterial
var _quad_size: float
var _follow: Node3D


func setup(follow: Node3D, sea_level: float) -> void:
	_follow = follow
	_quad_size = EXTENT / float(SUBDIVISIONS + 1)

	var plane := PlaneMesh.new()
	plane.size = Vector2(EXTENT, EXTENT)
	plane.subdivide_width = SUBDIVISIONS
	plane.subdivide_depth = SUBDIVISIONS

	_material = _build_material()

	_mesh = MeshInstance3D.new()
	_mesh.name = "Surface"
	_mesh.mesh = plane
	_mesh.material_override = _material
	# Une surface d'eau qui projette une ombre assombrirait tout le fond marin
	# sous elle, ce qui est faux et couteux.
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Le plan deborde largement du champ de vision : le laisser se faire
	# eliminer par sa boite englobante le ferait disparaitre quand son centre
	# sort de l'ecran.
	_mesh.extra_cull_margin = EXTENT
	add_child(_mesh)

	# Legerement SOUS le niveau marin : nos plages sont plates et pile a cette
	# altitude, donc un plan exactement coplanaire avec elles se battrait avec
	# le terrain sur toute leur etendue.
	position.y = sea_level - 0.25
	_snap_to_player()


func _process(_delta: float) -> void:
	if _follow == null:
		return
	_snap_to_player()


func _snap_to_player() -> void:
	var target := _follow.global_position
	# Calage sur la grille des quads : le motif des vagues est calcule en
	# coordonnees MONDE, donc un plan qui glisse continument ferait defiler ses
	# sommets sous un motif immobile.
	_mesh.global_position = Vector3(
		snappedf(target.x, _quad_size),
		global_position.y,
		snappedf(target.z, _quad_size))
	# Le shader attenue la hauteur des vagues avec la distance au joueur.
	_material.set_shader_parameter("ocean_pos", target)


func _build_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(SEA_SHADER)

	material.set_shader_parameter("wave", _wave_height())
	material.set_shader_parameter("wave_bump", _wave_normal())
	material.set_shader_parameter("texture_normal", _ripple_normal())
	material.set_shader_parameter("texture_normal2", _swell_normal())

	material.set_shader_parameter("albedo", Color(0.0, 0.32, 0.43))
	material.set_shader_parameter("albedo2", Color(0.0, 0.47, 0.76))
	material.set_shader_parameter("color_shallow", Color(0.0, 0.47, 0.76))
	material.set_shader_parameter("color_deep", Color(0.06, 0.20, 0.28))
	material.set_shader_parameter("edge_color", Color(1.0, 1.0, 1.0))

	material.set_shader_parameter("metallic", 0.0)
	material.set_shader_parameter("roughness", 0.02)
	material.set_shader_parameter("wave_direction", Vector2(0.5, -0.2))
	material.set_shader_parameter("wave_direction2", Vector2(-0.5, 0.5))
	material.set_shader_parameter("time_scale", 0.08)
	material.set_shader_parameter("noise_scale", 20.0)
	# Vagues volontairement basses : a 5 m par quad, une houle d'un metre se
	# verrait facettee. L'essentiel du relief vient des normales.
	material.set_shader_parameter("height_scale", 0.55)
	material.set_shader_parameter("beers_law", 1.1)
	material.set_shader_parameter("depth_offset", -0.6)
	# Largeur de l'ecume au rivage, en unites de profondeur.
	material.set_shader_parameter("edge_scale", 0.18)
	material.set_shader_parameter("near", 1.0)
	material.set_shader_parameter("far", 400.0)
	material.set_shader_parameter("shore_fade", 4.0)
	return material


# Les quatre bruits sont ceux du projet d'origine, reconstruits en code plutot
# que versionnes : ce sont des reglages, pas des images.

func _wave_height() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_VALUE_CUBIC
	noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	noise.fractal_gain = 0.34
	noise.fractal_weighted_strength = 0.6
	return _texture(noise, false, 0.0)


func _wave_normal() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_VALUE_CUBIC
	noise.fractal_gain = 0.34
	noise.fractal_weighted_strength = 0.6
	return _texture(noise, true, 1.0)


func _ripple_normal() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 0.032
	return _texture(noise, true, 1.6)


func _swell_normal() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.seed = 22
	noise.frequency = 0.003
	noise.fractal_lacunarity = 1.6
	noise.fractal_gain = 0.47
	noise.fractal_weighted_strength = 0.53
	var texture := _texture(noise, true, 21.8)
	texture.seamless_blend_skirt = 0.532
	return texture


func _texture(noise: FastNoiseLite, as_normal: bool, bump: float) -> NoiseTexture2D:
	var texture := NoiseTexture2D.new()
	texture.noise = noise
	texture.seamless = true
	texture.as_normal_map = as_normal
	if as_normal:
		texture.bump_strength = bump
	return texture
