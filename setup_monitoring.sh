#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR_DIR="$SCRIPT_DIR/deploy/monitoring"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root, for example: sudo ./setup_monitoring.sh" >&2
    exit 1
fi

install -d -m 0755 /var/log/lti-health
install -d -m 0755 /var/lib/lti-health
install -d -m 0755 /etc/lti-health

for script in \
    lti-health-sample.sh \
    lti-health-daily.sh \
    lti-health-weekly.sh \
    lti-health-watchdog.sh \
    lti-health-log-stats.py \
    lti-health-send-mail.py; do
    install -m 0755 "$MONITOR_DIR/$script" "/usr/local/sbin/$script"
done

for unit in \
    lti-health-sample.service \
    lti-health-sample.timer \
    lti-health-daily.service \
    lti-health-daily.timer \
    lti-health-weekly.service \
    lti-health-weekly.timer \
    lti-health-watchdog.service \
    lti-health-watchdog.timer; do
    install -m 0644 "$MONITOR_DIR/$unit" "/etc/systemd/system/$unit"
done

if [ ! -e /etc/lti-health/mail.env ]; then
    install -m 0600 "$MONITOR_DIR/mail.env.example" /etc/lti-health/mail.env.example
    echo "Email is not configured yet."
    echo "Copy /etc/lti-health/mail.env.example to /etc/lti-health/mail.env and edit it."
else
    chmod 0600 /etc/lti-health/mail.env
fi

systemctl daemon-reload
systemctl enable --now lti-health-sample.timer
systemctl enable --now lti-health-daily.timer
systemctl enable --now lti-health-weekly.timer
systemctl enable --now lti-health-watchdog.timer

# Take one immediate sample and watchdog pass so installation can be verified at once.
systemctl start lti-health-sample.service
systemctl start lti-health-watchdog.service

echo
echo "LTI AI Grader monitoring installed."
echo "Samples:        /var/log/lti-health/metrics-YYYY-MM.csv"
echo "Daily reports:  /var/log/lti-health/report-YYYY-MM-DD.txt"
echo "Weekly reports: /var/log/lti-health/weekly-YYYY-Www.txt"
echo
echo "Timers:"
systemctl list-timers --all | grep 'lti-health' || true
