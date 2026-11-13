# Historique des versions

## 0.8.0
- Réglages > « Tout rapatrier et vider le serveur » : télécharge sur le téléphone tous les livres absents, puis supprime absolument tout sur le serveur (livres, titres, texte, couvertures, état synchronisé, sauvegardes, configuration et jeton) et l'arrête. Rien n'est supprimé si un téléchargement échoue.
- `server/uninstall.sh` : désinstalle complètement le serveur (service, environnement Python, données).

## 0.7.0
- Version, clés de réglages et compatibilité appli ↔ serveur centralisées (`lib/config.dart`) ; l'appli prévient clairement si le serveur est trop ancien.
- Serveur : migrations de schéma numérotées, SQLite en mode WAL, vérifications automatiques sur GitHub (CI).
- Carte « Reprendre la lecture », mode plein écran dans le lecteur, temps de lecture.

## 0.6.0
- Carnet de lectures : livres lus / en cours / à lire, note sur 5, avis, statistiques ; livres importés ajoutés automatiquement.

## 0.5.1
- Bouton « Tout effacer définitivement » (téléphone + serveur, livres au choix).

## 0.5.0
- Synchronisation entre profils (page, marque-pages, notes, surlignages, catégories, titres).
- Couvertures en cache ; correction des pages blanches dans le lecteur.

## 0.4.x
- Lecture directe depuis le serveur, sans téléchargement ; import local par défaut.

## 0.3.0
- Serveur : stockage 200 Go, recherche plein texte, sauvegardes, livres libres en ligne.

## 0.2.0
- Catégories, surlignages, notes.

## 0.1.0
- Lecteur : défilement vertical, reprise de lecture, marque-pages, copie du texte.
