class_name Collectible
extends Area3D

# Objet ramassable par clic (voir Player._dig, qui verifie "est-ce que je
# vise un Collectible" avant de creuser le terrain). any_peer + call_local :
# n'importe quel joueur peut le ramasser, et l'effet (disparition + benefice
# debloque) s'applique chez tout le monde, comme le reste du reseau du jeu.
#
# Generalise (voir TASKS.md / issue "Generaliser Collectible") : le nom de
# la methode a appeler sur le joueur qui ramasse est parametrable, pour
# pouvoir reutiliser cette meme classe pour l'horloge, l'outil de recolte,
# et les prochains artefacts a venir.

@export var spin_speed := 1.2
@export var unlock_method := "unlock_clock"

var collected := false


func _process(delta: float) -> void:
	rotate_y(spin_speed * delta)


@rpc("any_peer", "call_local", "reliable")
func pick_up() -> void:
	if collected:
		return
	collected = true

	for player in get_tree().get_nodes_in_group("players"):
		if player.is_multiplayer_authority() and player.has_method(unlock_method):
			player.call(unlock_method)

	queue_free()
