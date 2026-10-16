#!/usr/bin/env python3
"""Summarise and watch the events that aigrader.py writes for every AI call.

aigrader.py writes one line per event to stderr, e.g.

    [lti-ai-grader] event=ai_error ts=2026-10-16T01:53:59+0200 script=evalua-x.py provider=openai
    model=poligpt-code kind=HTTPError code=500 ms=25 detail=...

The web server keeps CGI stderr in its error log, so this script only reads the Nginx error
log (current and rotated files). Student text is never part of an event.

Events: ai_ok, ai_error, no_grade (model answered without a grade line), lms_grade_failed
(grade could not be delivered to the LMS), session_missing, cgi_error.

Usage:
    lti-health-ai-events.py report --start YYYY-MM-DD --end YYYY-MM-DD   # section for the reports
    lti-health-ai-events.py watch                                        # e-mail on consecutive failures

`watch` is meant to run every few minutes (lti-health-ai-watch.timer). It alerts when the last
AI_ALERT_CONSECUTIVE (default 3) AI calls, all within the last AI_ALERT_WINDOW_MIN (default 30)
minutes, failed, and sends one "recovered" message when a call succeeds again.
"""

import argparse
import glob
import gzip
import json
import os
import re
import socket
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta
from urllib.parse import unquote

MARK = "[lti-ai-grader]"
TOKEN_RE = re.compile(r"^(\w+)=(.*)$")
DEFAULT_ERROR_LOGS = "/var/log/nginx/error.log*"


# --------------------------------------------------------------------------- parsing
def open_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, "rt", encoding="utf-8", errors="replace")


def parse_event_line(line):
    """Return a dict for an event line, or None.

    The event may sit on a continuation line (when other stderr text was written in the same
    chunk) and may be followed by Nginx's trailer (`" while reading ... upstream, client: ...`),
    so the line is cut at the first token that is not key=value.
    """
    pos = line.find(MARK)
    if pos < 0:
        return None
    event = {}
    for token in line[pos + len(MARK):].split():
        match = TOKEN_RE.match(token.rstrip('"'))
        if not match:
            break
        event[match.group(1)] = unquote(match.group(2))
    if "event" not in event or "ts" not in event:
        return None
    try:
        event["_dt"] = datetime.strptime(event["ts"], "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return None
    return event


def iter_events(pattern):
    for path in sorted(glob.glob(pattern)):
        if not os.path.isfile(path):
            continue
        try:
            handle = open_text(path)
        except OSError:
            continue
        with handle:
            try:
                for line in handle:
                    event = parse_event_line(line)
                    if event:
                        yield event
            except (OSError, EOFError):
                continue  # truncated or corrupt rotated file


# --------------------------------------------------------------------------- report
def percentile(sorted_values, pct):
    if not sorted_values:
        return 0
    index = min(len(sorted_values) - 1, int(round((pct / 100.0) * (len(sorted_values) - 1))))
    return sorted_values[index]


def short(text, width):
    text = " ".join(str(text).split())
    return text if len(text) <= width else text[: width - 1] + "…"


def normalize_detail(text):
    """Group the same error together even if it contains memory addresses or long numbers."""
    text = re.sub(r"0x[0-9a-fA-F]+", "0x…", text)
    return re.sub(r"\d{6,}", "#", text)


def cmd_report(args):
    start = date.fromisoformat(args.start)
    end = date.fromisoformat(args.end)
    if end < start:
        print("--end must be on or after --start", file=sys.stderr)
        return 2

    events = [e for e in iter_events(args.logs) if start <= e["_dt"].date() <= end]
    print("AI PROVIDER AND GRADING EVENTS")
    print("------------------------------")
    if not events:
        print("No grader events found in this period.")
        print("(If corrections were made, check that the updated aigrader.py is installed in")
        print(" /usr/lib/cgi-bin and that the Nginx error log is retained for this period.)")
        return 0

    counts = Counter(e["event"] for e in events)
    ok, err = counts["ai_ok"], counts["ai_error"]
    calls = ok + err
    rate = (100.0 * err / calls) if calls else 0.0
    print(f"AI calls: {calls}   OK: {ok}   Provider errors: {err} ({rate:.1f} %)")
    print(f"Answers without a grade line: {counts['no_grade']}")
    print(f"Grade not delivered to the LMS: {counts['lms_grade_failed']}")
    print(f"Session token without session file: {counts['session_missing']}")
    print(f"Unexpected grader errors: {counts['cgi_error']}")

    latencies = sorted(int(e["ms"]) for e in events if e["event"] == "ai_ok" and e.get("ms", "").isdigit())
    if latencies:
        slow = sum(1 for ms in latencies if ms > 60000)
        print(
            f"AI response time (successful calls): median {percentile(latencies, 50) / 1000:.1f} s, "
            f"p95 {percentile(latencies, 95) / 1000:.1f} s, max {latencies[-1] / 1000:.1f} s, "
            f"over 60 s: {slow}"
        )

    causes = {}
    for e in events:
        if e["event"] != "ai_error":
            continue
        key = (e.get("kind", "?"), e.get("code", "-"), short(normalize_detail(e.get("detail", "")), 110))
        item = causes.setdefault(key, {"n": 0, "first": e["_dt"], "last": e["_dt"]})
        item["n"] += 1
        item["first"] = min(item["first"], e["_dt"])
        item["last"] = max(item["last"], e["_dt"])
    if causes:
        print()
        print("PROVIDER ERRORS BY CAUSE")
        print("------------------------")
        for (kind, code, detail), item in sorted(causes.items(), key=lambda kv: -kv[1]["n"])[:8]:
            span = item["first"].strftime("%m-%d %H:%M")
            if item["last"] != item["first"]:
                span += " .. " + item["last"].strftime("%m-%d %H:%M")
            print(f"{item['n']:6d}  {kind} {code}  {detail}")
            print(f"        {span}")

    by_script = defaultdict(Counter)
    for e in events:
        if e["event"] in ("ai_ok", "ai_error"):
            by_script[e.get("script", "?")][e["event"]] += 1
    if by_script:
        print()
        print("BY EVALUATOR SCRIPT")
        print("-------------------")
        print(f"{'Script':46} {'Calls':>6} {'OK':>6} {'Errors':>6} {'Err %':>6}")
        for script, c in sorted(by_script.items(), key=lambda kv: -(kv[1]["ai_ok"] + kv[1]["ai_error"])):
            total = c["ai_ok"] + c["ai_error"]
            pct = 100.0 * c["ai_error"] / total if total else 0.0
            print(f"{script[:46]:46} {total:6d} {c['ai_ok']:6d} {c['ai_error']:6d} {pct:6.1f}")

    if end > start:
        by_day = defaultdict(Counter)
        for e in events:
            by_day[e["_dt"].date()][e["event"]] += 1
        print()
        print("DAY BY DAY")
        print("----------")
        print(f"{'Day':12} {'OK':>6} {'Errors':>6} {'No grade':>9} {'LMS fail':>9}")
        day = start
        while day <= end:
            c = by_day.get(day, Counter())
            print(f"{day.isoformat():12} {c['ai_ok']:6d} {c['ai_error']:6d} {c['no_grade']:9d} {c['lms_grade_failed']:9d}")
            day += timedelta(days=1)
    return 0


# --------------------------------------------------------------------------- watch
def read_tail(path, max_bytes=4_000_000):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as handle:
            if size > max_bytes:
                handle.seek(size - max_bytes)
                handle.readline()  # drop the partial first line
            return handle.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def recent_events(error_log):
    """AI-call events from the end of the current and previous (not compressed) error log."""
    events = []
    for path in (error_log + ".1", error_log):
        for line in read_tail(path).splitlines():
            event = parse_event_line(line)
            if event and event["event"] in ("ai_ok", "ai_error"):
                events.append(event)
    events.sort(key=lambda e: e["_dt"])
    return events


def load_state(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {"status": "OK"}


def save_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(state, handle)
    os.replace(tmp, path)


def send_mail(subject, body, log_dir, dry_run):
    """True = sent, False = configured but failed (retry later), None = e-mail not configured."""
    os.makedirs(log_dir, exist_ok=True)
    body_file = os.path.join(log_dir, "ai-alert.txt")
    with open(body_file, "w", encoding="utf-8") as handle:
        handle.write(body)
    if dry_run:
        print(f"[dry-run] {subject}\n{body}")
        return None
    if not all(os.environ.get(name) for name in ("MAIL_TO", "MAIL_FROM", "SMTP_HOST")):
        print(f"{subject}: e-mail not configured (MAIL_TO, MAIL_FROM, SMTP_HOST); alert saved in {body_file}")
        return None
    mail_bin = os.environ.get("LTI_HEALTH_MAIL_BIN", "/usr/local/sbin/lti-health-send-mail.py")
    result = subprocess.run([mail_bin, subject, body_file], capture_output=True, text=True)
    if result.returncode == 0:
        print(f"{subject}: e-mailed to {os.environ.get('MAIL_TO')}")
        return True
    print(f"{subject}: FAILED to e-mail ({result.stderr.strip() or 'exit ' + str(result.returncode)})", file=sys.stderr)
    return False


def describe(event):
    detail = " ".join(event.get("detail", "").split())
    return f"{event.get('kind', '?')} {event.get('code', '')}".strip() + (f" - {detail[:300]}" if detail else "")


def cmd_watch(args):
    needed = int(os.environ.get("AI_ALERT_CONSECUTIVE", "3"))
    window = timedelta(minutes=int(os.environ.get("AI_ALERT_WINDOW_MIN", "30")))
    log_dir = os.environ.get("LTI_HEALTH_LOG_DIR", "/var/log/lti-health")
    state_path = os.path.join(os.environ.get("LTI_HEALTH_STATE_DIR", "/var/lib/lti-health"), "ai-watch.state")
    now = datetime.fromisoformat(args.now) if args.now else datetime.now().astimezone()
    host = socket.gethostname()

    events = recent_events(args.error_log)
    state = load_state(state_path)
    last_n = [e for e in events if now - e["_dt"] <= window][-needed:]
    failing = len(last_n) >= needed and all(e["event"] == "ai_error" for e in last_n)
    exit_code = 0

    if state.get("status") != "ALERT" and failing:
        last_ok = next((e for e in reversed(events) if e["event"] == "ai_ok"), None)
        scripts = Counter(e.get("script", "?") for e in last_n)
        models = sorted({e.get("model", "?") for e in last_n})
        lines = [
            f"LTI AI Grader: the AI provider is failing on {host}",
            f"Detected at {now:%Y-%m-%d %H:%M:%S %z}",
            "",
            f"The last {len(last_n)} AI calls all failed "
            f"(first {last_n[0]['_dt']:%H:%M:%S}, last {last_n[-1]['_dt']:%H:%M:%S}).",
        ]
        if last_ok:
            lines.append(f"Last successful call: {last_ok['_dt']:%Y-%m-%d %H:%M:%S}")
        else:
            lines.append("No successful call found in the log tail.")
        lines += [
            "",
            f"Most recent error: {describe(last_n[-1])}",
            f"Model(s): {', '.join(models)}",
            f"Evaluators: {', '.join(f'{s} ({n})' for s, n in scripts.most_common())}",
            "",
            "Students currently get a server error instead of a correction.",
            "Check the provider status and run, on the server:",
            "  sudo grep 'event=ai_error' /var/log/nginx/error.log | tail -5",
            "You will get one more message when a call succeeds again.",
        ]
        body = "\n".join(lines) + "\n"
        sent = send_mail(f"ALERT: LTI AI Grader - AI provider failing ({len(last_n)} consecutive errors)",
                         body, log_dir, args.dry_run)
        if sent is False:
            exit_code = 1  # keep the state: it will be retried at the next run
        elif not args.dry_run:
            state = {"status": "ALERT", "since": last_n[0]["_dt"].isoformat(),
                     "last_failure": last_n[-1]["_dt"].isoformat()}
            save_state(state_path, state)

    elif state.get("status") == "ALERT":
        last_failure = datetime.fromisoformat(state.get("last_failure", state.get("since")))
        latest = events[-1] if events else None
        # ">=": timestamps have one-second resolution and the sort is stable, so an "ai_ok" that is the
        # last event in log order and shares the second of the last failure did happen after it.
        if latest and latest["event"] == "ai_ok" and latest["_dt"] >= last_failure:
            since = datetime.fromisoformat(state["since"])
            errors = sum(1 for e in events if e["event"] == "ai_error" and e["_dt"] >= since)
            body = (
                f"LTI AI Grader: the AI provider answers again on {host}\n"
                f"First successful call after the failures: {latest['_dt']:%Y-%m-%d %H:%M:%S %z}\n"
                f"Failures started at {since:%Y-%m-%d %H:%M:%S} ({errors} failed calls since then in the log tail).\n"
            )
            sent = send_mail("LTI AI Grader - AI provider recovered", body, log_dir, args.dry_run)
            if sent is False:
                exit_code = 1
            elif not args.dry_run:
                save_state(state_path, {"status": "OK"})
        elif events and events[-1]["event"] == "ai_error" and events[-1]["_dt"] > last_failure and not args.dry_run:
            state["last_failure"] = events[-1]["_dt"].isoformat()  # still failing: remember the latest failure
            save_state(state_path, state)

    return exit_code


# --------------------------------------------------------------------------- main
def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    report = sub.add_parser("report", help="print the events section for the daily/weekly reports")
    report.add_argument("--start", required=True, help="first day, YYYY-MM-DD")
    report.add_argument("--end", required=True, help="last day, YYYY-MM-DD")
    report.add_argument("--logs", default=os.environ.get("LTI_HEALTH_NGINX_ERROR_LOGS", DEFAULT_ERROR_LOGS),
                        help="glob of Nginx error logs")
    report.set_defaults(func=cmd_report)

    watch = sub.add_parser("watch", help="send an e-mail when the AI provider fails repeatedly")
    watch.add_argument("--error-log", default=os.environ.get("LTI_HEALTH_NGINX_ERROR_LOG", "/var/log/nginx/error.log"))
    watch.add_argument("--now", help="ISO time with offset, for testing")
    watch.add_argument("--dry-run", action="store_true", help="print instead of e-mailing; do not change state")
    watch.set_defaults(func=cmd_watch)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
