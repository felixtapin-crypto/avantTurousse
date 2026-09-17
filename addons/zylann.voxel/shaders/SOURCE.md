# Origine de ces fichiers

Ces `.gdshaderinc` ne sont **pas** livrés dans l'archive GDExtension de
godot_voxel (`GodotVoxelExtension.zip`, release v1.7x) : elle ne contient que
les binaires, le descripteur et les icônes.

Ils proviennent du dépôt de démonstration
[Zylann/voxelgame](https://github.com/Zylann/voxelgame), dossier
`project/addons/zylann.voxel/shaders/`, sous licence MIT (Marc Gilleron).

Le terrain lissé en a besoin : `transvoxel.gdshaderinc` porte le morphing de
sommets entre niveaux de détail, `triplanar.gdshaderinc` la projection
triplanaire, et `voxel_texturing.gdshaderinc` le décodage des indices et
poids de matières. Sans eux, le shader de `smooth_terrain.gdshader` ne
compile pas.
