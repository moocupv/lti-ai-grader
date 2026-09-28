#!/bin/bash
set -euo pipefail

# =================================================================
# SYSTEM PREPARATION SCRIPT: NGINX + FCGIWRAP
# =================================================================
# Architecture installed by this script:
#   - 16 fcgiwrap workers on /run/fcgiwrap.socket for AI evaluators
#   - 5 dedicated fcgiwrap workers on /run/fcgiwrap-receiver.socket
#     for lti-receiver.py
#
# The split prevents long-running LLM calls from exhausting all FastCGI
# workers and blocking subsequent LTI launches.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CGI_DIR="/usr/lib/cgi-bin"
SECURE_DIR="/var/secure"
SESSION_DIR="$SECURE_DIR/lti_sessions"
WEB_USER="www-data"

MAIN_WORKERS=16
RECEIVER_WORKERS=5

echo "Installing CGI dependencies for Nginx..."
sudo apt-get update
sudo apt-get install -y fcgiwrap

echo "Creating security directories in $SECURE_DIR..."
sudo mkdir -p "$SESSION_DIR" "$CGI_DIR"

# Move a legacy .env file if present. Current deployments normally use
# /var/secure/aigrader.env.
if [ -f "$CGI_DIR/.env" ]; then
    echo "Moving detected .env file to secure zone..."
    sudo mv "$CGI_DIR/.env" "$SECURE_DIR/.env"
fi

if [ ! -f "$SECURE_DIR/aigrader.env" ]; then
    echo "WARNING: $SECURE_DIR/aigrader.env was not found."
    echo "Create it with the required API keys and LTI secrets before grading."
fi

echo "Setting permissions for user $WEB_USER..."
sudo chown www-data:www-data "$SESSION_DIR"
sudo chmod 770 "$SESSION_DIR"

if [ -f "$SECURE_DIR/aigrader.env" ]; then
    sudo chown root:www-data "$SECURE_DIR/aigrader.env"
    sudo chmod 640 "$SECURE_DIR/aigrader.env"
fi

if compgen -G "$CGI_DIR/*.py" >/dev/null; then
    sudo chown root:www-data "$CGI_DIR"/*.py
    sudo chmod 755 "$CGI_DIR"/*.py
fi

# Configure the standard fcgiwrap service with 16 workers. A systemd drop-in
# is used instead of /etc/default/fcgiwrap because not all distributions ship
# that file and argument expansion differs between package versions.
echo "Configuring main fcgiwrap pool with $MAIN_WORKERS workers..."
sudo mkdir -p /etc/systemd/system/fcgiwrap.service.d
sudo tee /etc/systemd/system/fcgiwrap.service.d/override.conf >/dev/null <<EOF_MAIN
[Service]
ExecStart=
ExecStart=/usr/sbin/fcgiwrap -f -c $MAIN_WORKERS
EOF_MAIN

# Install the dedicated LTI receiver socket/service.
echo "Configuring dedicated LTI receiver pool with $RECEIVER_WORKERS workers..."
sudo install -m 0644 "$SCRIPT_DIR/deploy/systemd/fcgiwrap-receiver.socket" /etc/systemd/system/fcgiwrap-receiver.socket
sudo install -m 0644 "$SCRIPT_DIR/deploy/systemd/fcgiwrap-receiver.service" /etc/systemd/system/fcgiwrap-receiver.service

sudo systemctl daemon-reload
sudo systemctl enable fcgiwrap.socket >/dev/null 2>&1 || true
sudo systemctl restart fcgiwrap.service
sudo systemctl enable --now fcgiwrap-receiver.socket

echo
echo "FastCGI pools configured."
echo "  Evaluators:   $MAIN_WORKERS workers -> /run/fcgiwrap.socket"
echo "  LTI receiver: $RECEIVER_WORKERS workers -> /run/fcgiwrap-receiver.socket"
echo
echo "Add the Nginx configuration from:"
echo "  $SCRIPT_DIR/deploy/nginx/lti-ai-grader-cgi.conf"
echo "to the HTTPS server configuration, then run:"
echo "  sudo nginx -t && sudo systemctl reload nginx"
echo
echo "Verification commands:"
echo "  pgrep -a fcgiwrap"
echo "  ss -xl | grep fcgiwrap"
echo "  systemctl status fcgiwrap-receiver.socket --no-pager"
echo "  systemctl status fcgiwrap-receiver.service --no-pager"
