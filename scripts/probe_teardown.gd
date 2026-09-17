extends SceneTree

# Combien coute la FERMETURE de la partie, et quelle part en est VISIBLE ?
#
#   godot --path . --script res://scripts/probe_teardown.gd
#
# Liberer un VoxelTerrain attend que sa file de generation se vide, et rien ne
# permet de l'annuler depuis GDScript. Fait pendant `free()`, cette attente est
# un gel muet ; faite avant, image par image, elle devient une barre.
#
# Releves de reference : 119 447 ms avec une distance de vue de 384 et un
# generateur qui parcourait chaque voxel, puis 9 978 ms apres optimisation.

const WORLD := "res://scenes/voxel_world/smooth_voxel_world.tscn"
const STREAM_SECONDS := 14.0


func _initialize() -> void:
	var world: Node = (load(WORLD) as PackedScene).instantiate()
	root.add_child(world)
	await create_timer(STREAM_SECONDS).timeout

	var t0 := Time.get_ticks_msec()
	await world._announce_exit("Retour a la carte...")
	var drained := Time.get_ticks_msec() - t0

	world.free()
	var total := Time.get_ticks_msec() - t0
	print("fermeture : %d ms au total, dont %d ms de barre et %d ms de gel"
		% [total, drained, total - drained])
	quit(0)
