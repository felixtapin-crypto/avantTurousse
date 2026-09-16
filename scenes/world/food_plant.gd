class_name FoodPlant
extends Area3D

# Buisson recoltable (nourriture). Ramasse par clic si le joueur a l'outil
# de recolte (voir Player._dig et Collectible pour l'outil lui-meme) - sans
# quoi rien ne se passe. any_peer/call_local comme le reste des interactions
# reseau du jeu : quiconque recolte, tout le monde voit la plante disparaitre.

var harvested := false


@rpc("any_peer", "call_local", "reliable")
func harvest() -> void:
	if harvested:
		return
	harvested = true
	queue_free()
