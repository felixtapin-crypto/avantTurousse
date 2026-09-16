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
// Hauteurs (carte de deplacement d'ambientCG). Aucun sommet n'est deplace :
// elles servent uniquement a departager deux matieres qui se recouvrent.
uniform sampler2DArray u_height_array : hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;

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

// --- Detuilage ---
//
// Les textures d'ambientCG sont raccordables, donc sans couture visible. Mais
// « sans couture » n'est pas « sans repetition » : a 1,4 a 3,5 m de cote sur
// une ile de 600 m, la meme image revient des centaines de fois, et l'oeil
// repere la GRILLE bien avant de reperer un raccord.
//
// On la casse de deux facons, toutes deux en calcul pur — aucune lecture de
// texture de plus, alors qu'on en fait deja vingt-quatre par fragment :
//
// - une DEFORMATION du domaine : les coordonnees sont deplacees par un bruit
//   basse frequence avant projection. Les tuiles voisines se desynchronisent,
//   et la grille n'en est plus une. La deformation varie doucement, donc les
//   derivees d'ecran restent saines et le choix de mipmap avec elles — ce qui
//   n'est pas un detail vu d'ou l'on vient.
// - une variation MACRO de luminosite, a bien plus grande echelle. C'est elle
//   qui compte de loin : a distance on ne distingue plus le motif, on ne voit
//   plus que son rythme clair/sombre.
uniform float u_detile_meters = 23.0;
uniform float u_detile_strength = 1.8;
uniform float u_macro_meters = 46.0;
uniform float u_macro_strength : hint_range(0.0, 1.0) = 0.22;

// --- Melange par hauteur ---
//
// Un melange lineaire fond deux matieres comme deux photos en transparence.
// Celui-ci laisse percer la plus HAUTE : les galets sortent du sable, l'herbe
// pousse entre les pierres. La limite cesse d'etre une ligne et devient un
// engrenage.
//
// `u_height_influence` pese la hauteur face au poids du voxel. Il doit rester
// nettement SOUS 1 : sinon une matiere a poids nul mais a relief marque
// ressortirait la ou elle n'a rien a faire.
uniform float u_height_influence : hint_range(0.0, 1.0) = 0.35;
// Epaisseur de la zone ou deux matieres coexistent. Plus petit = bord plus
// net, jusqu'a cliqueter.
uniform float u_blend_depth : hint_range(0.01, 0.5) = 0.24;

// --- Pinceau ---
//
// Le melange par hauteur RESSERRE la limite : c'est sa raison d'etre, il
// remplace un fondu mou par un engrenage. Mais resserrer une limite deja
// courte redonne une coupure nette.
//
// On fait donc DIVAGUER les poids avant de le calculer. La frontiere cesse de
// suivre la ligne ou les poids s'egalisent — laquelle est lisse, et c'est
// precisement ce qui la fait lire comme une decoupe.
//
// TROIS octaves : le trait, la frange, le grain. Une seule donnait une limite
// ondulante mais toujours CONTINUE, qu'on lisait encore comme un trace ; ce
// sont les octaves fines qui la font se defaire en plaques.
//
// Le bruit est CENTRE sur zero : il deplace la limite sans favoriser aucune
// matiere. Il ne peut pas non plus faire surgir une matiere au milieu d'une
// zone pure, pour deux raisons qui se completent : `present` masque les
// emplacements a poids nul, et une matiere absente du noyau de generation
// n'occupe meme pas d'emplacement.
//
// C'est ce dernier point qui LIMITE le fondu, et c'est pourquoi la portee du
// noyau (voir TerrainGenerator.BLEND_KERNEL) et la force du pinceau se reglent
// ensemble : monter l'une sans l'autre ne donne rien.
uniform float u_brush_meters = 9.0;
uniform float u_brush_strength : hint_range(0.0, 1.0) = 0.60;

varying vec3 v_world_pos;
// `flat` est indispensable, pas une optimisation.
//
// Ce sont des INDICES entiers. Interpoles, ils prennent des valeurs
// intermediaires, et `int()` bascule alors d'un pixel a l'autre entre deux
// couches voisines. Chaque couche ayant sa propre echelle en metres, la
// coordonnee de texture change brutalement d'un pixel au suivant : le
// materiel calcule des derivees aberrantes, choisit un niveau de mipmap au
// hasard, et le terrain se couvre d'un moucheton — d'autant plus dense que
// les matieres se melangent, donc sur tout le littoral.
//
// C'est la cause qu'on a successivement attribuee a l'aliasing, aux ombres,
// au plan d'eau et au z-fighting.
varying flat vec4 v_material_indices;
varying vec4 v_material_weights;


void vertex() {
	VERTEX = get_transvoxel_position(VERTEX, CUSTOM0);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Les indices sont des entiers, on les decode tels quels ; les poids
	// doivent revenir dans [0..1].
	v_material_indices = decode_8bit_vec4(CUSTOM1.x);
	v_material_weights = decode_8bit_vec4(CUSTOM1.y) / 255.0;
}


// Bruit de valeur, interpole en douceur. Il est calcule plutot que lu dans une
// texture : quelques operations coutent moins qu'une lecture de plus, et
// surtout il reste continu et derivable, ce a quoi tient tout le detuilage.
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	// Lissage cubique : sans lui les cellules du bruit se voient autant que la
	// grille qu'on cherche a effacer.
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x),
		u.y);
}

// Deplace un couple de coordonnees planaires, en metres.
vec2 detile(vec2 p) {
	vec2 q = p / u_detile_meters;
	return p + vec2(value_noise(q), value_noise(q + 31.7)) * u_detile_strength;
}

// Projection triplanaire sur des coordonnees DEJA deformees, une par plan. La
// version de l'addon prend une position 3D unique ; il nous faut les trois
// plans separement, la deformation n'etant pas la meme sur chacun.
vec4 array_triplanar(sampler2DArray tex, vec2 pyz, vec2 pxz, vec2 pxy,
		float meters, vec3 blend, float layer) {
	return texture(tex, vec3(pyz / meters, layer)) * blend.x
		+ texture(tex, vec3(pxz / meters, layer)) * blend.y
		+ texture(tex, vec3(pxy / meters, layer)) * blend.z;
}

// Repartition entre les quatre matieres, en tenant compte de leur relief.
//
// La hauteur est ATTENUEE avant d'etre ajoutee au poids (cf.
// u_height_influence) : c'est ce qui garantit qu'une matiere a poids nul ne
// puisse jamais franchir le seuil, quel que soit son relief.
vec4 height_blend(vec4 heights, vec4 weights) {
	vec4 h = heights * u_height_influence + weights;
	float top = max(max(h.x, h.y), max(h.z, h.w)) - u_blend_depth;
	vec4 b = max(h - top, 0.0);
	return b / max(b.x + b.y + b.z + b.w, 0.0001);
}

// Normale triplanaire par melange "whiteout". Un terrain lisse n'a pas de
// tangentes exploitables, donc on ne peut pas passer par NORMAL_MAP : on
// reconstruit la normale en espace monde a partir des trois projections, puis
// on la ramene en espace vue, seul espace ou Godot lit NORMAL.
vec3 triplanar_normal(sampler2DArray tex, vec2 pyz, vec2 pxz, vec2 pxy,
		float meters, vec3 wnormal, vec3 blend, float layer) {
	vec3 nx = texture(tex, vec3(pyz / meters, layer)).xyz * 2.0 - 1.0;
	vec3 ny = texture(tex, vec3(pxz / meters, layer)).xyz * 2.0 - 1.0;
	vec3 nz = texture(tex, vec3(pxy / meters, layer)).xyz * 2.0 - 1.0;

	nx = vec3(nx.xy + wnormal.zy, abs(nx.z) * wnormal.x);
	ny = vec3(ny.xy + wnormal.xz, abs(ny.z) * wnormal.y);
	nz = vec3(nz.xy + wnormal.xy, abs(nz.z) * wnormal.z);

	return nx.zyx * blend.x + ny.xzy * blend.y + nz.xyz * blend.z;
}


void fragment() {
	vec3 wnormal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 blending = get_triplanar_blend(wnormal, u_blend_sharpness);

	// Certains sommets ressortent du mailleur avec QUATRE poids nuls. Diviser
	// par une epsilon donnait alors quatre poids nuls, la boucle ne
	// selectionnait aucune couche, l'albedo restait noir et le pixel ne
	// montrait plus que l'ambiante bleue du ciel — le moucheton qu'on
	// attribuait tour a tour a l'aliasing, aux ombres et au z-fighting.
	// On retombe sur la premiere couche plutot que sur du vide.
	vec4 weights = v_material_weights;
	float weight_sum = weights.x + weights.y + weights.z + weights.w;
	if (weight_sum < 0.001) {
		weights = vec4(1.0, 0.0, 0.0, 0.0);
		weight_sum = 1.0;
	}
	weights /= weight_sum;

	// Deformation calculee UNE fois : elle ne depend que de la position dans le
	// monde, pas de la matiere. Six evaluations de bruit par fragment, la ou
	// les faire dans la boucle en couterait vingt-quatre.
	vec2 pyz = detile(v_world_pos.yz);
	vec2 pxz = detile(v_world_pos.xz);
	vec2 pxy = detile(v_world_pos.xy);

	// Premiere passe : les quatre HAUTEURS. Elle est separee parce que la
	// repartition ne peut etre calculee qu'une fois les quatre connues — on ne
	// sait pas qui perce qui avant de les avoir toutes.
	int layers[4];
	float meters[4];
	vec4 heights = vec4(0.0);
	for (int i = 0; i < 4; i++) {
		int layer = clamp(int(v_material_indices[i]), 0, 7);
		layers[i] = layer;
		meters[i] = max(u_layer_meters[layer] * u_scale, 0.05);
		heights[i] = array_triplanar(u_height_array, pyz, pxz, pxy,
			meters[i], blending, float(layer)).r;
	}
	// Le pinceau : une limite de biome est une courbe AU SOL, donc c'est sur le
	// plan horizontal qu'il faut la perturber, et en coordonnees monde pour
	// qu'elle ne bouge pas avec la camera.
	vec2 bp = v_world_pos.xz / u_brush_meters;
	vec4 brush = vec4(
		value_noise(bp),
		value_noise(bp + 17.1),
		value_noise(bp + 41.7),
		value_noise(bp + 73.3));
	vec4 fringe = vec4(
		value_noise(bp * 2.9 + 5.3),
		value_noise(bp * 2.9 + 23.9),
		value_noise(bp * 2.9 + 51.1),
		value_noise(bp * 2.9 + 89.7));
	vec4 grain = vec4(
		value_noise(bp * 7.3 + 3.1),
		value_noise(bp * 7.3 + 29.7),
		value_noise(bp * 7.3 + 63.5),
		value_noise(bp * 7.3 + 97.3));
	// Masque des emplacements REELLEMENT occupes. Indispensable : les
	// emplacements inutilises portent l'indice 0 — donc l'herbe — avec un poids
	// nul, et le bruit du pinceau, qui est centre sur zero, suffirait a les
	// faire franchir le seuil. On verrait de l'herbe apparaitre entre deux
	// matieres qui n'en contiennent pas.
	vec4 present = step(0.001, weights);
	vec4 brushed = max(weights + (mix(mix(brush, fringe, 0.4), grain, 0.22) - 0.5) * u_brush_strength, 0.0) * present;

	vec4 mix_weights = height_blend(heights, brushed);

	vec3 albedo = vec3(0.0);
	vec3 normal = vec3(0.0);
	float roughness = 0.0;

	// Les QUATRE couches sont echantillonnees, sans condition, meme a poids
	// nul. Ce n'est pas un oubli d'optimisation : sauter les couches inutiles
	// mettait les appels a `texture()` dans un branchement DIVERGENT entre
	// pixels voisins. Or le materiel calcule le niveau de mipmap a partir des
	// derivees d'ecran, et celles-ci sont indefinies des qu'un pixel prend une
	// branche et son voisin l'autre : le mip est alors tire au hasard, pixel
	// par pixel, et le terrain se couvre d'un moucheton qu'on attribue
	// volontiers a l'aliasing, aux ombres ou au z-fighting.
	//
	// Si le cout des vingt-quatre lectures devenait genant, la sortie n'est
	// pas de rebrancher : c'est `textureGrad`, avec des derivees calculees en
	// dehors de toute condition.
	for (int i = 0; i < 4; i++) {
		// Poids issu du melange par hauteur, et non plus le poids brut du
		// voxel : c'est lui qui fait l'engrenage entre deux matieres.
		float weight = mix_weights[i];
		// L'indice a deja ete borne en premiere passe : les emplacements de
		// poids negligeable contiennent n'importe quoi, et un acces hors des
		// huit couches est un comportement indefini.
		int layer = layers[i];

		albedo += array_triplanar(u_albedo_array, pyz, pxz, pxy,
			meters[i], blending, float(layer)).rgb * weight;
		normal += triplanar_normal(u_normal_array, pyz, pxz, pxy,
			meters[i], wnormal, blending, float(layer)) * weight;
		roughness += u_layer_roughness[layer] * weight;
	}

	// Variation macro : deux echelles bien separees, pour que la modulation ne
	// soit pas elle-meme un damier. Moyenne centree sur 1, donc la matiere
	// garde sa luminosite d'ensemble.
	float macro = mix(
		value_noise(v_world_pos.xz / u_macro_meters),
		value_noise(v_world_pos.xz / (u_macro_meters * 0.31) + 11.3),
		0.4);
	albedo *= 1.0 + (macro - 0.5) * 2.0 * u_macro_strength;

	ALBEDO = albedo;
	ROUGHNESS = roughness;
	METALLIC = 0.0;

	// Si aucune couche n'a franchi le seuil de poids, la normale accumulee est
	// nulle et la normaliser donnerait un NaN, donc un pixel noir. On retombe
	// alors sur la normale geometrique.
	vec3 mapped = length(normal) > 0.001 ? normalize(normal) : wnormal;
	vec3 shaped = normalize(mix(wnormal, mapped, u_normal_strength));
	NORMAL = normalize((VIEW_MATRIX * vec4(shaped, 0.0)).xyz);
}
