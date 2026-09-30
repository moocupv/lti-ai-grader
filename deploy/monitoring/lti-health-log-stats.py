#!/usr/bin/env python3
"""Summarize LTI launches and evaluator requests from Nginx access logs."""

import argparse
import gzip
import glob
import os
import re
from collections import Counter, defaultdict
from datetime import date
from urllib.parse import parse_qs, unquote, urlsplit

MONTHS = {
    "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
    "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
}

LINE_RE = re.compile(
    r'^\S+ \S+ \S+ \[(?P<day>\d{2})/(?P<mon>[A-Z][a-z]{2})/(?P<year>\d{4}):[^]]+\] '
    r'"(?P<method>\S+) (?P<target>\S+) [^"]+" (?P<status>\d{3}) \S+ '
    r'"(?P<referer>[^"]*)"'
)

STATUS_COLUMNS = (200, 429, 499, 500, 502, 503, 504)


def open_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, "rt", encoding="utf-8", errors="replace")


def line_date(match):
    mon = MONTHS.get(match.group("mon"))
    if mon is None:
        return None
    return date(int(match.group("year")), mon, int(match.group("day")))


def normalize_activity_from_referer(referer):
    if not referer or referer == "-":
        return "UNATTRIBUTED"
    try:
        parsed = urlsplit(referer)
    except ValueError:
        return "UNATTRIBUTED"
    path = unquote(parsed.path or "/")
    if path == "/":
        return "UNATTRIBUTED"
    return path


def launch_activity(target):
    try:
        parsed = urlsplit(target)
        values = parse_qs(parsed.query).get("file", [])
    except ValueError:
        return "UNATTRIBUTED"
    if not values:
        return "UNATTRIBUTED"
    value = unquote(values[0]).strip()
    if not value:
        return "UNATTRIBUTED"
    if not value.startswith("/"):
        value = "/" + value
    return value.split("?", 1)[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--start", required=True, help="First date, YYYY-MM-DD")
    parser.add_argument("--end", required=True, help="Last date, YYYY-MM-DD")
    parser.add_argument("--logs", default="/var/log/nginx/access.log*")
    args = parser.parse_args()

    start = date.fromisoformat(args.start)
    end = date.fromisoformat(args.end)
    if end < start:
        parser.error("--end must be on or after --start")

    launches = Counter()
    corrections = Counter()
    statuses = defaultdict(Counter)
    evaluators = Counter()
    total_launches = 0
    total_corrections = 0

    for path in sorted(glob.glob(args.logs)):
        if not os.path.isfile(path):
            continue
        try:
            fh = open_text(path)
        except OSError:
            continue
        with fh:
            for line in fh:
                match = LINE_RE.match(line)
                if not match:
                    continue
                d = line_date(match)
                if d is None or d < start or d > end:
                    continue

                target = match.group("target")
                status = int(match.group("status"))

                if "/cgi-bin/lti-receiver.py" in target:
                    activity = launch_activity(target)
                    launches[activity] += 1
                    total_launches += 1

                if "/cgi-bin/evaluate-" in target:
                    activity = normalize_activity_from_referer(match.group("referer"))
                    corrections[activity] += 1
                    statuses[activity][status] += 1
                    script = urlsplit(target).path.rsplit("/", 1)[-1]
                    evaluators[script] += 1
                    total_corrections += 1

    activities = sorted(set(launches) | set(corrections), key=lambda x: (-(launches[x] + corrections[x]), x))

    print("USAGE BY ACTIVITY")
    print("-----------------")
    header = f"{'Activity':44} {'Launches':>8} {'Corrections':>11} {'200':>6} {'429':>6} {'499':>6} {'500':>6} {'502':>6} {'503':>6} {'504':>6} {'Other':>6}"
    print(header)
    for activity in activities:
        known = sum(statuses[activity][code] for code in STATUS_COLUMNS)
        other = corrections[activity] - known
        print(
            f"{activity[:44]:44} {launches[activity]:8d} {corrections[activity]:11d} "
            + " ".join(f"{statuses[activity][code]:6d}" for code in STATUS_COLUMNS)
            + f" {other:6d}"
        )
    if not activities:
        print("No LTI activity found in the selected period.")

    print()
    print("CORRECTIONS BY EVALUATOR")
    print("------------------------")
    if evaluators:
        for script, count in evaluators.most_common():
            print(f"{count:8d}  {script}")
    else:
        print("No evaluator requests found in the selected period.")

    print()
    print("TOTALS")
    print("------")
    print(f"LTI launches: {total_launches}")
    print(f"Corrections:  {total_corrections}")
    for code in STATUS_COLUMNS:
        count = sum(c[code] for c in statuses.values())
        print(f"HTTP {code}:     {count}")
    other_total = total_corrections - sum(sum(c[code] for code in STATUS_COLUMNS) for c in statuses.values())
    print(f"Other HTTP:   {other_total}")


if __name__ == "__main__":
    main()
