class_name GliderBuilder
extends RefCounted

# Construction du placeholder d'engin volant steampunk (nacelle/aile/helice
# en primitives, en attendant un vrai modele) partagee entre :
# - Player._play_arrival_sequence() : l'anime en vol le temps de la cinematique
# - World.spawn_wreck() : en pose une copie figee, comme epave, apres l'atterrissage


static func build() -> Node3D:
	var rig := Node3D.new()

	var wood_material := StandardMaterial3D.new()
	wood_material.albedo_color = Color(0.4, 0.26, 0.14)

	var brass_material := StandardMaterial3D.new()
	brass_material.albedo_color = Color(0.72, 0.53, 0.18)
	brass_material.metallic = 0.6
	brass_material.roughness = 0.35

	var gondola := MeshInstance3D.new()
	var gondola_mesh := BoxMesh.new()
	gondola_mesh.size = Vector3(1.0, 0.8, 1.6)
	gondola.mesh = gondola_mesh
	gondola.material_override = wood_material
	gondola.position = Vector3(0, -0.6, 0)
	rig.add_child(gondola)

	var wing := MeshInstance3D.new()
	var wing_mesh := BoxMesh.new()
	wing_mesh.size = Vector3(3.6, 0.1, 1.0)
	wing.mesh = wing_mesh
	wing.material_override = brass_material
	wing.position = Vector3(0, 0.1, 0)
	rig.add_child(wing)

	var tail := MeshInstance3D.new()
	var tail_mesh := BoxMesh.new()
	tail_mesh.size = Vector3(0.15, 0.6, 0.15)
	tail.mesh = tail_mesh
	tail.material_override = brass_material
	tail.position = Vector3(0, 0.1, 1.1)
	rig.add_child(tail)

	var propeller := MeshInstance3D.new()
	var propeller_mesh := BoxMesh.new()
	propeller_mesh.size = Vector3(0.08, 1.3, 0.12)
	propeller.mesh = propeller_mesh
	propeller.material_override = brass_material
	propeller.position = Vector3(0, 0.1, -1.0)
	rig.add_child(propeller)

	return rig
