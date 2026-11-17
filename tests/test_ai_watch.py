"""Tests for `lti-health-ai-events.py watch`: the e-mail alerts on AI provider failures.

Two rules raise the alert:
  * consecutive: the last AI_ALERT_CONSECUTIVE (3) calls in the window all failed (the provider is down);
  * rate: at least AI_ALERT_RATE_FAILS (3) of the last AI_ALERT_RATE_OF (8) calls failed, with successes in
    between (the provider fails intermittently, which the first rule never sees).
A clean outage still ends with the first success; an intermittent one ends only when the rate rule no longer
holds, and after any recovery the failures up to then are ignored, so the alert does not come back at once.

Nothing is sent and nothing outside a temporary directory is touched: a fake mailer records each message.

Run:   python3 -m unittest tests.test_ai_watch -v      (or python3 tests/test_ai_watch.py)
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.environ.get("AI_EVENTS_SCRIPT", os.path.join(HERE, "..", "deploy", "monitoring", "lti-health-ai-events.py"))
NOW = datetime.fromisoformat("2026-11-16T12:00:00+01:00")


def event_line(minutes_ago, ok, kind="TimeoutError", code="", script="evaluate-b2.py"):
    ts = (NOW - timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%S%z")
    if ok:
        body = f"event=ai_ok ts={ts} script={script} provider=openai model=m ms=55000"
    else:
        body = (f"event=ai_error ts={ts} script={script} provider=openai model=m kind={kind} code={code} "
                f"ms=285000 detail=failure")
    # the way Nginx writes it into error.log
    return f'2026/11/16 11:00:00 [error] 1#1: *7 FastCGI sent in stderr: "[lti-ai-grader] {body}" while reading response header'


class WatchTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="aiwatch_")
        self.log = os.path.join(self.dir, "error.log")
        self.mails = os.path.join(self.dir, "mails.txt")
        self.mailer = os.path.join(self.dir, "mailer.sh")
        with open(self.mailer, "w") as f:
            f.write('#!/bin/sh\nprintf "=== SUBJECT: %s\\n" "$1" >> "' + self.mails + '"; cat "$2" >> "' + self.mails + '"\n')
        os.chmod(self.mailer, 0o755)
        self.lines = []
        self.clock = NOW - timedelta(minutes=60)     # time of the newest call added so far
        self.now = NOW

    def tearDown(self):
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)

    # ------------------------------------------------------------ helpers
    def add(self, pattern, step_min=2, **kind):
        """Append calls ('o' = ok, 'x' = error, oldest first), one every `step_min` minutes, and move the
        clock to one minute after the last one, as a real run of the watcher would see it."""
        for ch in pattern:
            self.clock += timedelta(minutes=step_min)
            minutes_ago = (NOW - self.clock).total_seconds() / 60
            self.lines.append(event_line(minutes_ago, ch == "o", **kind))
        self.now = self.clock + timedelta(minutes=1)
        with open(self.log, "w") as f:
            f.write("\n".join(self.lines) + "\n")

    def run_watch(self, **env):
        e = dict(os.environ, LTI_HEALTH_STATE_DIR=self.dir, LTI_HEALTH_LOG_DIR=self.dir, LTI_HEALTH_MAIL_BIN=self.mailer,
                 MAIL_TO="a@b.c", MAIL_FROM="x@y.z", SMTP_HOST="smtp.test")
        for k in ("AI_ALERT_CONSECUTIVE", "AI_ALERT_RATE_FAILS", "AI_ALERT_RATE_OF", "AI_ALERT_WINDOW_MIN"):
            e.pop(k, None)
        e.update(env)
        r = subprocess.run([sys.executable, SCRIPT, "watch", "--error-log", self.log, "--now", self.now.isoformat()],
                           env=e, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def subjects(self):
        if not os.path.exists(self.mails):
            return []
        with open(self.mails) as f:
            return [l[len("=== SUBJECT: "):] for l in f.read().splitlines() if l.startswith("=== SUBJECT: ")]

    def body(self):
        if not os.path.exists(self.mails):
            return ""
        with open(self.mails) as f:
            return f.read()

    def state(self):
        p = os.path.join(self.dir, "ai-watch.state")
        if not os.path.exists(p):
            return None
        with open(p) as f:
            return json.load(f)

    # ------------------------------------------------------------ the rule that already existed
    def test_healthy_provider_sends_nothing(self):
        self.add("oooooooooo")
        self.run_watch()
        self.assertEqual(self.subjects(), [])

    def test_three_consecutive_errors_alert_as_before(self):
        self.add("ooooxxx")
        self.run_watch()
        self.assertEqual(len(self.subjects()), 1)
        self.assertIn("3 consecutive errors", self.subjects()[0])
        self.assertEqual(self.state()["rule"], "consecutive")

    def test_a_clean_outage_recovers_at_the_first_success_and_does_not_alert_again(self):
        self.add("ooooxxx")
        self.run_watch()
        self.add("o")                                # the provider answers again
        self.run_watch()
        self.assertEqual(len(self.subjects()), 2)
        self.assertIn("recovered", self.subjects()[1])
        self.run_watch()                             # the old failures are still among the last 8 calls
        self.add("o")
        self.run_watch()
        self.assertEqual(len(self.subjects()), 2, "no new alert from failures that were already reported")

    def test_errors_that_arrived_before_the_recovery_are_not_counted_after_it(self):
        """The watcher runs every 5 minutes: errors logged between two runs must also be forgotten at the recovery."""
        self.add("ooooxxx")
        self.run_watch()                             # alert; the state remembers the third error
        self.add("xx")                               # two more errors, no run sees them
        self.add("o")
        self.run_watch()                             # recovered
        self.assertEqual(len(self.subjects()), 2)
        self.add("xxo")                              # 2 new errors: below the 3 needed
        self.run_watch()
        self.assertEqual(len(self.subjects()), 2, "the 4 old errors must not add up with the 2 new ones")

    # ------------------------------------------------------------ the new rule
    def test_intermittent_failures_alert_by_rate(self):
        self.add("oxoxooxo")                         # 3 errors in the last 8, never 3 in a row
        self.run_watch()
        self.assertEqual(len(self.subjects()), 1)
        self.assertIn("3 of the last 8 calls", self.subjects()[0])
        self.assertIn("intermittently", self.body())
        self.assertIn("Failures by cause: TimeoutError (3)", self.body())
        self.assertEqual(self.state()["rule"], "rate")

    def test_two_errors_in_the_last_eight_do_not_alert(self):
        self.add("ooxooxoo")
        self.run_watch()
        self.assertEqual(self.subjects(), [])

    def test_the_same_episode_sends_one_alert_not_one_per_run(self):
        self.add("oxoxooxo")
        for _ in range(4):
            self.run_watch()
        self.assertEqual(len(self.subjects()), 1)

    def test_old_failures_outside_the_window_are_ignored(self):
        self.lines = [event_line(45 + i, False) for i in range(4)] + [event_line(5 - i, True) for i in range(4)]
        with open(self.log, "w") as f:
            f.write("\n".join(self.lines) + "\n")
        self.run_watch()
        self.assertEqual(self.subjects(), [])

    def test_low_traffic_three_failures_in_four_calls_alert(self):
        self.add("xoxx")
        self.run_watch()
        self.assertEqual(len(self.subjects()), 1)
        self.assertIn("3 of the last 4 calls", self.subjects()[0])

    def test_intermittent_alert_is_not_ended_by_a_single_success(self):
        """The flapping the rate rule must not cause: alert, 'recovered', alert, 'recovered'..."""
        self.add("oxoxooxo")
        self.run_watch()
        self.add("o")                                # one success: the last 8 still hold 3 errors
        self.run_watch()
        self.assertEqual(len(self.subjects()), 1, "no 'recovered' while the rate rule still holds")
        self.add("ooooo")                            # enough successes push the errors out of the last 8
        self.run_watch()
        self.assertEqual(len(self.subjects()), 2)
        self.assertIn("recovered", self.subjects()[1])
        self.run_watch()
        self.assertEqual(len(self.subjects()), 2, "and nothing more after the recovery")

    def test_after_a_recovery_new_intermittent_failures_alert_again(self):
        self.add("oxoxooxo")
        self.run_watch()
        self.add("oooooo")
        self.run_watch()
        self.assertEqual(len(self.subjects()), 2)
        self.add("xox")                              # 2 new failures: not enough yet
        self.run_watch()
        self.assertEqual(len(self.subjects()), 2)
        self.add("ox")                               # the third new failure
        self.run_watch()
        self.assertEqual(len(self.subjects()), 3)
        self.assertIn("ALERT", self.subjects()[2])

    # ------------------------------------------------------------ configuration
    def test_rate_rule_can_be_turned_off(self):
        self.add("oxoxooxo")
        self.run_watch(AI_ALERT_RATE_FAILS="0")
        self.assertEqual(self.subjects(), [])

    def test_thresholds_can_be_changed(self):
        env = dict(AI_ALERT_RATE_FAILS="2", AI_ALERT_RATE_OF="4")
        self.add("ooxoxooo")                         # the last 4 hold 1 error
        self.run_watch(**env)
        self.assertEqual(self.subjects(), [])
        self.add("xox")                              # the last 4 are now "o","x","o","x" -> 2 errors
        self.run_watch(**env)
        self.assertEqual(len(self.subjects()), 1)
        self.assertIn("2 of the last 4 calls", self.subjects()[0])

    def test_causes_are_counted(self):
        self.lines = []
        for i in range(8):
            failed = i % 2 == 0
            self.lines.append(event_line(14 - 2 * i, not failed, kind="HTTPError" if i in (0, 4) else "TimeoutError",
                                         code="502" if i in (0, 4) else ""))
        with open(self.log, "w") as f:
            f.write("\n".join(self.lines) + "\n")
        self.run_watch()
        self.assertIn("HTTPError 502 (2)", self.body())
        self.assertIn("TimeoutError (2)", self.body())

    def test_state_file_from_before_this_change_behaves_as_before(self):
        with open(os.path.join(self.dir, "ai-watch.state"), "w") as f:
            json.dump({"status": "ALERT", "since": (NOW - timedelta(minutes=20)).isoformat(),
                       "last_failure": (NOW - timedelta(minutes=10)).isoformat()}, f)       # no "rule"
        self.lines = [event_line(14, False), event_line(12, False), event_line(10, False), event_line(1, True)]
        with open(self.log, "w") as f:
            f.write("\n".join(self.lines) + "\n")
        self.run_watch()
        self.assertEqual(len(self.subjects()), 1)
        self.assertIn("recovered", self.subjects()[0])
        self.assertEqual(self.state()["status"], "OK")


if __name__ == "__main__":
    unittest.main()
