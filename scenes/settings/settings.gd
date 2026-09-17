extends SettingsScreen

# L'ecran des parametres COMME SCENE, pour l'accueil.
#
# Le meme ecran sert a deux endroits, et il n'y est pas ouvert de la meme
# facon :
#
# - depuis l'ACCUEIL, c'est une scene, comme « Jouer seul » ou « Heberger ».
#   Rien n'est charge derriere, donc rien ne coute a demonter, et le bouton se
#   comporte alors exactement comme ses voisins ;
# - depuis la PAUSE, c'est un noeud superpose. Changer de scene demonterait le
#   terrain voxel — une file de generation a vider a l'aller, plusieurs secondes
#   de calcul au retour — pour regler une sensibilite de souris.
#
# Le joueur ne voit pas la difference : c'est la meme classe, la meme grille et
# les memes onglets dans les deux cas. Seule la pastille de retour change de
# nom, parce qu'elle nomme sa destination.

const MAIN_MENU := "res://scenes/main_menu/main_menu.tscn"


func _ready() -> void:
	# AVANT `super()`, qui batit l'en-tete et y lit ce nom.
	back_label = "Accueil"
	closed.connect(_go_home)
	super()


func _go_home() -> void:
	get_tree().change_scene_to_file(MAIN_MENU)
