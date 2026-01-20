#!/bin/bash

# =================================================================
# 🛡️ SYSTEM PREPARATION SCRIPT: NGINX + FCGIWRAP (ENHANCED SECURITY)
# =================================================================

# 1. Path definitions
CGI_DIR="/usr/lib/cgi-bin"         # Standard CGI directory
SECURE_DIR="/var/secure"           # Private folder (outside web root)
SESSION_DIR="$SECURE_DIR/lti_sessions"
WEB_USER="www-data"                # Default Nginx/Web user

echo "⚙️  Installing CGI dependencies for Nginx..."
sudo apt-get update
sudo apt-get install -y fcgiwrap

# 2. Create private directory structure
echo "📂 Creating security directories in $SECURE_DIR..."
sudo mkdir -p "$SESSION_DIR"
sudo mkdir -p "$CGI_DIR"

# 3. Handle the .env file
# Moves the .env from the CGI folder to the restricted zone if present
if [ -f "$CGI_DIR/.env" ]; then
    echo "📦 Moving detected .env file to secure zone..."
    sudo mv "$CGI_DIR/.env" "$SECURE_DIR/.env"
elif [ ! -f "$SECURE_DIR/.env" ]; then
    echo "⚠️  WARNING: .env file not found."
    echo "Ensure you create it at $SECURE_DIR/.env with your API keys."
fi

# 4. Set ownership and strict permissions
echo "🔑 Setting permissions for user: $WEB_USER..."

# Secure folder and .env file
sudo chown -R $WEB_USER:$WEB_USER "$SECURE_DIR"
sudo chmod 700 "$SECURE_DIR"               # Only www-data can enter /var/secure
sudo chmod 600 "$SECURE_DIR/.env"          # Only www-data can read the .env file
sudo chmod -R 770 "$SESSION_DIR"           # Read/Write access for the web user

# CGI Scripts
echo "📜 Ensuring execution rights for scripts in $CGI_DIR..."
sudo chown -R $WEB_USER:$WEB_USER "$CGI_DIR"
sudo chmod +x "$CGI_DIR"/*.py

# 5. Enable and start fcgiwrap service
echo "⚙️  Starting fcgiwrap service..."
sudo systemctl enable fcgiwrap
sudo systemctl restart fcgiwrap

echo "✨ Done! Nginx environment is now prepared and secure."
