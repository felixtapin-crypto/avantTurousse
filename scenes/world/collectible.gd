class_name Collectible
extends Area3D

# Objet ramassable par clic (voir Player._dig, qui verifie "est-ce que je
# vise un Collectible" avant de creuser le terrain). any_peer + call_local :
# n'importe quel joueur peut le ramasser, et l'effet (disparition + benefice
# debloque) s'applique chez tout le monde, comme le reste du reseau du jeu.

@export var spin_speed := 1.2

var collected := false


func _process(delta: float) -> void:
	rotate_y(spin_speed * delta)


# Premier (et pour l'instant seul) artefact du jeu : l'horloge. Code en dur
# plutot que generique tant qu'il n'y a qu'un seul type d'objet a ramasser -
# a revoir (type d'artefact + effet associe en parametre) des qu'un
# deuxieme gabarit d'enigme arrive.
@rpc("any_peer", "call_local", "reliable")
func pick_up() -> void:
	if collected:
		return
	collected = true

	for player in get_tree().get_nodes_in_group("players"):
		if player.is_multiplayer_authority() and player.has_method("unlock_clock"):
			player.unlock_clock()

	queue_free()
