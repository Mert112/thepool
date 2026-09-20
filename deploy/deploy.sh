#!/usr/bin/env bash
# Build the web app and publish it. Run from the repo root on the server:
#   bash deploy/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/../web"
npm ci --no-audit --no-fund
npm run build
rsync -a --delete dist/ /var/www/thepool/ 2>/dev/null || { rm -rf /var/www/thepool/* && cp -r dist/. /var/www/thepool/; }
sudo systemctl reload caddy
echo "Deployed. https://thepool.today"
