# Architecture de My PDFs

## Vue d'ensemble

```
Téléphone (appli Flutter)                     Serveur (Python, Starlette)
┌───────────────────────────┐   Tailscale    ┌──────────────────────────────┐
│ ui/      écrans           │  (tunnel       │ app.py    routes HTTP + jeton │
│ data/    logique + SQLite │   chiffré)     │ store.py  fichiers + SQLite   │
│ config.dart  version, clés│ ─────────────► │ discover.py livres libres     │
└───────────────────────────┘    HTTP + jeton└──────────────────────────────┘
```

- Un livre est identifié partout par l'**empreinte SHA-256** de son fichier.
- Les PDF ne sont jamais modifiés : notes, surlignages, progression, catégories et carnet vivent dans la base SQLite de l'appli (`my_pdfs.db`).
- **Synchronisation** : chaque modification est un élément `(type, clé)` daté. Le serveur garde la version la plus récente et numérote les changements (`seq`). L'appli envoie ses changements et reçoit ceux faits ailleurs depuis sa dernière synchro. Détails : `lib/data/sync_item.dart`, `server/store.py` (`sync_state`).

## Faire évoluer l'appli sans rien casser

### Base de données de l'appli (`lib/data/database.dart`)
1. Augmenter `version:` dans `openDatabase`.
2. Ajouter une fonction `_createVn` et l'appeler dans `onCreate` **et** dans `onUpgrade` (`if (oldVersion < n)`).
3. Ne jamais modifier une migration déjà publiée : les téléphones l'ont déjà exécutée.

### Réglages (`lib/config.dart`, `SettingKeys`)
Ne jamais renommer une clé : les valeurs enregistrées seraient perdues.

### Synchronisation (nouveau type de données)
1. Ajouter le type dans `STATE_KINDS` (`server/store.py`) et dans le commentaire de `lib/data/sync_item.dart`.
2. Enregistrer les modifications avec `_record(...)` et les appliquer dans `_apply(...)` (`database.dart`).
3. Augmenter `API_VERSION` (`server/app.py`) et `AppInfo.minServerApi` (`lib/config.dart`) : une appli récente préviendra clairement si le serveur n'est pas à jour.

### Serveur (`server/store.py`)
Les changements de schéma passent par `MIGRATIONS` : ajouter une fonction à la fin de la liste, sans modifier les précédentes. Le numéro appliqué est gardé dans la table `meta` (`schema_version`).

### Versions
Mettre à jour `AppInfo.version` (`lib/config.dart`), `VERSION` (`server/app.py`), la ligne `version:` de `pubspec.yaml` et `CHANGELOG.md`.

## Vérifications automatiques
- `server/tests/` : tests du serveur, dont une simulation de deux profils qui se synchronisent.
- `test/` : tests de l'appli (fonctions sans interface).
- `.github/workflows/ci.yml` : à chaque push, GitHub lance les tests du serveur et `flutter analyze`.
