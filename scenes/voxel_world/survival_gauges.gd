class_name SurvivalGauges
extends RefCounted

# Faim, soif, vie - purement LOCAL au joueur (comme `Inventory`) : contrairement
# au terrain, l'etat de survie de chacun n'a rien de partage, donc pas besoin de
# passer par l'hote pour le faire evoluer. Voir DESIGN.md, "Boucle de survie".

const MAX := 100.0

# A calibrer en playtest (meme reserve que partout ailleurs dans ce code pour
# ce genre de reglage). Points de repere : une jauge pleine tient 15 min de
# faim, 10 de soif - la soif presse plus vite, comme dans la plupart des jeux
# de survie et dans la realite.
const HUNGER_DECAY_PER_SEC := MAX / (15.0 * 60.0)
const THIRST_DECAY_PER_SEC := MAX / (10.0 * 60.0)

# DESIGN.md laisse ouvert ce qui se passe a faim/soif nulles ("a trancher
# ensemble"). Choix pour cette version : des degats progressifs plutot qu'une
# mort nette - la pression est reelle, mais rien de definitif tant que la
# vraie condition de mort n'a pas ete tranchee. Vide en 90s de privation
# totale (faim ET soif a zero en meme temps).
const STARVING_DAMAGE_PER_SEC := MAX / 90.0
# Plancher et non zero : "pas de mort directe" cette version.
const MIN_HEALTH := 1.0

var hunger := MAX
var thirst := MAX
var health := MAX


func update(delta: float) -> void:
	hunger = maxf(0.0, hunger - HUNGER_DECAY_PER_SEC * delta)
	thirst = maxf(0.0, thirst - THIRST_DECAY_PER_SEC * delta)
	if hunger <= 0.0 or thirst <= 0.0:
		health = maxf(MIN_HEALTH, health - STARVING_DAMAGE_PER_SEC * delta)


func eat(item_id: int) -> void:
	hunger = minf(MAX, hunger + ItemCatalog.hunger_restore(item_id))


# Boire desaltere completement : une source d'eau n'est pas une ressource
# rare comme la nourriture, doser la gorgee n'apporterait rien.
func drink() -> void:
	thirst = MAX
