#!/bin/bash

# =================================================================
# 🛡️ SYSTEM PREPARATION SCRIPT: LTI-AI-GRADER (ENHANCED SECURITY)
# =================================================================

# 1. Path definitions
CGI_DIR="/usr/lib/cgi-bin"         # Standard CGI directory
SECURE_DIR="/var/secure"           # Private folder (outside web root)
SESSION_DIR="$SECURE_DIR/lti_sessions"
WEB_USER="www-data"                # Default Apache user on Debian/Ubuntu

echo "🚀 Starting system environment setup for Apache..."

# 2. Create private directory structure
echo "📂 Creating security directories in $SECURE_DIR..."
sudo mkdir -p "$SESSION_DIR"

# 3. Handle the .env file
# If the file exists in the cgi-bin, we move it to the secure zone.
if [ -f "$CGI_DIR/.env" ]; then
    echo "📦 Moving detected .env file to secure zone..."
    sudo mv "$CGI_DIR/.env" "$SECURE_DIR/.env"
elif [ ! -f "$SECURE_DIR/.env" ]; then
    echo "⚠️  WARNING: .env file not found."
    echo "Remember to manually create it at $SECURE_DIR/.env with your credentials."
fi

# 4. Set ownership and strict permissions
echo "🔑 Setting permissions for user: $WEB_USER..."

# Secure folder and .env file
sudo chown -R $WEB_USER:$WEB_USER "$SECURE_DIR"
sudo chmod 700 "$SECURE_DIR"               # Only www-data can access /var/secure
sudo chmod 600 "$SECURE_DIR/.env"          # Only www-data can read the .env file
sudo chmod -R 770 "$SESSION_DIR"           # Read/Write for the web server group

# CGI Scripts
echo "📜 Ensuring execution rights for scripts in $CGI_DIR..."
sudo chown $WEB_USER:$WEB_USER "$CGI_DIR"/*.py
sudo chmod +x "$CGI_DIR"/*.py

# 5. Enable Apache CGI modules
echo "⚙️ Verifying Apache modules..."
sudo a2enmod cgi
sudo systemctl restart apache2

echo "✨ Done! The system is now robust and secure."
