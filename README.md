# My PDFs

Lecteur et bibliothèque PDF personnelle pour Android (Flutter), avec son propre serveur : stockage de 200 Go, recherche plein texte, sauvegardes et recherche de livres libres en ligne.

## Fonctionnalités (version 0.3)

**Lecture**
- Défilement vertical continu, curseur à droite pour aller vite, reprise à la dernière page lue.
- Marque-pages, « aller à la page », mode nuit.
- Recherche dans le livre ouvert (loupe en haut), avec les résultats surlignés.

**Annotations**
- Sélection de texte (appui long) : copier, surligner en 4 couleurs, surligner + note.
- Notes libres par page, point orange sur les pages annotées.
- Panneau « Notes et surlignages » : relire, modifier, supprimer, tout copier en Markdown.
- Les PDF ne sont jamais modifiés : tout est enregistré à part, lié à l'empreinte SHA-256 de chaque fichier.

**Rangement**
- Catégories créées par toi (un livre peut être dans plusieurs) + filtres automatiques : En cours, Pas commencés, Terminés.
- Tri visible au-dessus de la liste : lus récemment, titre, date d'ajout, progression, nombre de pages, taille, avec ordre inverse.
- Recherche par titre (sans tenir compte des accents).

**Serveur (onglets Recherche, Découvrir, Réglages)**
- Les livres du serveur apparaissent dans la bibliothèque comme les autres ; ils se téléchargent à l'ouverture.
- Envoi sur le serveur (automatique à l'import, ou livre par livre), « Libérer de la place », épinglage, limite de place sur le téléphone.
- Recherche d'un mot dans le texte de tous les livres du serveur.
- Découvrir : livres libres sur Internet Archive, Open Library et Gallica ; « Ajouter » les télécharge sur le serveur.
- Sauvegarde automatique des catégories, notes et progression après chaque lecture, et restauration.

Limite : pas d'OCR, donc pas de texte copiable ni cherchable dans les pages scannées.

## Installation

### 1. Le serveur (sur la machine allumée 24 h/24, avec Tailscale)

```bash
git clone https://github.com/Zeid-Ibraheem/my-pdfs.git
cd my-pdfs/server
./install.sh
```

Le script affiche à la fin l'**adresse** et le **jeton** à saisir dans l'appli. Détails : [server/README.md](server/README.md).

### 2. L'appli (sur le PC, téléphone branché en USB)

Prérequis : Flutter **3.47 ou plus** (`flutter upgrade`) et le SDK Android.

```bash
cd my-pdfs
./setup.sh            # crée android/, ajoute les paquets, vérifie le code (relançable)
flutter run --release # installe et lance sur le téléphone
```

Puis dans l'appli : onglet **Réglages** > adresse + jeton > « Tester et enregistrer ». Tailscale doit être actif sur le téléphone, dans le même profil que l'appli.

## Organisation du code

```
lib/
  main.dart                    démarrage, thème clair/sombre
  data/
    book.dart                  modèle Livre, tri
    category.dart              catégories, filtres
    annotation.dart            surlignages, notes, export Markdown
    database.dart              base SQLite (version 3)
    library.dart               fichiers, import, serveur, cache, sauvegarde
    server_api.dart            client HTTP du serveur
  ui/
    home_screen.dart           onglets du bas
    library_screen.dart        bibliothèque
    reader_screen.dart         lecteur (pdfrx)
    search_screen.dart         recherche plein texte
    discover_screen.dart       livres libres en ligne
    settings_screen.dart       réglages
    book_tile.dart, annotation_widgets.dart, common.dart
  util/text.dart               titres, accents, tailles, dates
server/                        serveur Python (Starlette), tests, install.sh
test/                          tests de l'appli
```

## Dépannage

| Problème | Solution |
| --- | --- |
| `pdfrx requires Flutter >= 3.47` | `flutter upgrade` puis `./setup.sh` |
| « Serveur injoignable » | Tailscale activé sur le téléphone ? Serveur allumé ? `systemctl status my-pdfs` sur le serveur |
| « Jeton refusé » | Recopie le jeton : `sed -n 's/^MYPDFS_TOKEN=//p' ~/my-pdfs-data/server.env` |
| Erreur de compilation native (NDK) | Android Studio > SDK Manager > SDK Tools > NDK |
| `minSdkVersion` trop bas | `android/app/build.gradle.kts` : `minSdk = 24` |
