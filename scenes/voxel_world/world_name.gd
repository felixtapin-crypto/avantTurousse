class_name WorldName
extends RefCounted

# Nom et portrait d'un monde.
#
# Une graine est un bon identifiant et un mauvais SOUVENIR : « 418372 » ne dit
# rien de l'ile qu'on a explorée hier. Le menu doit pouvoir presenter un monde
# comme une destination, pas comme une reference de fichier.
#
# Le nom est DERIVE de la graine, donc stable sans rien stocker : la meme
# graine donne toujours la meme ile et toujours le meme nom.

const FORMS := [
	"L'ile", "La terre", "Le cap", "La baie", "La pointe",
	"La presqu'ile", "La rive", "Le rivage",
]

const TRAITS := [
	"des Brumes", "du Ponant", "des Trois Caps", "aux Vents", "du Levant",
	"des Cendres", "aux Palmes", "du Long Sommeil", "des Marees", "aux Recifs",
	"du Sel", "des Fougeres", "du Corail", "aux Mouettes", "des Orages",
	"du Silence",
]


static func for_seed(seed_value: int) -> String:
	var value := absi(seed_value)
	@warning_ignore("integer_division")
	return "%s %s" % [FORMS[value % FORMS.size()],
		TRAITS[(value / FORMS.size()) % TRAITS.size()]]


# Portrait en une phrase, tire des MESURES de la carte et non du hasard.
#
# Il doit apprendre quelque chose : deux mondes qui se ressemblent a la
# vignette peuvent etre tres differents a parcourir, et c'est la part de
# terrain praticable qui le dit — pas la surface emergee.
static func describe(meta: Dictionary) -> String:
	if meta.is_empty():
		return "Monde d'une version precedente : ses mesures n'ont pas ete conservees."

	var land := float(meta.get("land", 0.0))
	var flat := float(meta.get("flat", 0.0))

	# Seuils cales sur les valeurs REELLEMENT observees — terres emergees de 38
	# a 46 %, terrain praticable de 27 a 42 %. Des bornes choisies a vue d'oeil
	# rangeaient tous les mondes dans la meme case, ce qui ne distingue rien.
	var extent := "Une ile resserree"
	if land > 0.45:
		extent = "Une terre vaste"
	elif land > 0.40:
		extent = "Une ile large"

	var relief := "au relief tourmente"
	if flat > 0.40:
		relief = "aux pentes clementes"
	elif flat > 0.32:
		relief = "melant plaines et hauteurs"

	# On cite le SECOND biome et non le premier : la prairie domine partout,
	# donc elle ne dit rien. C'est la neige, le desert ou la foret qui donnent
	# son caractere a une ile.
	var cover := ""
	var second: String = meta.get("second_biome", "")
	var share := float(meta.get("second_share", 0.0))
	if second != "" and share > 0.03:
		cover = ", ou %s tient %d %% des terres" % [second, int(round(share * 100.0))]
	return "%s %s%s." % [extent, relief, cover]
