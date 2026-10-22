#!/usr/bin/env bash
# Installe le serveur My PDFs comme service systemd (à lancer sur le serveur,
# avec ton utilisateur habituel : le script demande sudo quand il en a besoin).
#
# Variables facultatives : MYPDFS_DATA (dossier des livres), MYPDFS_QUOTA_GB
# (200 par défaut), MYPDFS_PORT (8765 par défaut).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DATA="${MYPDFS_DATA:-$HOME/my-pdfs-data}"
QUOTA="${MYPDFS_QUOTA_GB:-200}"
PORT="${MYPDFS_PORT:-8765}"
ENV_FILE="$DATA/server.env"

echo "== Paquets système =="
sudo apt-get install -y python3-venv >/dev/null

echo "== Environnement Python (dans $DIR/.venv) =="
python3 -m venv "$DIR/.venv"
"$DIR/.venv/bin/pip" install -q --upgrade pip
"$DIR/.venv/bin/pip" install -q -r "$DIR/requirements.txt"

echo "== Tests =="
(cd "$DIR" && "$DIR/.venv/bin/python" -m unittest discover -s tests 2>&1 | tail -3)

echo "== Dossier de données : $DATA =="
mkdir -p "$DATA"
if [ ! -f "$ENV_FILE" ]; then
  TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  printf 'MYPDFS_TOKEN=%s\nMYPDFS_DATA=%s\nMYPDFS_QUOTA_GB=%s\n' \
    "$TOKEN" "$DATA" "$QUOTA" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Jeton secret créé dans $ENV_FILE"
fi

HOST="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
if [ -z "$HOST" ]; then
  echo "!! Tailscale introuvable : le serveur écoutera sur toutes les interfaces."
  HOST="0.0.0.0"
fi

echo "== Service systemd my-pdfs (écoute sur $HOST:$PORT) =="
sudo tee /etc/systemd/system/my-pdfs.service >/dev/null <<UNIT
[Unit]
Description=My PDFs - serveur de bibliothèque PDF
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
User=$USER
EnvironmentFile=$ENV_FILE
WorkingDirectory=$DIR
ExecStart=$DIR/.venv/bin/uvicorn --factory app:create_app --host $HOST --port $PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now my-pdfs
sudo systemctl restart my-pdfs
sleep 2

if curl -fsS "http://$HOST:$PORT/api/health" >/dev/null; then
  echo "Serveur en marche."
else
  echo "!! Le serveur ne répond pas : journalctl -u my-pdfs -n 50"
fi

DNS_NAME="$(tailscale status --json 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' \
  2>/dev/null || true)"

echo
echo "À saisir dans l'appli (onglet Réglages) :"
echo "  Adresse : http://$HOST:$PORT"
[ -n "$DNS_NAME" ] && echo "            (ou http://$DNS_NAME:$PORT)"
echo "  Jeton   : $(sed -n 's/^MYPDFS_TOKEN=//p' "$ENV_FILE")"
