// Repris tel quel de `shaders/water.gdshader` du projet terrain-3d de
// Guillaume, qui en est l'auteur. Il remplace le shader d'`Infinite Ocean`
// utilise jusqu'ici : celui-ci tire sa transparence de la REFRACTION et non
// d'un alpha, ce qui supprime le raccord pale et laiteux qu'on avait au
// rivage, et son `grazing_roughness` empeche la mer de renvoyer le disque
// lunaire en tache cramee.
//
// Il ne deplace aucun sommet : voir `sea.gd`, dont le plan s'en trouve
// beaucoup plus simple.
//
// Eau réaliste pour un grand plan (Terrain3D ne fournit pas d'eau).
// - Couleur par profondeur (peu profond -> profond) via DEPTH_TEXTURE.
// - Normales animées (2 couches de normalmap qui défilent) -> vaguelettes.
// - Écume aux rives (là où l'eau est peu profonde au-dessus du terrain).
// - Réflexion du ciel : roughness faible + fresnel (Godot reflète l'environnement).
// - Transparence croissante avec la profondeur.
shader_type spatial;
// cull_disabled : la surface reste visible VUE DE DESSOUS (sinon l'eau disparaît quand on
// passe sous la mer). L'effet "sous l'eau" (teinte + brouillard) est géré par world/underwater.gd.
render_mode blend_mix, depth_draw_always, cull_disabled, specular_schlick_ggx;

uniform vec3 color_shallow : source_color = vec3(0.10, 0.38, 0.44);
uniform vec3 color_deep : source_color = vec3(0.02, 0.11, 0.19);
uniform float depth_fade = 6.0;        // profondeur (m) pour atteindre color_deep (teinte)
uniform float beer_depth = 8.0;        // profondeur (m) de VISIBILITÉ (absorption Beer-Lambert)

uniform sampler2D normalmap : hint_normal;
uniform float uv_scale = 0.05;
uniform vec2 flow_a = vec2(0.020, 0.014);
uniform vec2 flow_b = vec2(-0.016, 0.021);
uniform float normal_strength = 0.5;
// Rugosité un peu élevée : sinon l'eau quasi-miroir reflète le disque lunaire/solaire HDR
// comme une énorme traînée blanche cramée. Ici -> scintillement doux, reflet du ciel diffus.
uniform float water_roughness : hint_range(0.0, 1.0) = 0.30;

// Rugosité aux angles RASANTS, c'est-à-dire au loin vers l'horizon. Elle sert à raviver les reflets
// de ciel et de soleil, qui sont ce qui donne sa vie à une mer vue de loin.
//
// ⚠ ELLE ÉTAIT À 0.06, SOIT UN QUASI-MIROIR, et la lune y laissait une tache CRAMÉE. En PBR le
// spéculaire vient aussi de la radiance de l'environnement : l'eau reflétait le DISQUE lunaire que
// `atmosphere.gdshader` dessine dans le ciel — et celui-ci est délibérément surbrillé
// (`moon_glow_boost = 1.7`, « disque plus lumineux (rayonne) »). À 0.06 ce disque se reflétait
// quasi intact, franchissait `glow_hdr_threshold` et bloomait en blob blanc avec sa traînée.
//
// ⚠ ET `light_specular` SUR LA LUNE N'Y CHANGE RIEN : il ne borne que le spéculaire de la LUMIÈRE,
// pas le reflet de l'environnement. C'est le test de l'utilisateur qui l'a établi — désactiver
// l'astre dans les réglages faisait disparaître le reflet, or cela met son énergie à 0, ce qui le
// retire aussi DU CIEL (`SKY_MODE_LIGHT_AND_SKY`). Le coupable était donc le ciel, pas la lampe.
//
// 0.18 garde le raffermissement à l'horizon — la mer reste plus nette au loin qu'à ses pieds — mais
// étale le disque lunaire en sentier au lieu d'un point. Une vraie mer n'est de toute façon jamais
// un miroir à distance : la houle s'en charge.
uniform float grazing_roughness : hint_range(0.0, 0.5) = 0.18;

uniform vec3 foam_color : source_color = vec3(0.90, 0.95, 1.0);
uniform float foam_depth = 1.3;        // épaisseur d'eau sous laquelle apparaît l'écume
uniform float fresnel_power = 5.0;

// --- Decoupe sur les terres emergees ---------------------------------------
//
// LE PLAN DE MER NE DOIT PAS EXISTER SOUS L'ILE.
//
// Il est pose a une seule altitude et s'etend bien au-dela de la carte, donc il
// traverse tout ce que l'ile a de creux sous le niveau marin — et l'ile en a :
// mesure sur une carte de 800, TREIZE SALLES DE GROTTE SUR VINGT-SIX etaient
// coupees par ce plan, et 722 colonnes de terre ferme portaient une galerie qui
// l'enjambe. On voyait donc une nappe d'eau au fond d'une grotte seche.
//
// Le masquer quand la camera est sous terre aurait cache le symptome ; le
// supprimer la ou il n'a rien a faire supprime la cause. Le masque vaut 1 sur
// les terres, et on y jette le fragment.
//
// `land_clip` reste a zero pour toute autre eau qui reutiliserait ce shader —
// une riviere, elle, coule PAR DEFINITION sur les terres.
uniform float land_clip = 0.0;
uniform sampler2D land_mask : filter_linear;
uniform vec2 land_origin = vec2(0.0);
uniform float land_extent = 1.0;

uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;
// Réfraction : la scène rendue DERRIÈRE l'eau (on l'échantillonne avec des UV décalés par la normale).
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float refraction_strength : hint_range(0.0, 0.15) = 0.04;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Hors de l'eau : voir `land_clip`. En premier, pour ne rien calculer d'un
	// fragment qu'on jette.
	if (land_clip > 0.5) {
		vec2 land_uv = (world_pos.xz - land_origin) / land_extent;
		if (land_uv.x >= 0.0 && land_uv.x <= 1.0 && land_uv.y >= 0.0 && land_uv.y <= 1.0
				&& texture(land_mask, land_uv).r > 0.5) {
			discard;
		}
	}

	// --- Normales animées (3 couches, dont une FINE pour casser le reflet des astres en
	//     scintillement/glitter au lieu d'une traînée blanche continue) ---
	vec2 uv = world_pos.xz * uv_scale;
	vec3 na = texture(normalmap, uv + TIME * flow_a).xyz * 2.0 - 1.0;
	vec3 nb = texture(normalmap, uv * 1.37 + TIME * flow_b).xyz * 2.0 - 1.0;
	vec3 nc = texture(normalmap, uv * 4.3 - TIME * flow_a * 2.1).xyz * 2.0 - 1.0;  // fine
	vec3 n = normalize(na + nb + nc * 0.5);
	NORMAL_MAP = n * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = normal_strength;

	// --- Profondeur d'eau (distance surface -> fond opaque) ---
	float raw = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw);
	vec4 vpos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vpos.xyz /= vpos.w;
	float scene_z = -vpos.z;      // distance vue du fond
	float surf_z = -VERTEX.z;     // distance vue de la surface d'eau
	float water_depth = max(scene_z - surf_z, 0.0);

	// --- Réfraction : scène DERRIÈRE l'eau, UV décalés par la normale des vaguelettes ---
	vec2 refr_uv = clamp(SCREEN_UV + n.xy * refraction_strength, vec2(0.002), vec2(0.998));
	// Guard anti-halo : si le point réfracté est DEVANT la surface d'eau, on annule le décalage.
	float rraw = texture(depth_tex, refr_uv).r;
	vec4 rpos = INV_PROJECTION_MATRIX * vec4(vec3(refr_uv * 2.0 - 1.0, rraw), 1.0);
	rpos.xyz /= rpos.w;
	if (-rpos.z < surf_z) {
		refr_uv = SCREEN_UV;
	}
	vec3 behind = texture(screen_tex, refr_uv).rgb;

	// --- Transparence physique : absorption Beer-Lambert. Le fond réfracté fond vers la teinte d'eau
	//     (peu profond -> profond) avec la profondeur : limpide en surface, teinte d'eau au fond. ---
	float transmit = exp(-water_depth / max(beer_depth, 0.1));
	vec3 water_tint = mix(color_shallow, color_deep, clamp(water_depth / depth_fade, 0.0, 1.0));
	vec3 col = mix(water_tint, behind, transmit);

	// --- Écume aux rives ---
	float foam = 1.0 - smoothstep(0.0, foam_depth, water_depth);
	foam *= 0.6 + 0.4 * (na.x + nb.y);   // un peu de variation via les normales
	col = mix(col, foam_color, clamp(foam, 0.0, 1.0) * 0.85);

	// --- Fresnel (bords plus réfléchissants) ---
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), fresnel_power);

	ALBEDO = col;
	METALLIC = 0.0;
	ROUGHNESS = mix(water_roughness, grazing_roughness, fres);   // + net aux angles rasants
	SPECULAR = 0.5;
	// OPAQUE : le "voir à travers" vient de la RÉFRACTION (screen_tex), plus de l'alpha. Au bord très
	// peu profond, transmit->1 et col->fond -> raccord doux avec le sable (pas de ligne dure).
	ALPHA = 1.0;
}
