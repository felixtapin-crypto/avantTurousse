class_name MapCache
extends RefCounted

# Cache disque des cartes generees.
#
# Generer une carte de 600 coute environ 2,7 s, entierement bloquantes. Rejouer
# la meme seed ou revenir a l'ecran d'apercu ne devrait pas les repayer.
#
# ---------------------------------------------------------------------------
# LE POINT DELICAT : CE QUI INVALIDE LE CACHE
# ---------------------------------------------------------------------------
#
# Une carte ne depend pas que de la seed et de la taille. Elle depend de TOUS
# les reglages de la generation : seuil de littoral, force d'erosion, gradient
# adiabatique, seuils de biome... Changer l'un d'eux produit un monde
# different pour la meme seed.
#
# Un cache qui ne surveillerait que la seed servirait donc silencieusement une
# carte perimee des la premiere retouche de calibrage — et comme on passe
# precisement notre temps a calibrer, ce serait un piege permanent : on
# croirait un reglage sans effet alors qu'on relit une vieille carte.
#
# D'ou l'empreinte des parametres, calculee par INTROSPECTION plutot qu'a
# partir d'une liste ecrite a la main. `get_script_constant_map()` rend les 52
# constantes de `WorldMap` ; toute constante ajoutee ou modifiee entre donc
# dans l'empreinte sans que personne n'ait a y penser. Une liste manuelle
# aurait exactement le defaut qu'on vient de corriger sur les biomes : elle
# derive des qu'on oublie une entree.
#
# L'introspection ne voit en revanche PAS le code lui-meme. Modifier la boucle
# d'erosion sans toucher a une constante ne changerait pas l'empreinte, d'ou
# `WorldMap.GENERATION_VERSION`, a incrementer dans ce cas — et qui, etant une
# constante, se retrouve de fait dans l'empreinte.

const CACHE_DIR := "user://map_cache"
# Structure du fichier. A incrementer si la liste des tableaux stockes change,
# sinon une ancienne entree serait relue de travers.
const FORMAT_VERSION := 1
# Au-dela, les entrees les plus anciennes sont supprimees. Une carte de 600
# pese une dizaine de Mo : sans plafond, un apres-midi de calibrage remplirait
# le disque d'etats intermediaires dont plus rien ne se sert.
const MAX_ENTRIES := 12

static var _last_was_cached := false


# Retourne la carte correspondant a ces parametres, depuis le cache si elle
# s'y trouve, en la calculant sinon.
# `target` est la carte a remplir, fournie par l'appelant.
#
# Elle existe pour que l'appelant puisse SURVEILLER le calcul : c'est lui qui
# tient l'objet, donc il peut lire `progress` et poser `cancel_requested`
# pendant que `generate()` tourne sur un autre fil. Sans elle, la carte
# n'existerait qu'au retour de la fonction, c'est-a-dire une fois le calcul
# fini — trop tard pour afficher quoi que ce soit ou pour l'interrompre.
#
# Retourne `null` si la generation a ete annulee. Une carte a moitie calculee
# n'est pas une carte, et surtout elle ne doit pas atterrir dans le cache.
static func load_or_generate(seed_value: int, size: int, height: int,
		target: WorldMap = null) -> WorldMap:
	var path := _path_for(seed_value, size, height)

	# La relecture est rapide et ne s'annule pas : inutile de la surveiller.
	var cached := _read(path, seed_value, size, height)
	if cached != null:
		_last_was_cached = true
		return cached

	var map := target if target != null else WorldMap.new(size, height)
	map.generate(seed_value)
	if map.cancel_requested:
		return null
	_write(path, map)
	_last_was_cached = false
	return map


# Vrai si le dernier appel a `load_or_generate` a servi une carte du cache.
# Sert a l'affichage : "repris du cache" ou "genere en N ms" ne racontent pas
# la meme chose a qui calibre la generation.
static func last_was_cached() -> bool:
	return _last_was_cached


# Empreinte de TOUS les reglages de generation, lue par introspection.
static func parameters_hash() -> int:
	var script: GDScript = WorldMap
	var constants := script.get_script_constant_map()
	var names := constants.keys()
	names.sort() # ordre stable : un dictionnaire ne garantit pas le sien

	var parts := PackedStringArray()
	for name in names:
		parts.append("%s=%s" % [name, constants[name]])
	return hash("\n".join(parts))


static func entry_count() -> int:
	var dir := DirAccess.open(CACHE_DIR)
	if dir == null:
		return 0
	return _entries(dir).size()


static func clear() -> void:
	var dir := DirAccess.open(CACHE_DIR)
	if dir == null:
		return
	for entry in _entries(dir):
		dir.remove(entry)
	_last_was_cached = false


static func _path_for(seed_value: int, size: int, height: int) -> String:
	# L'empreinte est dans le NOM : une retouche de reglage produit un autre
	# fichier, donc l'ancien n'est jamais relu par accident. Il sera balaye par
	# le plafond d'entrees.
	return "%s/%x_%d_%dx%d.bin" % [
		CACHE_DIR, parameters_hash() & 0xffffffff, seed_value, size, height]


static func _read(path: String, seed_value: int, size: int, height: int) -> WorldMap:
	if not FileAccess.file_exists(path):
		return null

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var data = file.get_var()
	file.close()

	if typeof(data) != TYPE_DICTIONARY:
		return null
	# Ceinture et bretelles : le nom de fichier porte deja ces valeurs, mais un
	# fichier tronque ou venant d'une autre version doit etre ignore, pas
	# charge de travers.
	if int(data.get("format", -1)) != FORMAT_VERSION:
		return null
	if int(data.get("params", 0)) != parameters_hash():
		return null
	if int(data.get("seed", 0)) != seed_value:
		return null
	if int(data.get("size", 0)) != size or int(data.get("height", 0)) != height:
		return null

	var map := WorldMap.new(size, height)
	if not map.restore_state(data):
		return null
	return map


static func _write(path: String, map: WorldMap) -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)

	var data := map.capture_state()
	data["format"] = FORMAT_VERSION
	data["params"] = parameters_hash()

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Cache de carte : ecriture impossible dans %s" % path)
		return
	file.store_var(data)
	file.close()

	_enforce_limit()


static func _entries(dir: DirAccess) -> PackedStringArray:
	var out := PackedStringArray()
	for name in dir.get_files():
		if name.ends_with(".bin"):
			out.append(name)
	return out


static func _enforce_limit() -> void:
	var dir := DirAccess.open(CACHE_DIR)
	if dir == null:
		return
	var files := _entries(dir)
	if files.size() <= MAX_ENTRIES:
		return

	# Les plus anciennes d'abord : celle qu'on vient d'ecrire est la plus
	# recente, donc jamais la victime.
	var dated := []
	for name in files:
		dated.append({
			"name": name,
			"time": FileAccess.get_modified_time("%s/%s" % [CACHE_DIR, name]),
		})
	dated.sort_custom(func(a, b): return a["time"] < b["time"])

	for i in range(dated.size() - MAX_ENTRIES):
		dir.remove(dated[i]["name"])
