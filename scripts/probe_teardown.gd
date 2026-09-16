extends SceneTree

# Combien coute la FERMETURE de la partie ?
#
#   godot --path . --script res://scripts/probe_teardown.gd
#
# Liberer un VoxelTerrain attend que sa file de generation se vide, et rien ne
# permet de l'annuler depuis GDScript. Tout ce que le generateur ne calcule pas
# assez vite se paie donc une seconde fois en quittant.
#
# Releve de reference : 119 447 ms, avec une distance de vue de 384 et un
# generateur qui parcourait chaque voxel.

const WORLD := "res://scenes/voxel_world/smooth_voxel_world.tscn"
const STREAM_SECONDS := 14.0


func _initialize() -> void:
	var world: Node = (load(WORLD) as PackedScene).instantiate()
	root.add_child(world)
	await create_timer(STREAM_SECONDS).timeout

	var t0 := Time.get_ticks_msec()
	world.free()
	print("fermeture de la partie : %d ms" % (Time.get_ticks_msec() - t0))
	quit(0)
