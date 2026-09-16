class_name IslandUI
extends RefCounted

# Vocabulaire visuel des ecrans d'avant-partie : menu des mondes, puis apercu
# de la carte.
#
# Il est PARTAGE et non recopie. Deux ecrans qui se suivent immediatement ne
# supportent pas la moindre derive — un or un peu different, un rayon d'angle
# de plus, et la transition se voit. Recopier six constantes aurait tenu le
# temps d'un commit, puis l'un des deux aurait bouge seul.
#
# L'interface est construite EN CODE plutot qu'en .tscn : le style repose sur
# des StyleBox et des opacites graduees, penibles a relire dans un fichier de
# scene, et les vignettes comme les barres de biomes sont produites a partir
# des donnees, donc leur nombre n'est pas connu d'avance.

# Palette : nuit oceanique, encre parcheminee, or de sable, lagon. On evite le
# gris neutre, qui ferait outil de debug plutot qu'ecran de jeu.
const BG := Color("#0b1a1f")
const BG_SOFT := Color("#122a31")
const INK := Color("#f0e6d2")
const GOLD := Color("#e0a542")
const LAGOON := Color("#4fb3a5")
const CORAL := Color("#e2725b")


static func label(text: String, size: int, color: Color) -> Label:
	var node := Label.new()
	node.text = text
	node.add_theme_font_size_override("font_size", size)
	node.add_theme_color_override("font_color", color)
	return node


static func caption(text: String) -> Label:
	return label(text, 11, Color(INK, 0.40))


static func gap(height: int) -> Control:
	var node := Control.new()
	node.custom_minimum_size = Vector2(0, height)
	return node


static func flat(color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(8)
	return style


# Piste de barre : coins arrondis, sans marge interieure — elle ne contient
# rien, elle EST le trait.
static func bar(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(2)
	style.set_content_margin_all(0)
	return style


# Bouton plat facon pastille, sans le relief du theme par defaut : c'est ce
# qui distingue le plus une interface de jeu d'un panneau d'editeur.
static func pill(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 13)
	button.add_theme_color_override("font_color", Color(INK, 0.70))
	button.add_theme_color_override("font_hover_color", INK)
	button.add_theme_color_override("font_pressed_color", INK)
	button.add_theme_stylebox_override("normal", flat(Color(INK, 0.07), 4))
	button.add_theme_stylebox_override("hover", flat(Color(INK, 0.15), 4))
	button.add_theme_stylebox_override("pressed", flat(Color(LAGOON, 0.35), 4))
	return button


# Bouton d'action pleine largeur. La couleur DIT ce que fait le bouton : le
# lagon pour rester sur cet ecran, l'or pour en partir.
static func action_button(text: String, color: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 46)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 16)
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(state, BG)
	# Un bouton desactive doit se lire comme tel sans qu'on ait a le cliquer :
	# fond eteint et texte efface, pas seulement une teinte un peu differente.
	button.add_theme_color_override("font_disabled_color", Color(INK, 0.30))
	button.add_theme_stylebox_override("normal", flat(color, 4))
	button.add_theme_stylebox_override("hover", flat(color.lightened(0.12), 4))
	button.add_theme_stylebox_override("pressed", flat(color.darkened(0.15), 4))
	button.add_theme_stylebox_override("disabled", flat(Color(INK, 0.07), 4))
	return button


static func mark_selected(button: Button, selected: bool) -> void:
	button.add_theme_stylebox_override("normal",
		flat(Color(LAGOON, 0.30) if selected else Color(INK, 0.07), 4))
	button.add_theme_color_override("font_color", INK if selected else Color(INK, 0.70))


# Fond d'ecran : la couleur de nuit, posee sous tout le reste.
static func backdrop() -> ColorRect:
	var node := ColorRect.new()
	node.color = BG
	node.set_anchors_preset(Control.PRESET_FULL_RECT)
	return node


# Cadre discret. Une carte doit se lire comme une piece posee sur la table,
# pas comme un widget colle au fond.
static func frame() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = BG_SOFT
	style.set_corner_radius_all(6)
	style.set_border_width_all(1)
	style.border_color = Color(INK, 0.12)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	return panel
