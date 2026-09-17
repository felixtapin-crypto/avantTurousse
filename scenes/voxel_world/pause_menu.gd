class_name PauseMenu
extends Control

# Ecran de pause, ouvert par ECHAP en partie.
#
# C'EST UN ECRAN, PAS UN VOILE. Il prend toute la surface, il est opaque, et il
# suit la meme grille que l'accueil, le menu des mondes et l'apercu de carte :
# enseigne en haut a gauche, retour en haut a droite, titre dessous, touches en
# pied de page (voir la section « Grille de lecture » d'`island_ui.gd`).
#
# Sa premiere version laissait voir le monde par transparence, au motif qu'une
# pause n'est pas un changement d'ecran. C'etait une idee de designer et non une
# regle du jeu : elle donnait un panneau flottant la ou tous les autres ecrans
# sont des pages pleines, et le joueur devait relire l'ecran pour retrouver ses
# reperes.
#
# Il remplace la touche `M`, qui renvoyait au menu des mondes sans rien dire et
# ne se devinait pas. Echap est la touche qu'on presse quand on veut sortir de
# quelque chose : lui donner le menu de sortie, c'est la brancher sur ce qu'on
# en attend deja.
#
# ECHAP NE REND PLUS LA SOURIS, parce qu'il n'y a plus rien a rendre : le
# curseur est libre en permanence (voir `voxel_debug_player.gd`). C'est ce qui
# levait l'ancienne tension — la meme touche liberait la souris ET aurait du
# ouvrir un menu.
#
# LE RETOUR SE FAIT A L'ACCUEIL et non au menu des mondes. Un client n'a rien a
# faire dans un selecteur de cartes : le monde lui vient de l'hote, et choisir
# la sienne n'aurait aucun effet. L'accueil, lui, est le seul ecran qui ferme
# proprement la partie en cours — il appelle `Network.leave_game()` en arrivant.

signal resumed
signal settings_requested
signal home_requested
signal quit_requested


func _ready() -> void:
	# Le menu de pause doit vivre PENDANT la pause, sinon il ne pourrait ni
	# s'afficher ni se refermer.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func _build() -> void:
	var rows := IslandUI.page(self)

	# LA SORTIE EST LA OU ELLE EST PARTOUT AILLEURS : la pastille de retour, en
	# haut a droite. Elle porte ici la reprise de la partie, parce que c'est
	# bien ce qu'il y a « au-dessus » de cet ecran.
	#
	# Un gros bouton « Reprendre » en tete de colonne aurait dit la meme chose
	# une seconde fois, a un endroit different de tous les autres ecrans. La
	# colonne est donc laissee aux trois vrais choix.
	rows.add_child(IslandUI.header("← Reprendre la partie", _on_resume))

	var column := IslandUI.column(460)
	rows.add_child(IslandUI.centered(column))

	column.add_child(IslandUI.title("Pause"))
	column.add_child(IslandUI.subtitle("L'ile vous attend."))
	column.add_child(IslandUI.group_gap())

	# Lagon : on reste dans les ecrans. Voir la note de couleur sur
	# `IslandUI.action_button`.
	var settings := IslandUI.action_button("Parametres", IslandUI.LAGOON)
	settings.pressed.connect(func(): settings_requested.emit())
	column.add_child(settings)

	column.add_child(IslandUI.section_gap())
	column.add_child(IslandUI.caption("QUITTER LA PARTIE"))

	var home := IslandUI.quiet_action("Retour au menu principal")
	home.pressed.connect(func(): home_requested.emit())
	column.add_child(home)

	var quit := IslandUI.quiet_action("Quitter sur le bureau")
	quit.pressed.connect(func(): quit_requested.emit())
	column.add_child(quit)


# Echap referme ce que Echap a ouvert.
#
# La garde sur `visible` compte : l'ecran des parametres se superpose a celui-ci,
# et sans elle une seule pression ferait les deux — retour depuis les parametres
# ET reprise de la partie.
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_resume()


func _on_resume() -> void:
	resumed.emit()
