#!/usr/bin/env bash
# One-time server setup for The Pool on Ubuntu/Debian. Run as a user with sudo:
#   bash deploy/setup-server.sh
# Afterwards, every deploy is just: bash deploy/deploy.sh
set -euo pipefail

# Node 20 (for building the app) and Caddy (web server with automatic HTTPS)
if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
if ! command -v caddy >/dev/null; then
  sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
  sudo apt-get update && sudo apt-get install -y caddy
fi

sudo mkdir -p /var/www/thepool
sudo chown "$USER" /var/www/thepool
sudo cp "$(dirname "$0")/Caddyfile" /etc/caddy/Caddyfile
sudo systemctl enable caddy
echo "Server ready. Now run: bash deploy/deploy.sh"
