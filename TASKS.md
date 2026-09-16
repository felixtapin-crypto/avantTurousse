# Suivi de travail et coordination

Objectif de ce fichier : que personne ne découvre en pullant que l'autre a
retravaillé le même système en parallèle. Le principe est simple :

1. **Avant de commencer un morceau non-trivial** (un système, pas une
   correction de bug d'une ligne), ajoute une ligne dans "En cours" avec ton
   nom, la date, et ce que tu attaques.
2. **Avant de toucher à un système déjà pris par l'autre**, ou à quelque
   chose qui touche l'architecture commune (format de sauvegarde, structure
   des voxels, code réseau), préviens-le (message, appel, peu importe) avant
   de coder, pas après.
3. Quand c'est fini (ou abandonné), déplace la ligne dans "Terminé
   récemment" avec un lien vers la commit/PR si possible, et nettoie de temps
   en temps les entrées trop vieilles.
4. Committe et pull souvent (idéalement à chaque session), surtout pour ce
   fichier et pour `DESIGN.md` — ce sont les deux fichiers qu'on modifie tous
   les deux, donc les divergences dessus doivent être résolues vite avant de
   diverger sur le code.

Fichiers particulièrement sensibles aux conflits (à ne pas éditer à deux en
même temps sans se prévenir) : les scènes `.tscn` (fusion textuelle mais
casse-tête à relire), `project.godot`, et tout futur fichier de format de
sauvegarde.

## En cours

_(vide pour l'instant — ajoutez une ligne quand vous démarrez quelque chose)_

| Qui | Depuis le | Sur quoi |
|-----|-----------|----------|
|     |           |          |

## À faire / idées non assignées

Repris de la feuille de route dans `DESIGN.md` — à affiner/découper en
tâches plus petites au fur et à mesure :

- [ ] Prototype voxel de base (terrain fixe, marche/saut, caméra 3e personne)
- [ ] Casser/poser des voxels + inventaire minimal
- [ ] Génération procédurale de la plateforme (seed → terrain + biomes)
- [ ] Jauges de survie (faim/soif) + cycle jour/nuit + température
- [ ] Artisanat de base (outils) + briquet + feu + tronc à brûler
- [ ] Construction d'abri (pose de blocs)
- [ ] Système de gabarits d'énigmes + chaîne d'indices (version fixe d'abord)
- [ ] Génération de la chaîne de quête + repères nommés
- [ ] Œuf : éclosion, élevage, condition de victoire
- [ ] Sauvegarde / chargement
- [ ] Répondre aux "Questions ouvertes" de `DESIGN.md`

## Terminé récemment

- 2026-09-16 — Squelette réseau initial (menu héberger/rejoindre, ENet,
  spawn de joueurs synchronisé) — à conserver, mais le contrôleur joueur et
  le monde seront réécrits pour le voxel/3e personne (voir `DESIGN.md`,
  section "Ce qui change par rapport au prototype existant").
- 2026-09-16 — Rédaction de `DESIGN.md` (concept, boucle de jeu, système de
  génération des énigmes, feuille de route).
