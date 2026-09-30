#!/bin/bash
set -u

LOG_DIR="/var/log/lti-health"
DAY="$(date -d yesterday '+%Y-%m-%d')"
MONTH="$(date -d yesterday '+%Y-%m')"
ACCESS_DAY="$(LC_ALL=C date -d yesterday '+%d/%b/%Y')"
ERROR_DAY="$(date -d yesterday '+%Y/%m/%d')"
METRICS="$LOG_DIR/metrics-$MONTH.csv"
REPORT="$LOG_DIR/report-$DAY.txt"
TMP_METRICS="$(mktemp)"
TMP_ACCESS="$(mktemp)"
TMP_ERRORS="$(mktemp)"

mkdir -p "$LOG_DIR"
trap 'rm -f "$TMP_METRICS" "$TMP_ACCESS" "$TMP_ERRORS"' EXIT

if [ -f "$METRICS" ]; then
    grep "^$DAY " "$METRICS" > "$TMP_METRICS" || true
fi

zgrep -h "$ACCESS_DAY" /var/log/nginx/access.log* 2>/dev/null > "$TMP_ACCESS" || true
zgrep -h "$ERROR_DAY" /var/log/nginx/error.log* 2>/dev/null > "$TMP_ERRORS" || true

{
    echo "============================================================"
    echo " LTI AI GRADER - DAILY HEALTH REPORT $DAY"
    echo "============================================================"
    echo

    if [ ! -s "$TMP_METRICS" ]; then
        echo "No health samples found for this day."
    else
        echo "---------------- CAPACITY ----------------"
        echo "Samples: $(wc -l < "$TMP_METRICS")"
        echo -n "Maximum 1-minute load average: "
        awk -F, '{if($2>m)m=$2} END{print m+0}' "$TMP_METRICS"
        echo -n "Minimum available memory (MB): "
        awk -F, 'NR==1{m=$3} $3<m{m=$3} END{print m+0}' "$TMP_METRICS"
        echo -n "Maximum root filesystem usage (%): "
        awk -F, '{if($4>m)m=$4} END{print m+0}' "$TMP_METRICS"
        echo

        echo "---------------- CONCURRENCY ----------------"
        echo -n "Maximum simultaneous evaluators observed: "
        awk -F, '{if($5>m)m=$5} END{print m+0}' "$TMP_METRICS"
        echo -n "Longest evaluator age observed (s): "
        awk -F, '{if($6>m)m=$6} END{print m+0}' "$TMP_METRICS"
        echo -n "Maximum simultaneous LTI receiver processes: "
        awk -F, '{if($7>m)m=$7} END{print m+0}' "$TMP_METRICS"
        echo -n "Minimum observed main fcgiwrap process count: "
        awk -F, 'NR==1{m=$8} $8<m{m=$8} END{print m+0}' "$TMP_METRICS"
        echo -n "Minimum observed receiver fcgiwrap process count: "
        awk -F, 'NR==1{m=$9} $9<m{m=$9} END{print m+0}' "$TMP_METRICS"
        echo

        echo "---------------- SOCKET QUEUES ----------------"
        echo -n "Maximum evaluator socket Recv-Q: "
        awk -F, '{if($10>m)m=$10} END{print m+0}' "$TMP_METRICS"
        echo -n "Maximum receiver socket Recv-Q: "
        awk -F, '{if($11>m)m=$11} END{print m+0}' "$TMP_METRICS"
    fi

    echo
    echo "---------------- NGINX EVENTS ----------------"
    echo "LTI receiver requests: $(grep -c '/cgi-bin/lti-receiver.py' "$TMP_ACCESS" || true)"
    echo "Evaluator requests: $(grep -c '/cgi-bin/evaluate-' "$TMP_ACCESS" || true)"
    echo "HTTP 429 responses: $(grep -cE '" 429 ' "$TMP_ACCESS" || true)"
    echo "HTTP 5xx responses: $(grep -cE '" 50[0-9] ' "$TMP_ACCESS" || true)"
    echo "Upstream timeouts: $(grep -c 'upstream timed out' "$TMP_ERRORS" || true)"
    echo "Evaluator upstream timeouts: $(grep 'upstream timed out' "$TMP_ERRORS" | grep -c '/cgi-bin/evaluate-' || true)"
    echo "Receiver upstream timeouts: $(grep 'upstream timed out' "$TMP_ERRORS" | grep -c 'lti-receiver.py' || true)"
    echo "Rate-limit events: $(grep -c 'limiting requests' "$TMP_ERRORS" || true)"

    echo
    echo "---------------- LTI USAGE ----------------"
    /usr/local/sbin/lti-health-log-stats.py --start "$DAY" --end "$DAY" 2>&1 || echo "Could not calculate LTI usage statistics."

    echo
    echo "Metrics file: $METRICS"
} > "$REPORT"

# Keep a little over one year of local monitoring data.
find "$LOG_DIR" -type f -mtime +400 -delete 2>/dev/null || true
