shader_type spatial;

// Shader du terrain lisse (Transvoxel), adapte de la demo `smooth_materials`
// de Zylann/voxelgame (MIT, Marc Gilleron).
//
// godot_voxel ne texture rien tout seul : le mailleur se contente de
// transporter les matieres dans les attributs de sommet, et c'est a ce shader
// de les decoder puis de les projeter — un terrain lisse n'ayant aucune
// coordonnee de texture exploitable.
//
// Trois mecanismes, dont aucun n'est optionnel :
//
// - `get_transvoxel_position` applique le morphing de sommets entre niveaux
//   de detail. Sans lui, les coutures entre deux LOD sautent a l'oeil.
// - CUSTOM1 transporte les matieres : .x contient 4 indices de couche et .y
//   4 poids, encodes par le mailleur en mode MIXEL4_S4.
// - la projection est triplanaire : on projette depuis les trois axes et on
//   melange selon la normale. Les textures doivent donc etre RACCORDABLES.

#include "res://addons/zylann.voxel/shaders/transvoxel.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/triplanar.gdshaderinc"
#include "res://addons/zylann.voxel/shaders/voxel_texturing.gdshaderinc"

uniform sampler2DArray u_albedo_array : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray u_normal_array : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

// Etendue reelle couverte par chaque matiere, en metres. Une seule valeur
// globale ne suffirait pas : les textures vont de 1,4 m a 3,5 m de cote, et a
// repetition constante les plus larges paraitraient deux fois et demie trop
// grosses (voir TerrainTextures.METERS).
uniform float u_layer_meters[8];
uniform float u_layer_roughness[8];
// Multiplicateur global, pour regler le grain d'ensemble sans toucher aux
// huit valeurs.
uniform float u_scale = 1.0;
uniform float u_normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float u_blend_sharpness : hint_range(1.0, 8.0) = 3.0;

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


// Normale triplanaire par melange "whiteout". Un terrain lisse n'a pas de
// tangentes exploitables, donc on ne peut pas passer par NORMAL_MAP : on
// reconstruit la normale en espace monde a partir des trois projections, puis
// on la ramene en espace vue, seul espace ou Godot lit NORMAL.
vec3 triplanar_normal(sampler2DArray tex, vec3 wpos, vec3 wnormal, vec3 blend, float layer) {
	vec3 nx = texture(tex, vec3(wpos.yz, layer)).xyz * 2.0 - 1.0;
	vec3 ny = texture(tex, vec3(wpos.xz, layer)).xyz * 2.0 - 1.0;
	vec3 nz = texture(tex, vec3(wpos.xy, layer)).xyz * 2.0 - 1.0;

	nx = vec3(nx.xy + wnormal.zy, abs(nx.z) * wnormal.x);
	ny = vec3(ny.xy + wnormal.xz, abs(ny.z) * wnormal.y);
	nz = vec3(nz.xy + wnormal.xy, abs(nz.z) * wnormal.z);

	return nx.zyx * blend.x + ny.xzy * blend.y + nz.xyz * blend.z;
}


void fragment() {
	vec3 wnormal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 blending = get_triplanar_blend(wnormal, u_blend_sharpness);

	vec4 weights = v_material_weights;
	weights /= (weights.x + weights.y + weights.z + weights.w + 0.00001);

	vec3 albedo = vec3(0.0);
	vec3 normal = vec3(0.0);
	float roughness = 0.0;

	// Quatre matieres melangeables par sommet, mais le generateur n'en ecrit
	// qu'une seule a plein poids sauf aux frontieres de biome. Sauter les
	// couches de poids nul evite donc, la plupart du temps, dix-huit lectures
	// de texture sur les vingt-quatre possibles.
	for (int i = 0; i < 4; i++) {
		float weight = weights[i];
		if (weight < 0.002) {
			continue;
		}
		int layer = int(v_material_indices[i]);
		vec3 wpos = v_world_pos / (u_layer_meters[layer] * u_scale);

		albedo += texture_array_triplanar(u_albedo_array, wpos, blending, float(layer)).rgb * weight;
		normal += triplanar_normal(u_normal_array, wpos, wnormal, blending, float(layer)) * weight;
		roughness += u_layer_roughness[layer] * weight;
	}

	ALBEDO = albedo;
	ROUGHNESS = roughness;
	METALLIC = 0.0;

	vec3 shaped = normalize(mix(wnormal, normalize(normal), u_normal_strength));
	NORMAL = normalize((VIEW_MATRIX * vec4(shaped, 0.0)).xyz);
}
