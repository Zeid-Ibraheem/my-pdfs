# Bibli

Lecteur et bibliothèque PDF personnelle pour Android, en Flutter.

## Ce que fait la version 0.1 (phase 1)

- **Import** de un ou plusieurs PDF. Chaque fichier est copié dans l'appli et identifié par son empreinte SHA-256 (un code unique calculé à partir du contenu) : un même livre importé deux fois est détecté comme doublon.
- **Bibliothèque** avec miniature de la page 1, progression, recherche par titre (sans tenir compte des accents) et tri (lus récemment, titre, date d'ajout). Appui long sur un livre pour le renommer ou le supprimer.
- **Lecture en défilement vertical continu**, avec un curseur à droite pour aller vite dans un long livre.
- **Reprise automatique** à la dernière page lue, même si Android ferme l'appli en arrière-plan.
- **Marque-pages** : icône en haut pour marquer la page en cours, liste dans le menu ⋮.
- **Copier du texte** : appui long sur un mot, ajuste la sélection, puis bouton « Copier ». Le menu ⋮ permet aussi de copier tout le texte de la page.
- **Mode nuit** (couleurs inversées) et **aller à la page n**.

Limite connue : sur un PDF scanné (pages en image), il n'y a pas de texte à copier. Il faudra l'OCR (reconnaissance de caractères), prévu plus tard.

## Installation

Prérequis : Flutter **3.47 ou plus** (`flutter upgrade`), le SDK Android, et le téléphone en mode débogage USB.

```bash
cd bibli
chmod +x setup.sh
./setup.sh            # une seule fois : crée android/, ajoute les paquets, vérifie le code
flutter run --release # installe et lance sur le téléphone branché
```

`--release` rend le défilement bien plus fluide que le mode debug. Pour développer avec le rechargement à chaud, utilise `flutter run` sans option.

Pour installer l'appli dans un seul profil du téléphone : `adb shell pm list users`, puis `flutter run --release --device-user <ID>`.

## Organisation du code

```
lib/
  main.dart                 démarrage, thème clair/sombre
  data/book.dart            modèle Livre + ordres de tri
  data/database.dart        base SQLite : livres, marque-pages, réglages
  data/library.dart         import (copie + empreinte), suppression
  ui/library_screen.dart    écran Bibliothèque
  ui/book_tile.dart         une ligne de la liste (miniature, progression)
  ui/reader_screen.dart     lecteur (pdfrx), marque-pages, copie, mode nuit
  util/text.dart            titres, recherche sans accents, tailles
test/text_test.dart         tests des fonctions de texte
```

Choix importants :

- Les PDF ne sont jamais modifiés. Marque-pages et progression vivent dans la base `bibli.db`, liés à l'empreinte du fichier.
- La base ne stocke que le nom du fichier (`<empreinte>.pdf`), pas son chemin complet, qui peut changer d'un profil Android à l'autre.

## Feuille de route

1. ~~Lecteur local~~ (cette version)
2. Catégories (manuelles et automatiques) et notes par page
3. Stockage sur le serveur debi (200 Go) et cache local
4. Sauvegarde de `bibli.db` sur debi
5. Recherche plein texte (OCR plus tard)
6. Recherche de livres libres en ligne (Internet Archive, Open Library, Gallica)

## Dépannage

| Erreur | Solution |
| --- | --- |
| `pdfrx requires Flutter >= 3.47` ou échec de `pub add` | `flutter upgrade` puis relancer `./setup.sh` |
| Erreur de compilation native (NDK, CMake) | Installer le NDK depuis Android Studio > SDK Manager > SDK Tools |
| `minSdkVersion` trop bas | Dans `android/app/build.gradle.kts`, mettre `minSdk = 24` |
| Avertissements sur `package:flutter/material.dart` | Normal : l'appli utilise déjà `material_ui`, le nouveau paquet Material |
