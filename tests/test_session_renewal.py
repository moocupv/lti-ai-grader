"""Regression tests for the LTI session handling in aigrader.py and lti-receiver.py.

Background: lti-receiver.py saves a session file (outcome URL and result id) when the student opens the
activity, and deletes sessions that have not been modified for SESSION_TIMEOUT. aigrader.py used to read
that file only AFTER the AI answered and never renewed it, so a student who evaluated more than an hour
after opening the activity (or whose correction took minutes while someone else launched an activity and
triggered the cleanup) got the correction but no grade, and nothing was reported.

Run:   python3 -m unittest discover -s tests -v      (or python3 tests/test_session_renewal.py)
"""
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
HOUR = 3600


def load_module(name, filename):
    """aigrader.py replaces sys.stdout when imported (UTF-8 for CGI); keep the test runner's stdout intact."""
    saved = sys.stdout
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module._wrapper_keepalive = sys.stdout
    sys.stdout = saved
    return module


LTI_PARAMS = {"lis_outcome_service_url": "https://lms.example.org/outcome", "lis_result_sourcedid": "sid-1",
              "oauth_consumer_key": "openedx_key"}


class SessionHandlingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.g = load_module("aigrader_session_test", "aigrader.py")

    def setUp(self):
        g = self.g
        self.dir = tempfile.mkdtemp(prefix="lti_sessions_")
        self.events, self.sent, self.ai_calls = [], [], []
        self._saved = {k: getattr(g, k) for k in ("log_event", "send_grade_to_lti", "call_ai_api", "setup_environment")}
        g.log_event = lambda event, **fields: self.events.append((event, fields))
        g.setup_environment = lambda debug: None

        def fake_send(url, sourcedid, key, score, config):
            self.sent.append((url, sourcedid, key, score))
            return True

        g.send_grade_to_lti = fake_send
        self.ai_hook = None

        def fake_ai(text, config):
            self.ai_calls.append(text)
            if self.ai_hook:
                self.ai_hook()                      # e.g. the session file disappears while the AI is "thinking"
            return self.ai_result

        g.call_ai_api = fake_ai
        self.ai_result = {"success": True, "feedback": "Good work.\nNOTA_FINAL: 3/5"}

    def tearDown(self):
        for k, v in self._saved.items():
            setattr(self.g, k, v)
        shutil.rmtree(self.dir, ignore_errors=True)

    # ------------------------------------------------------------ helpers
    def make_session(self, token="tok1", age_s=0, content=None):
        path = os.path.join(self.dir, token + ".json")
        with open(path, "w") as f:
            f.write(content if content is not None else json.dumps({"lti_params": LTI_PARAMS}))
        old = time.time() - age_s
        os.utime(path, (old, old))
        return path

    def run_cgi(self, body, **cfg):
        config = {"DEBUG": False, "CORS_ALLOWED_ORIGINS": "*", "grade_identifier": "NOTA_FINAL", "session_dir": self.dir,
                  "send_grade_to_lms": True, "model_name": "m"}
        config.update(cfg)
        raw = json.dumps(body)
        env = {"REQUEST_METHOD": "POST", "CONTENT_LENGTH": str(len(raw.encode()))}
        saved_env = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        saved_io = sys.stdin, sys.stdout
        sys.stdin, sys.stdout = io.StringIO(raw), io.StringIO()
        try:
            self.g.run(config)
            out = sys.stdout.getvalue()
        finally:
            sys.stdin, sys.stdout = saved_io
            for k, v in saved_env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        return json.loads(out.split("\n\n", 1)[1])

    def names(self):
        return [e for e, _ in self.events]

    # ------------------------------------------------------------ tests
    def test_fresh_session_sends_the_grade(self):
        self.make_session()
        out = self.run_cgi({"studentInput": "my text", "token": "tok1"})
        self.assertTrue(out["success"])
        self.assertTrue(out["lti_notified"])
        self.assertEqual(self.sent, [("https://lms.example.org/outcome", "sid-1", "openedx_key", 0.6)])
        self.assertEqual(self.names(), [])

    def test_using_the_session_renews_it(self):
        path = self.make_session(age_s=7 * HOUR + 3000)        # almost expired for an 8 h timeout
        self.run_cgi({"studentInput": "my text", "token": "tok1"})
        self.assertLess(time.time() - os.path.getmtime(path), 60, "the file's modification time was not refreshed")

    def test_session_deleted_while_the_ai_is_thinking_still_sends_the_grade(self):
        """The root cause of the lost grades: the cleanup removed the file during a long correction."""
        path = self.make_session()
        self.ai_hook = lambda: os.remove(path)
        out = self.run_cgi({"studentInput": "my text", "token": "tok1"})
        self.assertFalse(os.path.exists(path))
        self.assertTrue(out["lti_notified"], "the grade must be sent with the parameters read before the AI call")
        self.assertEqual(len(self.sent), 1)
        self.assertNotIn("session_missing", self.names())

    def test_missing_session_reports_why_the_grade_was_not_sent(self):
        out = self.run_cgi({"studentInput": "my text", "token": "nothere"})
        self.assertTrue(out["success"], "the student still gets the correction")
        self.assertFalse(out["lti_notified"])
        self.assertEqual(self.sent, [])
        self.assertEqual(self.names(), ["session_missing", "lms_grade_failed"])
        self.assertEqual(self.events[1][1], {"reason": "no_session"})

    def test_missing_session_without_lms_grading_is_not_a_failure(self):
        self.run_cgi({"studentInput": "my text", "token": "nothere"}, send_grade_to_lms=False)
        self.assertEqual(self.names(), ["session_missing"])

    def test_no_token_standalone_use_has_no_session_events(self):
        out = self.run_cgi({"studentInput": "my text"})
        self.assertTrue(out["success"])
        self.assertEqual(self.names(), [])
        self.assertEqual(self.sent, [])

    def test_damaged_session_file_counts_as_missing_instead_of_crashing(self):
        self.make_session(content="{not json")
        out = self.run_cgi({"studentInput": "my text", "token": "tok1"})
        self.assertTrue(out["success"])
        self.assertEqual(self.names(), ["session_missing", "lms_grade_failed"])
        self.assertNotIn("cgi_error", self.names())

    def test_token_cannot_point_outside_the_session_directory(self):
        outside = os.path.join(os.path.dirname(self.dir), os.path.basename(self.dir) + "_evil")
        os.makedirs(outside)
        try:
            with open(os.path.join(outside, "x.json"), "w") as f:
                json.dump({"lti_params": LTI_PARAMS}, f)
            for token in ("../" + os.path.basename(outside) + "/x", "/etc/passwd", "../../../etc/passwd"):
                self.sent.clear()
                self.events.clear()
                out = self.run_cgi({"studentInput": "my text", "token": token})
                self.assertFalse(out["lti_notified"], token)
                self.assertEqual(self.sent, [], token)
                self.assertIn("session_missing", self.names(), token)
        finally:
            shutil.rmtree(outside, ignore_errors=True)

    def test_no_grade_line_in_the_answer_does_not_report_a_session_problem(self):
        self.ai_result = {"success": True, "feedback": "A correction without a grade line"}
        out = self.run_cgi({"studentInput": "my text", "token": "nothere"})
        self.assertTrue(out["success"])
        self.assertEqual(self.names(), ["no_grade"])      # as before the change: only the missing grade line is reported
        self.assertEqual(self.sent, [])

    def test_ai_failure_keeps_the_session_alive_for_the_retry(self):
        path = self.make_session(age_s=2 * HOUR)
        self.ai_result = {"success": False, "error": "provider down"}
        out = self.run_cgi({"studentInput": "my text", "token": "tok1"})
        self.assertFalse(out["success"])
        self.assertLess(time.time() - os.path.getmtime(path), 60)
        self.assertEqual(self.sent, [])

    def test_empty_submission_does_not_call_the_ai_nor_touch_the_session(self):
        path = self.make_session(age_s=2 * HOUR)
        before = os.path.getmtime(path)
        out = self.run_cgi({"studentInput": "   ", "token": "tok1"})
        self.assertTrue(out["success"])
        self.assertEqual(self.ai_calls, [])
        self.assertEqual(os.path.getmtime(path), before)


class ReceiverCleanupTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        saved = sys.stdout
        spec = importlib.util.spec_from_file_location("lti_receiver_test", os.path.join(ROOT, "lti-receiver.py"))
        cls.r = importlib.util.module_from_spec(spec)
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)      # `import cgi`
            spec.loader.exec_module(cls.r)
        sys.stdout = saved

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="lti_sessions_")
        self.saved_dir = self.r.SESSION_DIR
        self.r.SESSION_DIR = self.dir

    def tearDown(self):
        self.r.SESSION_DIR = self.saved_dir
        shutil.rmtree(self.dir, ignore_errors=True)

    def make(self, name, age_s):
        path = os.path.join(self.dir, name)
        open(path, "w").write("{}")
        old = time.time() - age_s
        os.utime(path, (old, old))

    def test_sessions_live_for_the_configured_time_not_for_one_hour(self):
        self.assertGreaterEqual(self.r.SESSION_TIMEOUT, 4 * HOUR)
        self.make("two_hours.json", 2 * HOUR)
        self.make("seven_hours.json", 7 * HOUR)
        self.make("nine_hours.json", 9 * HOUR)
        self.r.ensure_session_dir()
        left = sorted(os.listdir(self.dir))
        self.assertEqual(left, ["seven_hours.json", "two_hours.json"], "only sessions older than the timeout are removed")

    def test_a_renewed_session_survives_the_cleanup(self):
        self.make("used.json", 9 * HOUR)
        os.utime(os.path.join(self.dir, "used.json"), None)          # what aigrader.py does when it is used
        self.r.ensure_session_dir()
        self.assertEqual(os.listdir(self.dir), ["used.json"])


if __name__ == "__main__":
    unittest.main()
