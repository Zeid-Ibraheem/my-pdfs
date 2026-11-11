# Fonctionnalités en détail

[← Retour au README](../README.md)

## Version 0.7

**Lecture**
- Défilement vertical continu, curseur à droite pour aller vite, reprise à la dernière page lue.
- Marque-pages, « aller à la page », mode nuit, mode plein écran.
- Carte « Reprendre la lecture » en haut de la bibliothèque ; temps de lecture par livre.
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
- Import avec le bouton « Importer ». Les livres importés restent sur le téléphone ; le bouton nuage de chaque livre les envoie sur le serveur.

**Carnet de lectures (onglet Lectures)**
- Livres lus, en cours ou à lire, avec note sur 5, avis et date de fin ; statistiques (lus cette année, note moyenne).
- Les livres importés y entrent tout seuls et changent de statut d'eux-mêmes (ouvert → En cours, dernière page → Lu) ; les livres papier ou lus ailleurs s'ajoutent à la main.
- Synchronisé entre profils ; supprimer un PDF garde son entrée dans le carnet.

**Serveur (onglets Recherche, Découvrir, Réglages)**
- Les livres du serveur apparaissent dans la bibliothèque comme les autres et **se lisent directement depuis le serveur**, sans être enregistrés sur le téléphone : seules les pages affichées sont transférées (requêtes HTTP partielles).
- « Télécharger sur le téléphone » pour lire hors connexion, « Libérer de la place », épinglage, limite de place sur le téléphone.
- Recherche d'un mot dans le texte de tous les livres du serveur.
- Découvrir : livres libres sur Internet Archive, Open Library et Gallica ; « Ajouter » les télécharge sur le serveur.
- Sauvegarde automatique des catégories, notes et progression après chaque lecture, et restauration.
- **Synchronisation entre profils ou appareils** : page en cours, marque-pages, surlignages, notes, catégories et titres sont partagés via le serveur, élément par élément (la modification la plus récente gagne). Synchro au lancement, au retour dans l'appli, à l'ouverture et à la fermeture d'un livre.
- Couvertures créées une seule fois en images (par le téléphone, ou par le serveur avec `pdftoppm` pour les livres qui n'y sont que sur le serveur).

Limite : pas d'OCR, donc pas de texte copiable ni cherchable dans les pages scannées.

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
