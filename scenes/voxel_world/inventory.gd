class_name Inventory
extends RefCounted

# Cases + pile, generique : ce fichier ne connait ni la terre ni le caillou
# specifiquement, tout passe par `ItemCatalog`. Remplace l'ancien compteur
# brut `carried`/`CARRY_CAPACITY` (PR #49), qui ne pouvait porter qu'un seul
# type de matiere indifferenciee.

const BASE_SLOT_COUNT := 9  # touches 1-9 du clavier, standard du genre (Minecraft, Terraria)

# Chaque case est soit `null` (vide), soit {"item": int, "count": int}.
var _slots: Array = []
var active_slot := 0

# Emplacement d'equipement -> item_id. Absent (pas de cle) si rien n'y est
# equipe. Un seul emplacement existe pour l'instant ("back"), voir
# `ItemCatalog.EQUIP_SLOT`.
var _equipped := {}


func _init() -> void:
	_slots.resize(BASE_SLOT_COUNT)


func slot_count() -> int:
	return _slots.size()


func get_slot(index: int) -> Variant:
	return _slots[index]


func equipped(slot_name: String) -> Variant:
	return _equipped.get(slot_name, null)


# Vrai s'il existe une pile de `item_id` pas encore pleine, OU une case vide.
func has_room(item_id: int) -> bool:
	var max_stack := ItemCatalog.max_stack(item_id)
	for slot in _slots:
		if slot == null:
			return true
		if slot["item"] == item_id and slot["count"] < max_stack:
			return true
	return false


# Ajoute jusqu'a `amount` unites de `item_id`, en remplissant d'abord les
# piles existantes non pleines (dans l'ordre des cases), puis des cases
# vides. Retourne la quantite REELLEMENT ajoutee (peut etre inferieure a
# `amount`, jamais negative) ; l'appelant decide quoi faire du reste
# (aujourd'hui : rien, `_edit`/`ItemPickup` n'ajoutent jamais plus d'une
# unite a la fois).
func add(item_id: int, amount: int) -> int:
	var max_stack := ItemCatalog.max_stack(item_id)
	var remaining := amount

	for i in _slots.size():
		if remaining <= 0:
			break
		var slot = _slots[i]
		if slot != null and slot["item"] == item_id and slot["count"] < max_stack:
			var room: int = max_stack - slot["count"]
			var taken: int = mini(room, remaining)
			slot["count"] += taken
			remaining -= taken

	for i in _slots.size():
		if remaining <= 0:
			break
		if _slots[i] == null:
			var taken: int = mini(max_stack, remaining)
			_slots[i] = {"item": item_id, "count": taken}
			remaining -= taken

	return amount - remaining


func count(item_id: int) -> int:
	var total := 0
	for slot in _slots:
		if slot != null and slot["item"] == item_id:
			total += slot["count"]
	return total


# Retire `amount` unites de `item_id`, en vidant d'abord la PLUS PETITE pile
# (laisse moins de cases a moitie pleines derriere). Refuse (false, aucune
# mutation) si le total disponible est insuffisant : jamais de retrait
# partiel silencieux.
func remove(item_id: int, amount: int) -> bool:
	if count(item_id) < amount:
		return false

	var remaining := amount
	while remaining > 0:
		var smallest_index := -1
		var smallest_count := 0
		for i in _slots.size():
			var slot = _slots[i]
			if slot != null and slot["item"] == item_id:
				if smallest_index == -1 or slot["count"] < smallest_count:
					smallest_index = i
					smallest_count = slot["count"]

		var taken: int = mini(smallest_count, remaining)
		_slots[smallest_index]["count"] -= taken
		remaining -= taken
		if _slots[smallest_index]["count"] <= 0:
			_slots[smallest_index] = null

	return true


func select(index: int) -> void:
	active_slot = clampi(index, 0, BASE_SLOT_COUNT - 1)


func cycle(direction: int) -> void:
	active_slot = wrapi(active_slot + direction, 0, BASE_SLOT_COUNT)


# Deplace l'objet de `slot_index` vers son emplacement d'equipement dedie, et
# agrandit l'inventaire de `ItemCatalog.capacity_bonus(item_id)` cases vides
# ajoutees a la fin. Refuse si la case ne contient pas un objet d'equipement,
# si l'emplacement est deja occupe, ou si la pile porte plus d'une unite
# (l'equipement n'est jamais empile, voir `ItemCatalog.MAX_STACK`).
func equip_from_slot(slot_index: int) -> bool:
	var slot = _slots[slot_index]
	if slot == null:
		return false
	var item_id: int = slot["item"]
	if not ItemCatalog.is_equipment(item_id):
		return false
	var slot_name := ItemCatalog.equip_slot(item_id)
	if _equipped.has(slot_name):
		return false

	_equipped[slot_name] = item_id
	_slots[slot_index] = null
	for _i in ItemCatalog.capacity_bonus(item_id):
		_slots.append(null)
	return true


# Inverse de `equip_from_slot` : remet l'objet dans une case libre et retire
# les cases bonus qu'il accordait. Refuse si retirer ces cases laisserait des
# objets sans case pour les recevoir - regle volontairement simple : le
# nombre de cases OCCUPEES doit deja tenir dans (slot_count() - bonus) avant
# de deshabiller, message a l'appelant de vider des cases sinon. Compacte les
# objets vers le debut du tableau avant de raccourcir, pour que les cases
# retirees en fin de tableau soient garanties vides.
func unequip(slot_name: String) -> bool:
	if not _equipped.has(slot_name):
		return false
	var item_id: int = _equipped[slot_name]
	var bonus := ItemCatalog.capacity_bonus(item_id)
	var target_count := slot_count() - bonus

	var occupied := 0
	for slot in _slots:
		if slot != null:
			occupied += 1
	# +1 : l'objet qu'on va replacer a besoin lui-meme d'une case.
	if occupied + 1 > target_count:
		return false

	var compacted: Array = []
	for slot in _slots:
		if slot != null:
			compacted.append(slot)
	compacted.append({"item": item_id, "count": 1})
	while compacted.size() < target_count:
		compacted.append(null)

	_slots = compacted
	_equipped.erase(slot_name)
	return true
