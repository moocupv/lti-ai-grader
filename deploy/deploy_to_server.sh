#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HTML_DST="/usr/share/nginx/html"
CGI_DST="/usr/lib/cgi-bin"
MON_BIN_DST="/usr/local/sbin"
SYSTEMD_DST="/etc/systemd/system"
LTI_HEALTH_ETC="/etc/lti-health"

log() {
    printf '\n==> %s\n' "$*"
}

copy_if_exists() {
    local src="$1"
    local dst="$2"
    local mode="$3"
    local owner="${4:-root}"
    local group="${5:-root}"

    if [ -f "$src" ]; then
        printf '  %-55s -> %s\n' "${src#$REPO_DIR/}" "$dst"
        install -o "$owner" -g "$group" -m "$mode" "$src" "$dst"
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this script with sudo/root." >&2
    exit 1
fi

for dir in "$HTML_DST" "$CGI_DST" "$MON_BIN_DST" "$SYSTEMD_DST"; do
    if [ ! -d "$dir" ]; then
        echo "ERROR: required destination directory does not exist: $dir" >&2
        exit 1
    fi
done

log "Deploying static web files to $HTML_DST"
shopt -s nullglob
for src in "$REPO_DIR"/*.html "$REPO_DIR"/*.js "$REPO_DIR"/*.css; do
    copy_if_exists "$src" "$HTML_DST/$(basename "$src")" 0644 root www-data
done

log "Deploying CGI application files to $CGI_DST"
copy_if_exists "$REPO_DIR/aigrader.py" "$CGI_DST/aigrader.py" 0755 root www-data
copy_if_exists "$REPO_DIR/lti-receiver.py" "$CGI_DST/lti-receiver.py" 0755 root www-data

for src in "$REPO_DIR"/evaluate-*.py; do
    copy_if_exists "$src" "$CGI_DST/$(basename "$src")" 0755 root www-data
done

for src in "$REPO_DIR"/*-conf.json; do
    copy_if_exists "$src" "$CGI_DST/$(basename "$src")" 0640 root www-data
done

MON_SRC="$REPO_DIR/deploy/monitoring"
if [ -d "$MON_SRC" ]; then
    log "Deploying monitoring scripts to $MON_BIN_DST"
    for src in "$MON_SRC"/*.sh "$MON_SRC"/*.py; do
        copy_if_exists "$src" "$MON_BIN_DST/$(basename "$src")" 0755 root root
    done

    log "Deploying monitoring systemd units"
    for src in "$MON_SRC"/*.service "$MON_SRC"/*.timer; do
        copy_if_exists "$src" "$SYSTEMD_DST/$(basename "$src")" 0644 root root
    done

    if [ -f "$MON_SRC/mail.env.example" ]; then
        mkdir -p "$LTI_HEALTH_ETC"
        chmod 0755 "$LTI_HEALTH_ETC"
        copy_if_exists "$MON_SRC/mail.env.example" \
            "$LTI_HEALTH_ETC/mail.env.example" 0644 root root

        if [ ! -f "$LTI_HEALTH_ETC/mail.env" ]; then
            echo "  Creating initial $LTI_HEALTH_ETC/mail.env (edit before enabling email)."
            install -o root -g root -m 0600 \
                "$MON_SRC/mail.env.example" "$LTI_HEALTH_ETC/mail.env"
        else
            echo "  Keeping existing $LTI_HEALTH_ETC/mail.env (credentials are never overwritten)."
        fi
    fi
fi

SYSTEMD_SRC="$REPO_DIR/deploy/systemd"
if [ -d "$SYSTEMD_SRC" ]; then
    log "Deploying fcgiwrap systemd units"
    for src in "$SYSTEMD_SRC"/*.service "$SYSTEMD_SRC"/*.socket; do
        copy_if_exists "$src" "$SYSTEMD_DST/$(basename "$src")" 0644 root root
    done
fi

log "Reloading systemd"
systemctl daemon-reload

# Enable/update monitoring timers that are present in the deployed tree.
for timer in \
    lti-health-sample.timer \
    lti-health-daily.timer \
    lti-health-weekly.timer \
    lti-health-watchdog.timer
do
    if [ -f "$SYSTEMD_DST/$timer" ]; then
        systemctl enable --now "$timer"
        systemctl restart "$timer"
    fi
done

# Keep the dedicated receiver socket enabled if its unit is present.
if [ -f "$SYSTEMD_DST/fcgiwrap-receiver.socket" ]; then
    systemctl enable --now fcgiwrap-receiver.socket
fi

log "Validating Nginx configuration"
if command -v nginx >/dev/null 2>&1; then
    nginx -t
else
    echo "  nginx command not found; skipping nginx -t."
fi

log "Deployment summary"
echo "Repository:       $REPO_DIR"
echo "Static files:     $HTML_DST"
echo "CGI files:        $CGI_DST"
echo "Monitoring tools: $MON_BIN_DST"
echo "Systemd units:    $SYSTEMD_DST"

echo
if systemctl list-timers --all --no-pager 2>/dev/null | grep -q 'lti-health'; then
    systemctl list-timers --all --no-pager | grep 'lti-health' || true
else
    echo "No lti-health timers are currently installed."
fi

echo
echo "Deployment completed successfully."
