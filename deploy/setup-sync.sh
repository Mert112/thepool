#!/usr/bin/env bash
# Install the ESPN sync as a systemd timer. Needs sync/.env with SUPABASE_URL and SUPABASE_SERVICE_KEY
# (a secret key from Supabase → Settings → API keys). Run from the repo root: bash deploy/setup-sync.sh
set -euo pipefail
cd "$(dirname "$0")/.."
test -f sync/.env || { echo "sync/.env is missing (SUPABASE_URL, SUPABASE_SERVICE_KEY)"; exit 1; }
chmod 600 sync/.env
(cd sync && npm ci --no-audit --no-fund)
sudo cp deploy/thepool-sync.service deploy/thepool-sync.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now thepool-sync.timer
echo "Sync running. Logs: journalctl -u thepool-sync -f"
