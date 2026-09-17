class_name HostStatus
extends Label

# Temoin d'hebergement, pose dans l'en-tete des ecrans que l'HOTE traverse
# avant d'entrer en partie.
#
# L'HOTE ETAIT AVEUGLE, et c'etait le trou le plus couteux de la cinematique
# d'ecrans. Il ouvre son serveur depuis l'accueil, puis choisit son monde ;
# pendant ce temps un client peut se connecter, et il PATIENTE — la scene de
# jeu n'annonce le monde qu'a l'entree en partie, parce que c'est la que les
# reglages de l'hote sont arretes (voir `network.gd`). Rien, nulle part, ne
# disait a l'hote que quelqu'un l'attendait : il pouvait comparer des vignettes
# pendant que son compagnon fixait « Connecte, en attente du monde de
# l'hote... ».
#
# Il se tait en solo. Un temoin qui affiche toujours la meme chose n'est pas
# une information.
#
# C'est un noeud a part et non un bout de `world_menu.gd`, parce que DEUX
# ecrans le portent — le menu des mondes et l'apercu de carte — et que deux
# copies auraient diverge le jour ou l'on change le libelle.

const IDLE_COLOR := Color(IslandUI.INK, 0.45)
const WAITING_COLOR := IslandUI.GOLD


func _ready() -> void:
	add_theme_font_size_override("font_size", IslandUI.SIGN_SIZE)
	Network.player_connected.connect(_on_roster_changed)
	Network.player_disconnected.connect(_on_roster_changed_one)
	Network.server_disconnected.connect(_refresh)
	_refresh()


func _on_roster_changed(_id: int, _player_name: String) -> void:
	_refresh()


func _on_roster_changed_one(_id: int) -> void:
	_refresh()


func _refresh() -> void:
	# `Network.is_hosting()` et non `multiplayer.is_server()` : voir la note sur
	# le pair hors ligne dans `network.gd`. Ce temoin s'allumait en solo.
	if not Network.is_hosting():
		text = ""
		return

	# L'hote se compte lui-meme dans `players` : ce sont les AUTRES qui
	# attendent.
	var guests := maxi(Network.players.size() - 1, 0)
	if guests == 0:
		text = "· PARTIE OUVERTE, EN ATTENTE D'UN JOUEUR"
		add_theme_color_override("font_color", IDLE_COLOR)
		return
	text = "· %d JOUEUR%s ATTEND%s VOTRE MONDE" % [
		guests, "S" if guests > 1 else "", "ENT" if guests > 1 else ""]
	add_theme_color_override("font_color", WAITING_COLOR)
