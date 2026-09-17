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


# Action de MEME TAILLE mais de moindre poids : la geometrie d'un bouton
# d'action, les couleurs assourdies d'une pastille.
#
# Taille et importance sont deux choses distinctes, et les confondre oblige a
# choisir entre un bouton trop discret pour qu'on le trouve et un bouton qui se
# dispute la primaute avec l'action principale. La taille dit « c'est un choix
# de ce niveau-la », la couleur dit « ce n'est pas celui qu'on attend de toi ».
static func quiet_action(text: String) -> Button:
	var button := pill(text)
	button.custom_minimum_size = Vector2(0, 46)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 16)
	return button


static func mark_selected(button: Button, selected: bool) -> void:
	button.add_theme_stylebox_override("normal",
		flat(Color(LAGOON, 0.30) if selected else Color(INK, 0.07), 4))
	button.add_theme_color_override("font_color", INK if selected else Color(INK, 0.70))


# --- Grille de lecture ------------------------------------------------------
#
# LES TROIS ECRANS D'AVANT-PARTIE SE LISENT AU MEME ENDROIT.
#
# Le retour en haut a gauche, l'enseigne juste apres, le titre du contexte
# dessous, les touches en pied de page. Un joueur qui passe de l'accueil au
# menu des mondes puis a l'ecran de carte ne doit pas avoir a RECHERCHER la
# sortie a chaque fois.
#
# Ces regles etaient auparavant reecrites dans chaque ecran, et elles ont
# diverge exactement comme on pouvait le craindre : le menu des mondes rangeait
# son retour en pied de page, a cote de « Vider le cache », ou il se lisait
# comme un reglage ; l'ecran de carte le mettait en en-tete. Les mettre ici,
# c'est les rendre impossibles a contredire par inadvertance.

# Marges de page. Moins d'air en haut, ou se tient la barre de navigation.
const MARGIN := 44
const MARGIN_TOP := 22

# Taille du titre de contexte, et de l'enseigne au-dessus.
const TITLE_SIZE := 52
const SIGN_SIZE := 13

# Hauteur de la barre de navigation. C'est celle d'une pastille — treize points
# de texte, huit pixels de marge de chaque cote — et elle est imposee meme aux
# en-tetes qui n'en portent pas. Voir `header`.
const HEADER_HEIGHT := 36


# --- Echelle d'espacement ---------------------------------------------------
#
# QUATRE ECARTS, ET PAS UN DE PLUS.
#
# Chaque ecran avait les siens : 4, 6, 10, 14, 18, 20, 28, 30. Aucun n'etait
# faux isolement, et ensemble ils ne disaient plus rien — deux elements separes
# de 14 sur un ecran et de 20 sur le suivant se lisent comme deux liens
# differents alors qu'ils sont le meme. Un ecart doit signifier quelque chose :
# c'est ce qui permet de voir d'un coup d'oeil ce qui va avec quoi.
#
# TIGHT   : deux choses qui n'en font qu'une (un intitule et sa valeur).
# ROW     : deux lignes d'une meme liste, deux rangees d'une page.
# GROUP   : deux groupes d'un meme sujet.
# SECTION : deux sujets differents.
const SPACE_TIGHT := 6
const SPACE_ROW := 12
const SPACE_GROUP := 22
const SPACE_SECTION := 34


# Ecart entre deux groupes, pose DANS une colonne dont les lignes sont deja
# separees de `SPACE_TIGHT`.
#
# La separation de la colonne s'ajoute de part et d'autre du vide insere : un
# `gap(22)` dans une colonne a 6 donne 34 a l'ecran, pas 22. On la retranche ici
# pour que l'ecart MESURE soit le meme partout, quelle que soit la colonne qui
# le porte — c'est tout l'interet d'avoir une echelle.
static func group_gap() -> Control:
	return gap(SPACE_GROUP - 2 * SPACE_TIGHT)


static func section_gap() -> Control:
	return gap(SPACE_SECTION - 2 * SPACE_TIGHT)


# Colonne de contenu : l'empilement standard, aux lignes serrees. Les ecarts
# plus larges s'y posent avec `group_gap` et `section_gap`.
static func column(width: int) -> VBoxContainer:
	var node := VBoxContainer.new()
	node.add_theme_constant_override("separation", SPACE_TIGHT)
	node.custom_minimum_size = Vector2(width, 0)
	return node


# Page complete : fond, marges, et la colonne verticale ou tout s'empile.
# Rend cette colonne, a laquelle l'appelant ajoute ses rangees.
#
# LA PAGE PREND TOUT L'ECRAN, ET C'EST ICI QUE C'EST GARANTI.
#
# Un ecran bati en code plutot que depuis un `.tscn` n'a pas d'ancres : il nait
# a la taille zero, son fond ne peint rien, et ses conteneurs se rabattent sur
# leur taille MINIMALE. On obtient alors un ecran qui flotte en haut a gauche,
# transparent, par-dessus celui qu'il etait cense remplacer — exactement ce
# qu'ont donne l'ecran des parametres et le menu de pause a leur premiere
# version.
#
# `set_anchors_preset` seul ne suffit pas : il pose les ancres sans toucher aux
# marges, donc la taille ne bouge pas. Il faut la variante qui pose les deux.
static func page(screen: Control) -> VBoxContainer:
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.add_child(backdrop())

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, MARGIN)
	margin.add_theme_constant_override("margin_top", MARGIN_TOP)
	screen.add_child(margin)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", SPACE_ROW)
	margin.add_child(rows)
	return rows


# Barre de navigation : l'enseigne et l'etat a gauche, le retour A DROITE.
#
# L'enseigne ouvre la ligne parce qu'elle est l'ancre d'identite — c'est le
# seul element commun a tous les ecrans, et il ne bouge jamais. L'etat la suit,
# la ou le regard vient de passer. Le retour ferme la ligne, a l'oppose.
#
# Un texte de retour vide donne un en-tete sans sortie : l'ecran d'accueil, qui
# n'a nulle part ou remonter.
static func header(back_text: String, on_back: Callable,
		status: Control = null) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", SPACE_ROW)
	# L'EN-TETE A TOUJOURS LA MEME HAUTEUR, avec ou sans pastille de retour.
	#
	# Sinon la ligne se rabat sur la hauteur de l'enseigne seule, et le titre
	# remonte de dix-sept pixels sur les ecrans qui n'ont nulle part ou
	# remonter — l'accueil, la pause. Un titre qui change de place d'un ecran a
	# l'autre est precisement ce que cette grille existe pour empecher.
	row.custom_minimum_size = Vector2(0, HEADER_HEIGHT)
	row.add_child(label("AVANT TOUROUSSE", SIGN_SIZE, Color(INK, 0.45)))
	if status != null:
		row.add_child(status)
	row.add_child(spacer())
	if back_text != "":
		var back := pill(back_text)
		back.pressed.connect(on_back)
		row.add_child(back)
	return row


static func spacer() -> Control:
	var node := Control.new()
	node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return node


# Bande de contenu CENTREE dans la page.
#
# Les ecrans rangeaient leur colonne a gauche, avec le vide a sa droite. Sur une
# fenetre large cela donnait un tiers d'ecran occupe et deux tiers deserts, et
# l'oeil devait repartir a gauche a chaque ligne alors que la page, elle, est
# large.
#
# La navigation ne passe PAS par ici : l'enseigne, la pastille de retour et le
# pied de page tiennent les bords de la page, parce que c'est la qu'on va les
# chercher. Seul le contenu se centre.
static func centered(content: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(spacer())
	row.add_child(content)
	row.add_child(spacer())
	return row


# Titre du contexte : ce qu'on regarde sur CET ecran. Toujours sous
# l'enseigne, toujours a gauche, toujours a la meme taille.
static func title(text: String) -> Label:
	return label(text, TITLE_SIZE, INK)


# Sous-titre : la phrase d'or sous le titre. Elle dit de quoi parle l'ecran, pas
# ce qu'il faut y faire.
static func subtitle(text: String) -> Label:
	return label(text, 17, Color(GOLD, 0.85))


# PAS DE RAPPEL DES TOUCHES EN PIED DE PAGE.
#
# Il y en a eu trois : en jeu, au menu des mondes, et brievement sur les ecrans
# de pause et de parametres. Tous retires, et pour la meme raison a chaque fois.
#
# Une ligne « ECHAP retour » ne rend service qu'a qui sait deja lire une ligne
# de raccourcis — et celui-la n'en a pas besoin. Elle double un bouton qui est
# a l'ecran, en moins visible, et elle occupe le bas de la page a ne rien dire.
# Ce qui doit etre fait doit etre CLIQUABLE ; le raccourci vient en plus, pas a
# la place.


# Fond d'ecran : la couleur de nuit, posee sous tout le reste.
#
# PLEIN ET OPAQUE, toujours. Un ecran qui laisse voir celui d'avant n'est pas un
# ecran, c'est un panneau — et on a eu les deux qui se lisaient en meme temps.
static func backdrop() -> ColorRect:
	var node := ColorRect.new()
	node.color = BG
	node.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
