#!/bin/bash
# LTI AI Grader monitoring watchdog (runs every 5 minutes from lti-health-watchdog.timer).
#
# It collects a list of problems and e-mails only when that list CHANGES, plus a "recovered" message
# when it becomes empty again. Each problem is a fixed sentence (so a number that changes does not
# cause a new e-mail); figures go in the "details" part of the message, which is not compared.
#
# Checks:
#   * systemd timers / fcgiwrap sockets are active, the last metrics sample is fresh, the root
#     filesystem is not nearly full, yesterday's daily report exists
#   * TLS (only when TLS_HOST is set): something answers on the HTTPS port, the certificate that is
#     really SERVED expires in more than TLS_WARN_DAYS, it verifies for TLS_HOST, and it is the same
#     certificate as CERT_FILE on disk (a renewed file that nginx has not reloaded)
#   * low available memory / high load average in the last ALERT_WINDOW_MIN minutes of samples
#
# Options (environment, normally /etc/lti-health/mail.env):
#   LTI_HEALTH_DRYRUN=1       print what would be reported; send nothing, change no state
#   --tls-summary (argument)  print one line about the served certificate and exit

set -u

LOG_DIR="${LOG_DIR:-/var/log/lti-health}"
STATE_DIR="${STATE_DIR:-/var/lib/lti-health}"
STATE_FILE="$STATE_DIR/watchdog.state"
TLS_FAILS_FILE="$STATE_DIR/watchdog-tls-fails"
ALERT_FILE="$LOG_DIR/watchdog-alert.txt"
SEND_MAIL="${LTI_HEALTH_SEND_MAIL:-/usr/local/sbin/lti-health-send-mail.py}"
DRYRUN="${LTI_HEALTH_DRYRUN:-0}"

MAX_SAMPLE_AGE="${MAX_SAMPLE_AGE:-120}"
MAX_DISK_USED="${MAX_DISK_USED:-90}"

# TLS checks are OFF until TLS_HOST is set.
TLS_HOST="${TLS_HOST:-}"
TLS_CONNECT="${TLS_CONNECT:-127.0.0.1}"
TLS_PORT="${TLS_PORT:-443}"
TLS_WARN_DAYS="${TLS_WARN_DAYS:-21}"
TLS_CRIT_DAYS="${TLS_CRIT_DAYS:-7}"
TLS_VERIFY="${TLS_VERIFY:-1}"
TLS_CAFILE="${TLS_CAFILE:-}"
CERT_FILE="${CERT_FILE:-}"
CERT_RELOAD_GRACE_MIN="${CERT_RELOAD_GRACE_MIN:-10}"
WATCHDOG_FAILS_BEFORE_ALERT="${WATCHDOG_FAILS_BEFORE_ALERT:-2}"

# Resource alerts (always on).
MEM_ALERT_MB="${MEM_ALERT_MB:-300}"
MEM_ALERT_SAMPLES="${MEM_ALERT_SAMPLES:-4}"
LOAD_ALERT="${LOAD_ALERT:-20}"
LOAD_ALERT_SAMPLES="${LOAD_ALERT_SAMPLES:-4}"
ALERT_WINDOW_MIN="${ALERT_WINDOW_MIN:-15}"

# ---------------------------------------------------------------------------------------------
# TLS helpers
# ---------------------------------------------------------------------------------------------

# Connects to the HTTPS port and fills TLS_OUT (full s_client output) and TLS_PEM (the served leaf
# certificate). Returns 1 when no certificate could be obtained.
tls_probe() {
    local args=(-connect "$TLS_CONNECT:$TLS_PORT" -servername "$TLS_HOST")
    if [ "$TLS_VERIFY" = "1" ]; then
        args+=(-verify_hostname "$TLS_HOST")
        if [ -n "$TLS_CAFILE" ]; then
            args+=(-CAfile "$TLS_CAFILE")
        fi
    fi
    TLS_OUT="$(echo | timeout 10 openssl s_client "${args[@]}" 2>&1 || true)"
    TLS_PEM="$(printf '%s\n' "$TLS_OUT" | openssl x509 2>/dev/null || true)"
    [ -n "$TLS_PEM" ]
}

# Expiry of a PEM certificate given on stdin, as epoch seconds ("" when it cannot be read).
pem_end_epoch() {
    local notafter
    notafter="$(openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2-)"
    [ -n "$notafter" ] && date -d "$notafter" +%s 2>/dev/null
}

pem_enddate_text() {
    openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2-
}

pem_fingerprint() {
    openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}

tls_summary() {
    local end now days notafter issuer
    if [ -z "$TLS_HOST" ]; then
        echo "Certificate check is not configured (TLS_HOST is empty: set it in /etc/lti-health/mail.env; run through systemctl so that file is loaded)."
        return 0
    fi
    if ! tls_probe; then
        echo "Could not get a certificate from $TLS_CONNECT:$TLS_PORT for $TLS_HOST."
        return 0
    fi
    notafter="$(printf '%s\n' "$TLS_PEM" | pem_enddate_text)"
    end="$(printf '%s\n' "$TLS_PEM" | pem_end_epoch)"
    now="$(date +%s)"
    if [ -z "$end" ]; then
        echo "Certificate served for $TLS_HOST: expiry date could not be read."
    elif [ "$end" -le "$now" ]; then
        echo "Certificate served for $TLS_HOST: EXPIRED on $notafter"
    else
        days=$(( (end - now) / 86400 ))
        echo "Certificate served for $TLS_HOST: expires $notafter ($days days left)"
    fi
    issuer="$(printf '%s\n' "$TLS_PEM" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer= *//')"
    if [ -n "$issuer" ]; then
        echo "Issuer: $issuer"
    fi
}

if [ "${1:-}" = "--tls-summary" ]; then
    tls_summary
    exit 0
fi

mkdir -p "$LOG_DIR" "$STATE_DIR"

issues=()
details=()

check_active() {
    local unit="$1"
    if ! systemctl is-active --quiet "$unit"; then
        issues+=("$unit is not active")
    fi
}

check_active lti-health-sample.timer
check_active lti-health-daily.timer
check_active lti-health-weekly.timer
check_active lti-health-ai-watch.timer
check_active lti-health-watchdog.timer
# fcgiwrap is socket-activated: the *service* only runs after the first request following a
# boot or restart, so "fcgiwrap.service inactive" is normal while idle. What must always be up
# is the listening *socket* (nginx connects to it, and systemd starts the service on demand).
check_active fcgiwrap.socket
check_active fcgiwrap-receiver.socket

METRICS="$LOG_DIR/metrics-$(date '+%Y-%m').csv"
if [ ! -f "$METRICS" ]; then
    issues+=("Current metrics file does not exist: $METRICS")
else
    # The timestamp is "YYYY-MM-DD HH:MM:SS" (it contains a space), so it must be passed to date as
    # ONE quoted argument. Piping it through xargs split it in two and the parse always failed.
    # It is validated first because `date -d ""` silently returns midnight instead of failing.
    last_ts="$(tail -n 1 "$METRICS" | cut -d, -f1)"
    last_epoch=""
    if [[ "$last_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        last_epoch="$(date -d "$last_ts" +%s 2>/dev/null || true)"
    fi
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

# ---------------------------------------------------------------------------------------------
# TLS: nginx answering, certificate served (expiry, chain, host name), file on disk reloaded
# ---------------------------------------------------------------------------------------------
check_tls() {
    [ -n "$TLS_HOST" ] || return 0

    local fails problem="" notafter end now days verify_line fp_served fp_disk mtime file_age
    fails="$(cat "$TLS_FAILS_FILE" 2>/dev/null || echo 0)"
    [[ "$fails" =~ ^[0-9]+$ ]] || fails=0

    if command -v ss >/dev/null 2>&1 && ! ss -H -ltn "sport = :$TLS_PORT" 2>/dev/null | grep -q .; then
        problem="Nothing is listening on TCP port $TLS_PORT (nginx down?)"
    elif ! tls_probe; then
        problem="No TLS certificate received from the HTTPS port (nginx down or not serving TLS?)"
    fi

    if [ -n "$problem" ]; then
        fails=$((fails + 1))
        if [ "$DRYRUN" != "1" ]; then
            echo "$fails" > "$TLS_FAILS_FILE"
        fi
        # A single failure can be an nginx reload; report only after consecutive failed checks.
        if [ "$fails" -ge "$WATCHDOG_FAILS_BEFORE_ALERT" ] || [ "$DRYRUN" = "1" ]; then
            issues+=("$problem")
            details+=("HTTPS check: $TLS_CONNECT:$TLS_PORT, host name $TLS_HOST, $fails consecutive failed check(s)")
        fi
        return 0
    fi
    if [ "$DRYRUN" != "1" ]; then
        echo 0 > "$TLS_FAILS_FILE"
    fi

    now="$(date +%s)"
    notafter="$(printf '%s\n' "$TLS_PEM" | pem_enddate_text)"
    end="$(printf '%s\n' "$TLS_PEM" | pem_end_epoch)"
    if [ -z "$end" ]; then
        issues+=("The expiry date of the certificate served by $TLS_HOST could not be read")
    elif [ "$end" -le "$now" ]; then
        issues+=("TLS certificate served by $TLS_HOST has EXPIRED")
        details+=("It expired on $notafter")
    else
        days=$(( (end - now) / 86400 ))
        if [ "$days" -lt "$TLS_CRIT_DAYS" ]; then
            # The number is part of the sentence on purpose: one reminder per day in the last days.
            issues+=("TLS certificate served by $TLS_HOST expires in $days day(s)")
            details+=("Expires $notafter")
        elif [ "$days" -lt "$TLS_WARN_DAYS" ]; then
            issues+=("TLS certificate served by $TLS_HOST expires in less than $TLS_WARN_DAYS days")
            details+=("Expires $notafter ($days days left)")
        fi
    fi

    if [ "$TLS_VERIFY" = "1" ]; then
        verify_line="$(printf '%s\n' "$TLS_OUT" | grep -m1 'Verify return code:' | sed 's/^ *//')"
        if [ -z "$verify_line" ]; then
            issues+=("The TLS certificate chain of $TLS_HOST could not be verified")
        elif [ "${verify_line#Verify return code: 0 (}" = "$verify_line" ]; then
            issues+=("The TLS certificate served by $TLS_HOST does not verify (chain or host name)")
            details+=("$verify_line")
        fi
    fi

    if [ -n "$CERT_FILE" ]; then
        if [ ! -r "$CERT_FILE" ]; then
            issues+=("Certificate file $CERT_FILE is missing or unreadable")
        else
            fp_disk="$(pem_fingerprint < "$CERT_FILE")"
            fp_served="$(printf '%s\n' "$TLS_PEM" | pem_fingerprint)"
            if [ -z "$fp_disk" ]; then
                issues+=("No certificate could be read from $CERT_FILE")
            elif [ "$fp_disk" != "$fp_served" ]; then
                mtime="$(stat -c %Y "$CERT_FILE" 2>/dev/null || echo 0)"
                file_age=$(( now - mtime ))
                # Give nginx a few minutes after the file was written before complaining.
                if [ "$file_age" -gt $(( CERT_RELOAD_GRACE_MIN * 60 )) ]; then
                    issues+=("The certificate file on disk is not the one nginx is serving (reload nginx?)")
                    details+=("Served: $fp_served")
                    details+=("On disk ($CERT_FILE, changed $(date -d "@$mtime" '+%Y-%m-%d %H:%M')): $fp_disk")
                fi
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------------------------
# Low available memory / high load in the last ALERT_WINDOW_MIN minutes of samples
# (columns: timestamp,load1,mem_available_mb,...)
# ---------------------------------------------------------------------------------------------
check_resources() {
    [ -f "$METRICS" ] || return 0
    local cutoff res n low minmem hi maxload load_limit
    cutoff="$(date -d "-${ALERT_WINDOW_MIN} minutes" '+%Y-%m-%d %H:%M:%S')"
    load_limit="$LOAD_ALERT"
    [ "$LOAD_ALERT" = "0" ] && load_limit=999999999
    res="$(tail -n 400 "$METRICS" | awk -F, -v cutoff="$cutoff" -v memmax="$MEM_ALERT_MB" -v loadmax="$load_limit" '
        $1 ~ /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] / && $1 >= cutoff {
            n++
            if ($3 ~ /^[0-9]+$/ && $3 + 0 < memmax) { low++; if (minmem == "" || $3 + 0 < minmem) minmem = $3 + 0 }
            if ($2 ~ /^[0-9.]+$/ && $2 + 0 > loadmax) { hi++; if ($2 + 0 > maxload) maxload = $2 + 0 }
        }
        END { printf "%d %d %d %d %s\n", n, low, (minmem == "" ? 0 : minmem), hi, (maxload == "" ? 0 : maxload) }')"
    read -r n low minmem hi maxload <<< "$res"
    n="${n:-0}"; low="${low:-0}"; minmem="${minmem:-0}"; hi="${hi:-0}"; maxload="${maxload:-0}"

    if [ "$low" -ge "$MEM_ALERT_SAMPLES" ]; then
        issues+=("Available memory is below ${MEM_ALERT_MB} MB in ${MEM_ALERT_SAMPLES} or more samples of the last ${ALERT_WINDOW_MIN} minutes")
        details+=("$low of $n samples below ${MEM_ALERT_MB} MB; lowest ${minmem} MB")
    fi
    if [ "$LOAD_ALERT" != "0" ] && [ "$hi" -ge "$LOAD_ALERT_SAMPLES" ]; then
        issues+=("1-minute load average is above ${LOAD_ALERT} in ${LOAD_ALERT_SAMPLES} or more samples of the last ${ALERT_WINDOW_MIN} minutes")
        details+=("$hi of $n samples above ${LOAD_ALERT}; highest ${maxload}")
    fi
}

check_tls
check_resources

# ---------------------------------------------------------------------------------------------
# Notification: only when the set of problems changes
# ---------------------------------------------------------------------------------------------
if [ "$DRYRUN" = "1" ]; then
    if [ "${#issues[@]}" -eq 0 ]; then
        echo "Dry run: no problems detected."
    else
        echo "Dry run: problems that would be reported:"
        for issue in "${issues[@]}"; do
            echo "- $issue"
        done
        if [ "${#details[@]}" -gt 0 ]; then
            echo "Details:"
            for detail in "${details[@]}"; do
                echo "- $detail"
            done
        fi
    fi
    exit 0
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
        "$SEND_MAIL" "$subject" "$ALERT_FILE" || true
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
        if [ "${#details[@]}" -gt 0 ]; then
            body+="\nDetails (informational, not used to decide whether to alert again):\n"
            for detail in "${details[@]}"; do
                body+="- $detail\n"
            done
        fi
        send_notice "ALERT: LTI AI Grader monitoring" "$(printf '%b' "$body")"
    fi
fi

printf '%s\n' "$current_state" > "$STATE_FILE"
