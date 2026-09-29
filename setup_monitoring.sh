#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR_DIR="$SCRIPT_DIR/deploy/monitoring"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root, for example: sudo ./setup_monitoring.sh" >&2
    exit 1
fi

install -d -m 0755 /var/log/lti-health
install -m 0755 "$MONITOR_DIR/lti-health-sample.sh" /usr/local/sbin/lti-health-sample.sh
install -m 0755 "$MONITOR_DIR/lti-health-daily.sh" /usr/local/sbin/lti-health-daily.sh
install -m 0644 "$MONITOR_DIR/lti-health-sample.service" /etc/systemd/system/lti-health-sample.service
install -m 0644 "$MONITOR_DIR/lti-health-sample.timer" /etc/systemd/system/lti-health-sample.timer
install -m 0644 "$MONITOR_DIR/lti-health-daily.service" /etc/systemd/system/lti-health-daily.service
install -m 0644 "$MONITOR_DIR/lti-health-daily.timer" /etc/systemd/system/lti-health-daily.timer

systemctl daemon-reload
systemctl enable --now lti-health-sample.timer
systemctl enable --now lti-health-daily.timer

# Take one immediate sample so installation can be verified at once.
systemctl start lti-health-sample.service

echo
echo "LTI AI Grader monitoring installed."
echo "Samples:  /var/log/lti-health/metrics-YYYY-MM.csv"
echo "Reports:  /var/log/lti-health/report-YYYY-MM-DD.txt"
echo
echo "Timers:"
systemctl list-timers --all | grep 'lti-health' || true
