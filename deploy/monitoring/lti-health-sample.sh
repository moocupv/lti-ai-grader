#!/bin/bash
set -u

LOG_DIR="/var/log/lti-health"
SAMPLE_FILE="$LOG_DIR/metrics-$(date +%Y-%m).csv"
MAIN_POOL_SIZE="${MAIN_POOL_SIZE:-16}"
RECEIVER_POOL_SIZE="${RECEIVER_POOL_SIZE:-5}"

mkdir -p "$LOG_DIR"

if [ ! -f "$SAMPLE_FILE" ]; then
    echo "timestamp,load1,mem_available_mb,disk_used_pct,evaluators,oldest_evaluator_sec,lti_receivers,fcgi_general,fcgi_receiver,queue_general,queue_receiver" > "$SAMPLE_FILE"
fi

TS="$(date '+%Y-%m-%d %H:%M:%S')"
LOAD1="$(awk '{print $1}' /proc/loadavg)"
MEM_AVAILABLE_MB="$(awk '/MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)"
DISK_USED_PCT="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"

EVALUATORS="$(pgrep -fc '^python3 /usr/lib/cgi-bin/evaluate-' 2>/dev/null || true)"
LTI_RECEIVERS="$(pgrep -fc '^python3 /usr/lib/cgi-bin/lti-receiver.py' 2>/dev/null || true)"

OLDEST_EVALUATOR_SEC="$(
    ps -eo etimes=,args= 2>/dev/null |
    awk '/python3 \/usr\/lib\/cgi-bin\/evaluate-/ {
        if ($1 > max) max=$1
    }
    END {print max+0}'
)"

FCGI_GENERAL="$(
    ps -eo args= 2>/dev/null |
    awk -v n="$MAIN_POOL_SIZE" '$0 ~ ("^/usr/sbin/fcgiwrap -f -c " n "$") {count++} END {print count+0}'
)"

FCGI_RECEIVER="$(
    ps -eo args= 2>/dev/null |
    awk -v n="$RECEIVER_POOL_SIZE" '$0 ~ ("^/usr/sbin/fcgiwrap -f -c " n "$") {count++} END {print count+0}'
)"

# ss columns with -x -l -H are: Netid State Recv-Q Send-Q Local Address ...
QUEUE_GENERAL="$(
    ss -xlH 2>/dev/null |
    awk '$0 ~ /\/run\/fcgiwrap.socket/ && $0 !~ /receiver/ {print $3; exit}'
)"
[ -n "$QUEUE_GENERAL" ] || QUEUE_GENERAL=0

QUEUE_RECEIVER="$(
    ss -xlH 2>/dev/null |
    awk '$0 ~ /\/run\/fcgiwrap-receiver.socket/ {print $3; exit}'
)"
[ -n "$QUEUE_RECEIVER" ] || QUEUE_RECEIVER=0

printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$TS" "$LOAD1" "$MEM_AVAILABLE_MB" "$DISK_USED_PCT" \
    "$EVALUATORS" "$OLDEST_EVALUATOR_SEC" "$LTI_RECEIVERS" \
    "$FCGI_GENERAL" "$FCGI_RECEIVER" "$QUEUE_GENERAL" "$QUEUE_RECEIVER" \
    >> "$SAMPLE_FILE"
