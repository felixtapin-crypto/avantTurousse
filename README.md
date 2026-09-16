# Avant Tourousse

Jeu 3D multijoueur (2 joueurs pour l'instant), fait avec [Godot 4](https://godotengine.org/).

## Prérequis

- [Godot 4.3 ou plus récent](https://godotengine.org/download) (version "Standard", pas besoin de .NET).

## Lancer le projet

1. Ouvrir Godot, cliquer sur "Importer", sélectionner le fichier `project.godot` de ce dossier.
2. Appuyer sur F5 (ou le bouton ▶ en haut à droite) pour lancer le jeu.

## Contrôles

- **Z/Q/S/D** (physiquement les touches W/A/S/D, donc affichées différemment sur un clavier AZERTY) : se déplacer.
- **Souris** : regarder autour de soi.
- **Espace** : sauter.
- **Échap** : libérer la souris (re-cliquer dans la fenêtre pour la recapturer).

## Tester en multijoueur en local (sur une seule machine)

1. Dans Godot, ouvrir "Debug" > "Instances multiples" (ou `Débogage > Lancer plusieurs instances`) et choisir "Lancer 2 instances".
2. Dans la première fenêtre : cliquer sur **Héberger une partie**.
3. Dans la deuxième fenêtre : laisser `127.0.0.1` dans le champ d'adresse et cliquer sur **Rejoindre une partie**.

Les deux joueurs devraient apparaître dans le même monde 3D.

## Jouer à deux, chacun chez soi

Pour l'instant le réseau utilise une connexion directe (un des deux joueurs héberge, l'autre le rejoint par IP), sans serveur dédié. Pour que ça marche entre deux maisons différentes, il faut une des solutions suivantes (pas encore mise en place, à voir ensemble selon ce qui vous convient) :

- **Redirection de port (port forwarding)** : celui qui héberge ouvre le port UDP `7777` sur sa box/routeur vers sa machine, et donne son IP publique à l'autre joueur.
- **VPN léger type [Tailscale](https://tailscale.com/) ou Radmin VPN** : les deux machines rejoignent le même réseau virtuel, et on se connecte à l'IP donnée par le VPN. Plus simple à mettre en place que le port forwarding, pas besoin de toucher à la box.
- **Serveur dédié loué** (VPS) : plus tard, si le jeu grandit au-delà de 2 joueurs ou si vous voulez une partie toujours disponible.

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
