class_name Sea
extends Node3D

# La mer : un plan a hauteur du niveau marin, avec le shader d'eau de
# terrain-3d (voir sea.gdshader).
#
# Le plan est FIXE et volontairement simple. La version precedente suivait le
# joueur et portait 199 subdivisions parce que son shader deplacait les sommets
# pour faire des vagues, et qu'il fallait donc concentrer la resolution autour
# de la camera. Celui-ci ne touche pas aux sommets : les vaguelettes viennent
# de trois couches de normales qui defilent, la profondeur et l'ecume se
# lisent dans le tampon de profondeur, et la transparence vient de la
# refraction. Tout est donc par PIXEL, et deux triangles suffisent.

const SEA_SHADER := "res://scenes/voxel_world/sea.gdshader"

# Doit depasser la distance de vue, sinon on voit le bord du plan a l'horizon.
# A la densite de brouillard reglee dans SkyCycle, tout est deja fondu bien
# avant.
const EXTENT := 5000.0

var _mesh: MeshInstance3D
var _material: ShaderMaterial


# Marge, en voxels, au-dessus du niveau marin avant de declarer une colonne
# « terre ». Le plan de mer continue donc un peu SOUS la plage, ou il est de
# toute facon enfoui : sans cette marge, la decoupe tomberait pile sur la ligne
# d'eau et s'y verrait en trait net.
const LAND_MARGIN := 2


func setup(map: WorldMap) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(EXTENT, EXTENT)

	_material = build_material()
	_clip_to_water(map)

	_mesh = MeshInstance3D.new()
	_mesh.name = "Surface"
	_mesh.mesh = plane
	_mesh.material_override = _material
	# Une surface d'eau qui projette une ombre assombrirait tout le fond marin
	# sous elle, ce qui est faux et couteux.
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)

	# Legerement SOUS le niveau marin. Le shader est OPAQUE et ecrit dans le
	# tampon de profondeur (`depth_draw_always`) : nos plages sont plates et
	# pile a cette altitude, donc un plan exactement coplanaire avec elles se
	# battrait avec le terrain sur toute leur etendue. Le decalage suffit a
	# trancher, et l'ecume de rive masque la ligne de coupe.
	var centre := float(map.size_xz) * 0.5
	position = Vector3(centre, float(WorldMap.SEA_LEVEL) - 0.25, centre)


# Decoupe le plan de mer sur les terres emergees : voir `land_clip` dans le
# shader pour la raison, qui est une grotte percee d'une nappe d'eau.
#
# Le masque est construit en UN passage et pousse d'un bloc : `set_pixel` sur
# 640 000 colonnes couterait plusieurs secondes, la ou un `PackedByteArray`
# remis a `Image.create_from_data` se compte en fractions de seconde. C'est la
# meme lecon que `map_render.gd`.
func _clip_to_water(map: WorldMap) -> void:
	var size := map.size_xz
	var mask := PackedByteArray()
	mask.resize(size * size)
	var limit := WorldMap.SEA_LEVEL + LAND_MARGIN
	var i := 0
	for z in size:
		for x in size:
			mask[i] = 255 if map.terrain_height(x, z) > limit else 0
			i += 1

	var texture := ImageTexture.create_from_image(
		Image.create_from_data(size, size, false, Image.FORMAT_R8, mask))
	_material.set_shader_parameter("land_clip", 1.0)
	_material.set_shader_parameter("land_mask", texture)
	_material.set_shader_parameter("land_origin", Vector2.ZERO)
	_material.set_shader_parameter("land_extent", float(size))


# Valeurs reprises de `tools/water_bench.gd` et de la direction artistique de
# terrain-3d, ou elles ont ete reglees a la capture.
#
# STATIQUE, parce que les rivieres s'en servent aussi (voir
# `river_splines.gd`). Partager la matiere plutot que la recopier est ce qui
# garantit qu'un reglage d'eau vaut pour toute l'eau du monde : une mer et une
# riviere qui divergeraient au fil des retouches se verraient immediatement a
# une embouchure, ou les deux se touchent.
static func build_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(SEA_SHADER)

	material.set_shader_parameter("normalmap", _ripple_normal())
	material.set_shader_parameter("color_shallow", Color(0.235, 0.485, 0.545))
	material.set_shader_parameter("color_deep", Color(0.090, 0.235, 0.330))
	material.set_shader_parameter("foam_color", Color(0.880, 0.925, 0.940))
	# Profondeur (m) sous laquelle l'ecume apparait : c'est ce qui dessine le
	# liseré blanc le long des plages.
	material.set_shader_parameter("foam_depth", 1.8)
	# Profondeur de VISIBILITE, au sens de l'absorption de Beer-Lambert.
	material.set_shader_parameter("beer_depth", 9.0)
	# Profondeur a laquelle la teinte atteint `color_deep`.
	material.set_shader_parameter("depth_fade", 12.0)
	material.set_shader_parameter("refraction_strength", 0.035)
	material.set_shader_parameter("water_roughness", 0.34)
	return material


# Bruit de normales des vaguelettes : un reglage, pas une image, donc construit
# en code plutot que versionne.
static func _ripple_normal() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.03

	var texture := NoiseTexture2D.new()
	texture.width = 512
	texture.height = 512
	texture.seamless = true
	texture.as_normal_map = true
	texture.bump_strength = 3.0
	texture.noise = noise
	return texture
