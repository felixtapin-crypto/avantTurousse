# Avant Tourousse

Jeu 3D multijoueur (2 joueurs pour l'instant), fait avec [Godot 4](https://godotengine.org/).

## Prérequis

- [Godot 4.3 ou plus récent](https://godotengine.org/download) (version "Standard", pas besoin de .NET).

## Lancer le projet

1. Ouvrir Godot, cliquer sur "Importer", sélectionner le fichier `project.godot` de ce dossier.
2. Appuyer sur F5 (ou le bouton ▶ en haut à droite) pour lancer le jeu.

## Contrôles

- **Z/Q/S/D** (physiquement les touches W/A/S/D, donc affichées différemment sur un clavier AZERTY) : se déplacer.
- **Souris** : regarder autour de soi (vue à la 3e personne).
- **Espace** : sauter.
- **Clic gauche** : creuser (baisse le terrain visé d'1m, donne un bloc).
- **Clic droit** : construire (monte le terrain visé d'1m, coûte un bloc).
- **Échap** : libérer la souris (re-cliquer dans la fenêtre pour la recapturer).

## Tester en multijoueur en local (sur une seule machine)

1. Dans Godot, ouvrir "Debug" > "Instances multiples" (ou `Débogage > Lancer plusieurs instances`) et choisir "Lancer 2 instances".
2. Dans la première fenêtre : cliquer sur **Héberger une partie**.
3. Dans la deuxième fenêtre : laisser `127.0.0.1` dans le champ d'adresse et cliquer sur **Rejoindre une partie**.

Les deux joueurs devraient apparaître dans le même monde 3D.

## Jouer à deux, chacun chez soi

Le réseau utilise une connexion directe (un des deux joueurs héberge, l'autre le rejoint par IP), sans serveur dédié. Pour que ça marche entre deux maisons différentes, la solution retenue pour l'instant est un VPN léger :

**[Tailscale](https://tailscale.com/download)** — chaque joueur l'installe et se connecte avec le même compte (ou s'invite mutuellement dans le même "tailnet" via [l'admin console](https://tailscale.com/admin)). Une fois connecté, `tailscale status` donne une IP `100.x.x.x` par machine. L'hôte clique **Héberger une partie**, l'autre saisit l'IP Tailscale de l'hôte dans le champ adresse et clique **Rejoindre une partie**. Aucune configuration de routeur, et ça évite les soucis de CGNAT (fréquent chez les FAI) qui bloquent souvent la redirection de port classique.

Alternatives pour plus tard si besoin : redirection de port manuelle (ouvrir le port UDP `7777` sur la box de l'hôte), ou un serveur dédié loué (VPS) si le jeu grandit au-delà de 2 joueurs.

## Chat vocal

Pas de chat vocal intégré au jeu pour l'instant — utilisez un appel Discord (ou équivalent) en parallèle. Un vrai chat vocal en jeu est noté comme tâche future dans `TASKS.md` si on veut le construire proprement plus tard.

## Structure du projet

```
autoload/
  input_setup.gd   # définit les touches (déplacement, saut) en code
  network.gd        # gère la connexion réseau (héberger/rejoindre)
scenes/
  main_menu/        # écran titre (héberger / rejoindre)
  world/            # le monde 3D, fait apparaître les joueurs
  player/           # le personnage jouable (déplacement, caméra, réseau)
```

## Prochaines étapes possibles

- Ajouter un vrai modèle 3D pour le personnage (pour l'instant c'est une capsule).
- Ajouter du gameplay (objectif, interactions, autre chose selon l'idée de jeu).
- Ajouter un nom de joueur affiché au-dessus de chaque personnage.
- Choisir une solution d'hébergement si vous voulez jouer à distance régulièrement.
