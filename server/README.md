# Serveur My PDFs

Petit serveur HTTP (Python, Starlette) qui stocke les PDF de l'appli, extrait leur texte pour la recherche, garde les sauvegardes de la base de l'appli et cherche des livres libres en ligne.

## Sécurité

- Il écoute **uniquement sur l'adresse Tailscale** de la machine : il n'est jamais joignable depuis Internet ni depuis le réseau local.
- Chaque requête doit porter un **jeton secret** de 43 caractères, généré à l'installation et stocké dans `server.env` (lisible seulement par ton utilisateur).
- Le trafic entre le téléphone et le serveur passe dans le tunnel chiffré de Tailscale (WireGuard), d'où le HTTP simple.

## Installation (Debian)

```bash
git clone https://github.com/Zeid-Ibraheem/my-pdfs.git
cd my-pdfs/server
./install.sh
```

Le script installe les dépendances dans `.venv`, lance les tests, crée le service `my-pdfs` (démarrage automatique) et affiche **l'adresse et le jeton à saisir dans l'appli** (onglet Réglages).

Options : `MYPDFS_QUOTA_GB=200` (quota), `MYPDFS_DATA=~/my-pdfs-data` (dossier des livres), `MYPDFS_PORT=8765`.

## Au quotidien

| Besoin | Commande |
| --- | --- |
| État du service | `systemctl status my-pdfs` |
| Journal | `journalctl -u my-pdfs -n 50` |
| Mise à jour | `git pull && ./install.sh` |
| Revoir le jeton | `sed -n 's/^MYPDFS_TOKEN=//p' ~/my-pdfs-data/server.env` |

## Dossier de données

```
~/my-pdfs-data/
  books/<empreinte>.pdf          les livres (nommés par leur empreinte SHA-256)
  catalog.db                     catalogue + index de recherche plein texte
  backups/my_pdfs-AAAA-MM-JJ.db  base de l'appli, 1 par jour, 7 derniers jours
  server.env                     jeton et réglages
```

Conseil : copie ce dossier sur un autre disque de temps en temps (`rsync -a ~/my-pdfs-data/ <destination>/`). Un seul disque, c'est un seul point de panne.

## API

Toutes les routes sauf `/api/health` exigent `Authorization: Bearer <jeton>`.

| Méthode | Route | Rôle |
| --- | --- | --- |
| GET | `/api/health` | vérifier que le serveur répond |
| GET | `/api/usage` | place utilisée, quota, nombre de livres |
| GET | `/api/books` | liste des livres |
| PUT | `/api/books/{empreinte}?title=…` | envoyer un PDF (vérifié par son empreinte) |
| GET | `/api/books/{empreinte}/file` | télécharger un PDF |
| PATCH | `/api/books/{empreinte}` | renommer (`{"title": "…"}`) |
| DELETE | `/api/books/{empreinte}` | supprimer |
| GET | `/api/search?q=…` | recherche plein texte dans tous les livres |
| PUT | `/api/backup` | envoyer une sauvegarde de la base de l'appli |
| GET | `/api/backups` · `/api/backup/latest` | lister / récupérer les sauvegardes |
| GET | `/api/discover?q=…` | chercher des livres libres (Internet Archive, Open Library, Gallica) |
| POST | `/api/discover/import` | ajouter un livre libre d'Internet Archive |

## Limites

- **Pas d'OCR** : le texte des pages scannées (images) n'est pas extrait, donc pas cherchable.
- **Livres en ligne** : seuls les fichiers en accès libre sont téléchargés. Les livres « empruntables » d'Internet Archive sont protégés contre la copie : l'appli affiche seulement un lien. Gallica est proposée en lien, sans import automatique.

Tests : `.venv/bin/python -m unittest discover -s tests`
