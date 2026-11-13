#!/usr/bin/env bash
# Désinstalle complètement le serveur My PDFs : arrête et supprime le service,
# l'environnement Python et le dossier de données (s'il en reste).
# À lancer après « Tout rapatrier et vider le serveur » dans l'appli.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
DATA="${MYPDFS_DATA:-$HOME/my-pdfs-data}"

sudo systemctl disable --now my-pdfs 2>/dev/null || true
sudo rm -f /etc/systemd/system/my-pdfs.service
sudo systemctl daemon-reload
rm -rf "$DIR/.venv" "$DATA"
echo "Serveur My PDFs désinstallé (service, environnement Python et $DATA)."
echo "Le code reste dans $(dirname "$DIR") : supprime-le avec rm -rf si tu n'en veux plus."
