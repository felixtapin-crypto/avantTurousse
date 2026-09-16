shader_type spatial;

// Shader du terrain lisse (Transvoxel), adapte de la demo
// `smooth_materials` de Zylann/voxelgame (MIT, Marc Gilleron).
//
// Trois choses s'y passent, et aucune n'est optionnelle :
//
// - `get_transvoxel_position` applique le morphing de sommets entre niveaux
//   de detail. Sans lui, les coutures entre deux LOD sautent a l'oeil.
// - CUSTOM1 transporte les matieres : .x contient 4 indices de couche et .y
//   4 poids, encodes par le mailleur. On les decode en vec4.
// - la projection est triplanaire, parce qu'une surface d'isovaleur n'a pas
//   de coordonnees de texture : on projette depuis les trois axes et on
//   melange selon la normale. Les textures doivent donc etre RACCORDABLES,
//   sans quoi les jointures se voient partout.

#include "res://addons/zylann.voxel/shaders/transvoxel.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/triplanar.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/voxel_texturing.gdshaderinc"

uniform sampler2DArray u_albedo_array : source_color, filter_linear_mipmap, repeat_enable;
// Taille du motif, en metres. Plus la valeur est basse, plus la texture est
// etiree ; plus elle est haute, plus le carrelage se repete visiblement.
uniform float u_texture_scale = 0.15;
uniform float u_roughness : hint_range(0.0, 1.0) = 1.0;
// Attenue le contraste de la texture pour rester proche des aplats KayKit.
uniform float u_tint_strength : hint_range(0.0, 1.0) = 1.0;

varying vec3 v_world_pos;
varying vec4 v_material_indices;
varying vec4 v_material_weights;


void vertex() {
	VERTEX = get_transvoxel_position(VERTEX, CUSTOM0);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Les indices sont des entiers, on les decode tels quels ; les poids
	// doivent revenir dans [0..1].
	v_material_indices = decode_8bit_vec4(CUSTOM1.x);
	v_material_weights = decode_8bit_vec4(CUSTOM1.y) / 255.0;
}


void fragment() {
	vec3 normal = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	vec3 wpos = v_world_pos * u_texture_scale;

	// Les facteurs de melange triplanaire sont les memes pour les 4 couches,
	// donc calcules une seule fois.
	vec3 blending = get_triplanar_blend(normal, 1.0);
	vec3 col0 = texture_array_triplanar(u_albedo_array, wpos, blending, v_material_indices.x).rgb;
	vec3 col1 = texture_array_triplanar(u_albedo_array, wpos, blending, v_material_indices.y).rgb;
	vec3 col2 = texture_array_triplanar(u_albedo_array, wpos, blending, v_material_indices.z).rgb;
	vec3 col3 = texture_array_triplanar(u_albedo_array, wpos, blending, v_material_indices.w).rgb;

	vec4 weights = v_material_weights;
	weights /= (weights.x + weights.y + weights.z + weights.w + 0.00001);

	vec3 col =
		col0 * weights.r +
		col1 * weights.g +
		col2 * weights.b +
		col3 * weights.a;

	ALBEDO = mix(vec3(dot(col, vec3(0.333))), col, u_tint_strength);
	ROUGHNESS = u_roughness;
	METALLIC = 0.0;
}
