#!/bin/bash
set -u

LOG_DIR="/var/log/lti-health"
STATE_DIR="/var/lib/lti-health"
STATE_FILE="$STATE_DIR/watchdog.state"
ALERT_FILE="$LOG_DIR/watchdog-alert.txt"
MAX_SAMPLE_AGE="${MAX_SAMPLE_AGE:-120}"
MAX_DISK_USED="${MAX_DISK_USED:-90}"

mkdir -p "$LOG_DIR" "$STATE_DIR"

issues=()

check_active() {
    local unit="$1"
    if ! systemctl is-active --quiet "$unit"; then
        issues+=("$unit is not active")
    fi
}

check_active lti-health-sample.timer
check_active lti-health-daily.timer
check_active lti-health-weekly.timer
check_active lti-health-watchdog.timer
check_active fcgiwrap.service
check_active fcgiwrap-receiver.socket

METRICS="$LOG_DIR/metrics-$(date '+%Y-%m').csv"
if [ ! -f "$METRICS" ]; then
    issues+=("Current metrics file does not exist: $METRICS")
else
    last_epoch="$(tail -n 1 "$METRICS" | cut -d, -f1 | xargs -r date -d 2>/dev/null +%s || true)"
    now_epoch="$(date +%s)"
    if [ -z "$last_epoch" ]; then
        issues+=("Could not parse timestamp from the last metrics sample")
    else
        age=$((now_epoch - last_epoch))
        if [ "$age" -gt "$MAX_SAMPLE_AGE" ]; then
            issues+=("Last health sample is ${age}s old (limit ${MAX_SAMPLE_AGE}s)")
        fi
    fi
fi

DISK_USED="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
if [ -n "$DISK_USED" ] && [ "$DISK_USED" -ge "$MAX_DISK_USED" ]; then
    issues+=("Root filesystem usage is ${DISK_USED}% (alert threshold ${MAX_DISK_USED}%)")
fi

TODAY_HOUR="$(date '+%H')"
YESTERDAY="$(date -d yesterday '+%Y-%m-%d')"
if [ "$TODAY_HOUR" -ge 2 ] && [ ! -s "$LOG_DIR/report-$YESTERDAY.txt" ]; then
    issues+=("Daily report for $YESTERDAY is missing after 02:00")
fi

if [ "${#issues[@]}" -eq 0 ]; then
    current_state="OK"
else
    current_state="$(printf '%s\n' "${issues[@]}" | sort | sha256sum | awk '{print $1}')"
fi
previous_state="$(cat "$STATE_FILE" 2>/dev/null || true)"

send_notice() {
    local subject="$1"
    local body="$2"
    printf '%s\n' "$body" > "$ALERT_FILE"
    logger -t lti-health-watchdog -- "$subject: $body"
    if [ -n "${MAIL_TO:-}" ] && [ -n "${MAIL_FROM:-}" ] && [ -n "${SMTP_HOST:-}" ]; then
        /usr/local/sbin/lti-health-send-mail.py "$subject" "$ALERT_FILE" || true
    fi
}

if [ "$current_state" = "OK" ]; then
    if [ -n "$previous_state" ] && [ "$previous_state" != "OK" ]; then
        send_notice "LTI AI Grader monitoring recovered" "Monitoring is healthy again on $(hostname) at $(date '+%Y-%m-%d %H:%M:%S %z')."
    fi
else
    if [ "$current_state" != "$previous_state" ]; then
        body="LTI AI Grader monitoring alert on $(hostname) at $(date '+%Y-%m-%d %H:%M:%S %z')\n\nProblems detected:\n"
        for issue in "${issues[@]}"; do
            body+="- $issue\n"
        done
        send_notice "ALERT: LTI AI Grader monitoring" "$(printf '%b' "$body")"
    fi
fi

printf '%s\n' "$current_state" > "$STATE_FILE"
