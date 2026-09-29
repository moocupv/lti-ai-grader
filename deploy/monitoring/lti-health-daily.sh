#!/bin/bash
set -u

LOG_DIR="/var/log/lti-health"
DAY="$(date -d yesterday '+%Y-%m-%d')"
MONTH="$(date -d yesterday '+%Y-%m')"
NGINX_DAY="$(date -d yesterday '+%Y/%m/%d')"
METRICS="$LOG_DIR/metrics-$MONTH.csv"
REPORT="$LOG_DIR/report-$DAY.txt"
TMP="$(mktemp)"

mkdir -p "$LOG_DIR"
trap 'rm -f "$TMP"' EXIT

if [ -f "$METRICS" ]; then
    grep "^$DAY " "$METRICS" > "$TMP" || true
fi

nginx_error_lines() {
    zgrep -h "$NGINX_DAY" /var/log/nginx/error.log* 2>/dev/null || true
}

nginx_access_lines() {
    zgrep -h "$NGINX_DAY" /var/log/nginx/access.log* 2>/dev/null || true
}

{
    echo "============================================================"
    echo " LTI AI GRADER - DAILY HEALTH REPORT $DAY"
    echo "============================================================"
    echo

    if [ ! -s "$TMP" ]; then
        echo "No health samples found for this day."
    else
        echo "---------------- CAPACITY ----------------"
        echo "Samples: $(wc -l < "$TMP")"
        echo -n "Maximum 1-minute load average: "
        awk -F, '{if($2>m)m=$2} END{print m+0}' "$TMP"
        echo -n "Minimum available memory (MB): "
        awk -F, 'NR==1{m=$3} $3<m{m=$3} END{print m+0}' "$TMP"
        echo -n "Maximum root filesystem usage (%): "
        awk -F, '{if($4>m)m=$4} END{print m+0}' "$TMP"
        echo

        echo "---------------- CONCURRENCY ----------------"
        echo -n "Maximum simultaneous evaluators observed: "
        awk -F, '{if($5>m)m=$5} END{print m+0}' "$TMP"
        echo -n "Longest evaluator age observed (s): "
        awk -F, '{if($6>m)m=$6} END{print m+0}' "$TMP"
        echo -n "Maximum simultaneous LTI receiver processes: "
        awk -F, '{if($7>m)m=$7} END{print m+0}' "$TMP"
        echo -n "Minimum observed main fcgiwrap process count: "
        awk -F, 'NR==1{m=$8} $8<m{m=$8} END{print m+0}' "$TMP"
        echo -n "Minimum observed receiver fcgiwrap process count: "
        awk -F, 'NR==1{m=$9} $9<m{m=$9} END{print m+0}' "$TMP"
        echo

        echo "---------------- SOCKET QUEUES ----------------"
        echo -n "Maximum evaluator socket Recv-Q: "
        awk -F, '{if($10>m)m=$10} END{print m+0}' "$TMP"
        echo -n "Maximum receiver socket Recv-Q: "
        awk -F, '{if($11>m)m=$11} END{print m+0}' "$TMP"
    fi

    echo
    echo "---------------- NGINX EVENTS ----------------"
    ACCESS="$(nginx_access_lines)"
    ERRORS="$(nginx_error_lines)"

    echo -n "LTI receiver requests: "
    printf '%s\n' "$ACCESS" | grep -c '/cgi-bin/lti-receiver.py' || true
    echo -n "Evaluator requests: "
    printf '%s\n' "$ACCESS" | grep -c '/cgi-bin/evaluate-' || true
    echo -n "HTTP 429 responses: "
    printf '%s\n' "$ACCESS" | grep -cE '" 429 ' || true
    echo -n "HTTP 5xx responses: "
    printf '%s\n' "$ACCESS" | grep -cE '" 50[0-9] ' || true
    echo -n "Upstream timeouts: "
    printf '%s\n' "$ERRORS" | grep -c 'upstream timed out' || true
    echo -n "Evaluator upstream timeouts: "
    printf '%s\n' "$ERRORS" | grep 'upstream timed out' | grep -c '/cgi-bin/evaluate-' || true
    echo -n "Receiver upstream timeouts: "
    printf '%s\n' "$ERRORS" | grep 'upstream timed out' | grep -c 'lti-receiver.py' || true
    echo -n "Rate-limit events: "
    printf '%s\n' "$ERRORS" | grep -c 'limiting requests' || true

    echo
    echo "Metrics file: $METRICS"
} > "$REPORT"

# Keep a little over one year of local monitoring data.
find "$LOG_DIR" -type f -mtime +400 -delete 2>/dev/null || true
