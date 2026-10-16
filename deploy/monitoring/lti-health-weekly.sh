#!/bin/bash
# Weekly LTI AI Grader health and usage report.
#
# By default it covers the previous full ISO week (Monday..Sunday), so the timer that runs it
# on Monday at 08:00 reports the week that just ended. It writes
#   /var/log/lti-health/weekly-YYYY-Www.txt
# and, if SMTP is configured (/etc/lti-health/mail.env), e-mails it.
#
# Manual use (also to backfill a period):
#   sudo /usr/local/sbin/lti-health-weekly.sh                       # previous full week
#   sudo /usr/local/sbin/lti-health-weekly.sh 2026-09-28 2026-10-04 # explicit range
set -u

LOG_DIR="${LTI_HEALTH_LOG_DIR:-/var/log/lti-health}"
NGINX_LOG_DIR="${LTI_HEALTH_NGINX_LOG_DIR:-/var/log/nginx}"
STATS_BIN="${LTI_HEALTH_STATS_BIN:-/usr/local/sbin/lti-health-log-stats.py}"
MAIL_BIN="${LTI_HEALTH_MAIL_BIN:-/usr/local/sbin/lti-health-send-mail.py}"
AI_EVENTS_BIN="${LTI_HEALTH_AI_EVENTS_BIN:-/usr/local/sbin/lti-health-ai-events.py}"

note() {
    echo "$*"
    if command -v logger >/dev/null 2>&1; then
        logger -t lti-health-weekly -- "$*"
    fi
}

# ---- period ---------------------------------------------------------------
if [ "$#" -eq 0 ]; then
    dow="$(date '+%u')"                                   # 1 = Monday ... 7 = Sunday
    END="$(date -d "-${dow} days" '+%Y-%m-%d')"           # last Sunday
    START="$(date -d "-$((dow + 6)) days" '+%Y-%m-%d')"   # the Monday before it
    LABEL="$(date -d "$START 12:00" '+%G-W%V')"
    REPORT="$LOG_DIR/weekly-$LABEL.txt"
elif [ "$#" -eq 2 ]; then
    START="$1"
    END="$2"
    LABEL="$START to $END"
    REPORT="$LOG_DIR/weekly-${START}_${END}.txt"
else
    echo "Usage: $0 [START_YYYY-MM-DD END_YYYY-MM-DD]" >&2
    exit 2
fi

start_epoch="$(date -d "$START 12:00" +%s 2>/dev/null)" || { echo "Invalid start date: $START" >&2; exit 2; }
end_epoch="$(date -d "$END 12:00" +%s 2>/dev/null)" || { echo "Invalid end date: $END" >&2; exit 2; }
if [ "$end_epoch" -lt "$start_epoch" ]; then
    echo "END must be on or after START" >&2
    exit 2
fi

mkdir -p "$LOG_DIR"
TMP_METRICS="$(mktemp)"
TMP_ACCESS="$(mktemp)"
TMP_ERRORS="$(mktemp)"
TMP_DAYS="$(mktemp)"
TMP_DAY_METRICS="$(mktemp)"
TMP_DAY_ACCESS="$(mktemp)"
trap 'rm -f "$TMP_METRICS" "$TMP_ACCESS" "$TMP_ERRORS" "$TMP_DAYS" "$TMP_DAY_METRICS" "$TMP_DAY_ACCESS"' EXIT

# ---- collect the data day by day -------------------------------------------
# (the period may span two months, so the monthly metrics files are read per day)
d="$START"
while [ "$(date -d "$d 12:00" +%s)" -le "$end_epoch" ]; do
    month="${d:0:7}"
    access_day="$(LC_ALL=C date -d "$d 12:00" '+%d/%b/%Y')"
    error_day="$(date -d "$d 12:00" '+%Y/%m/%d')"

    : > "$TMP_DAY_METRICS"
    if [ -f "$LOG_DIR/metrics-$month.csv" ]; then
        grep "^$d " "$LOG_DIR/metrics-$month.csv" > "$TMP_DAY_METRICS" || true
    fi
    cat "$TMP_DAY_METRICS" >> "$TMP_METRICS"

    zgrep -h "$access_day" "$NGINX_LOG_DIR"/access.log* 2>/dev/null > "$TMP_DAY_ACCESS" || true
    cat "$TMP_DAY_ACCESS" >> "$TMP_ACCESS"
    zgrep -h "$error_day" "$NGINX_LOG_DIR"/error.log* 2>/dev/null >> "$TMP_ERRORS" || true

    samples="$(wc -l < "$TMP_DAY_METRICS")"
    launches="$(grep -c '/cgi-bin/lti-receiver.py' "$TMP_DAY_ACCESS" || true)"
    corrections="$(grep -c '/cgi-bin/evalua' "$TMP_DAY_ACCESS" || true)"
    http429="$(grep -cE '" 429 ' "$TMP_DAY_ACCESS" || true)"
    http5xx="$(grep -cE '" 50[0-9] ' "$TMP_DAY_ACCESS" || true)"
    max_eval="$(awk -F, '{if($5>m)m=$5} END{print m+0}' "$TMP_DAY_METRICS")"
    printf '%-12s %8s %9s %12s %6s %6s %14s\n' \
        "$d ($(LC_ALL=C date -d "$d 12:00" '+%a'))" "$samples" "$launches" "$corrections" "$http429" "$http5xx" "$max_eval" >> "$TMP_DAYS"

    d="$(date -d "$d 12:00 +1 day" '+%Y-%m-%d')"
done

# ---- report ---------------------------------------------------------------
{
    echo "============================================================"
    echo " LTI AI GRADER - WEEKLY HEALTH REPORT $LABEL"
    echo " Period: $START to $END    Host: $(hostname)"
    echo "============================================================"
    echo

    echo "---------------- DAY BY DAY ----------------"
    printf '%-12s %8s %9s %12s %6s %6s %14s\n' "Day" "Samples" "Launches" "Corrections" "429" "5xx" "Max evaluators"
    cat "$TMP_DAYS"
    echo "(Samples are taken every 30 s: 2880 per full day. Fewer means monitoring was not running.)"
    echo

    if [ ! -s "$TMP_METRICS" ]; then
        echo "No health samples found for this period."
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
        echo -n "fcgiwrap main pool, most processes seen (workers + 1 master): "
        awk -F, '{if($8>m)m=$8} END{print m+0}' "$TMP_METRICS"
        echo -n "fcgiwrap main pool, samples with no process (not started yet): "
        awk -F, '$8==0{c++} END{print c+0 " of " NR}' "$TMP_METRICS"
        echo -n "fcgiwrap receiver pool, most processes seen (workers + 1 master): "
        awk -F, '{if($9>m)m=$9} END{print m+0}' "$TMP_METRICS"
        echo -n "fcgiwrap receiver pool, samples with no process (not started yet): "
        awk -F, '$9==0{c++} END{print c+0 " of " NR}' "$TMP_METRICS"
        echo "(fcgiwrap is socket-activated: after a reboot a pool only starts with its first request.)"
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
    echo "Evaluator requests: $(grep -c '/cgi-bin/evalua' "$TMP_ACCESS" || true)"
    echo "HTTP 429 responses: $(grep -cE '" 429 ' "$TMP_ACCESS" || true)"
    echo "HTTP 5xx responses: $(grep -cE '" 50[0-9] ' "$TMP_ACCESS" || true)"
    echo "Upstream timeouts: $(grep -c 'upstream timed out' "$TMP_ERRORS" || true)"
    echo "Evaluator upstream timeouts: $(grep 'upstream timed out' "$TMP_ERRORS" | grep -c '/cgi-bin/evalua' || true)"
    echo "Receiver upstream timeouts: $(grep 'upstream timed out' "$TMP_ERRORS" | grep -c 'lti-receiver.py' || true)"
    echo "Rate-limit events: $(grep -c 'limiting requests' "$TMP_ERRORS" || true)"

    echo
    echo "---------------- LTI USAGE ----------------"
    "$STATS_BIN" --start "$START" --end "$END" --logs "$NGINX_LOG_DIR/access.log*" 2>&1 \
        || echo "Could not calculate LTI usage statistics."

    echo
    echo "---------------- AI PROVIDER ----------------"
    "$AI_EVENTS_BIN" report --start "$START" --end "$END" --logs "$NGINX_LOG_DIR/error.log*" 2>&1 \
        || echo "Could not calculate AI event statistics."

    echo
    echo "Raw metrics: $LOG_DIR/metrics-YYYY-MM.csv (one file per month)"
    echo "Note: counts come from the Nginx access logs, which are only kept as long as logrotate keeps them."
} > "$REPORT"

echo "Weekly report written to $REPORT"

# ---- optional e-mail -------------------------------------------------------
status=0
if [ -n "${MAIL_TO:-}" ] && [ -n "${MAIL_FROM:-}" ] && [ -n "${SMTP_HOST:-}" ]; then
    if "$MAIL_BIN" "LTI AI Grader weekly report $LABEL ($(hostname))" "$REPORT"; then
        note "Weekly report $LABEL e-mailed to $MAIL_TO"
    else
        note "FAILED to e-mail weekly report $LABEL (report kept in $REPORT)"
        status=1
    fi
else
    echo "E-mail not configured (set MAIL_TO, MAIL_FROM and SMTP_HOST in /etc/lti-health/mail.env); nothing sent."
fi

exit "$status"
