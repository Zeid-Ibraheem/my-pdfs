"""Réglages du serveur, lus dans les variables d'environnement.

Le script install.sh les écrit dans un fichier server.env (droits 600)
que le service systemd charge au démarrage.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    quota_bytes: int
    token: str
    keep_backups: int = 7


def load_settings() -> Settings:
    data_dir = Path(
        os.environ.get("MYPDFS_DATA", str(Path.home() / "my-pdfs-data"))
    ).expanduser()
    quota_gb = float(os.environ.get("MYPDFS_QUOTA_GB", "200"))
    token = os.environ.get("MYPDFS_TOKEN", "")
    if len(token) < 16:
        raise RuntimeError(
            "MYPDFS_TOKEN manquant ou trop court (16 caractères minimum). "
            "Lance install.sh pour en générer un."
        )
    keep = int(os.environ.get("MYPDFS_KEEP_BACKUPS", "7"))
    return Settings(
        data_dir=data_dir,
        quota_bytes=int(quota_gb * 1024**3),
        token=token,
        keep_backups=keep,
    )
