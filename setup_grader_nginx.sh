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

# www-data writes in lti_sessions to create tokens
sudo chown www-data:www-data /var/secure/lti_sessions/
sudo chmod 770 /var/secure/lti_sessions/

# only root edits env file , www-data only reads
sudo chown root:www-data /var/secure/aigrader.env
sudo chmod 640 /var/secure/aigrader.env

# CGI Scripts: only root edits scripts, www-data only runs them 
sudo chown root:www-data /usr/lib/cgi-bin/*.py
sudo chmod 755 /usr/lib/cgi-bin/*.py

# 5. Enable and start fcgiwrap service
echo "⚙️  Starting fcgiwrap service..."
sudo systemctl enable fcgiwrap
sudo systemctl restart fcgiwrap

echo "You must also add the cgi-bin configuration in Nginx configuration file"
echo "✨ Done! Nginx environment is now prepared and secure."
