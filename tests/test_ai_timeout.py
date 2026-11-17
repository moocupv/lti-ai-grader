"""Tests for how aigrader.py reports an AI call that ended because the provider did not answer in time.

When the call exceeds `api_timeout` the exception text is technical and in English ("The read operation timed
out"). The service now adds `error_code: "ai_timeout"` to its answer, so that aigrader.js can show a clear
message in the student's language. Any other failure keeps its text and gets no code, and an HTTP error
(the provider DID answer, even if its own message says "timed out") is not a timeout of ours.

Run:   python3 -m unittest tests.test_ai_timeout -v      (or python3 tests/test_ai_timeout.py)
"""
import importlib.util
import io
import json
import os
import socket
import sys
import unittest
import urllib.error
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))


def load_aigrader():
    """aigrader.py replaces sys.stdout when imported (UTF-8 for CGI); keep the test runner's stdout intact."""
    saved = sys.stdout
    spec = importlib.util.spec_from_file_location("aigrader_timeout_test", os.path.join(ROOT, "aigrader.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module._wrapper_keepalive = sys.stdout
    sys.stdout = saved
    return module


CONFIG = {"DEBUG": False, "CORS_ALLOWED_ORIGINS": "*", "provider": "openai", "api_url": "https://ai.example.org",
          "api_key": "k", "model_name": "m", "system_instructions": "s", "grade_identifier": "NOTA_FINAL",
          "api_timeout": 285}


def http_error(code, message="upstream request timed out"):
    return urllib.error.HTTPError("https://ai.example.org", code, "err", {}, io.BytesIO(json.dumps({"error": {"message": message}}).encode()))


class AiTimeoutTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.g = load_aigrader()

    def setUp(self):
        self.events = []
        self._log = self.g.log_event
        self.g.log_event = lambda event, **fields: self.events.append((event, fields))

    def tearDown(self):
        self.g.log_event = self._log

    def call(self, exception):
        with mock.patch("urllib.request.urlopen", side_effect=exception):
            return self.g.call_ai_api("my text", dict(CONFIG))

    # ------------------------------------------------------------ what counts as a timeout
    def test_read_timeout_has_the_code(self):
        out = self.call(socket.timeout("The read operation timed out"))
        self.assertFalse(out["success"])
        self.assertEqual(out["error_code"], "ai_timeout")
        self.assertIn("timed out", out["error"])            # the technical text is still there

    def test_builtin_timeout_error_has_the_code(self):
        self.assertEqual(self.call(TimeoutError("x"))["error_code"], "ai_timeout")

    def test_connect_timeout_wrapped_in_urlerror_has_the_code(self):
        self.assertEqual(self.call(urllib.error.URLError(socket.timeout("timed out")))["error_code"], "ai_timeout")

    def test_urlerror_whose_reason_is_text_has_the_code(self):
        self.assertEqual(self.call(urllib.error.URLError("timed out"))["error_code"], "ai_timeout")

    # ------------------------------------------------------------ what does not
    def test_http_error_is_not_our_timeout_even_if_its_message_says_so(self):
        out = self.call(http_error(504, "upstream request timed out"))
        self.assertFalse(out["success"])
        self.assertNotIn("error_code", out)

    def test_connection_refused_has_no_code(self):
        self.assertNotIn("error_code", self.call(ConnectionRefusedError("refused")))

    def test_any_other_failure_has_no_code(self):
        self.assertNotIn("error_code", self.call(ValueError("boom")))

    def test_the_failure_is_still_logged_for_the_health_reports(self):
        self.call(socket.timeout("The read operation timed out"))
        self.assertEqual(self.events[0][0], "ai_error")
        self.assertIn(self.events[0][1]["kind"], ("timeout", "TimeoutError"))

    # ------------------------------------------------------------ what the page receives
    def run_cgi(self, exception):
        raw = json.dumps({"studentInput": "my text"})
        env = {"REQUEST_METHOD": "POST", "CONTENT_LENGTH": str(len(raw.encode()))}
        saved_env = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        saved_io = sys.stdin, sys.stdout
        sys.stdin, sys.stdout = io.StringIO(raw), io.StringIO()
        setup = self.g.setup_environment
        self.g.setup_environment = lambda debug: None
        try:
            with mock.patch("urllib.request.urlopen", side_effect=exception):
                self.g.run(dict(CONFIG))
            out = sys.stdout.getvalue()
        finally:
            sys.stdin, sys.stdout = saved_io
            self.g.setup_environment = setup
            for k, v in saved_env.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        return json.loads(out.split("\n\n", 1)[1])

    def test_the_page_gets_the_code_on_a_timeout(self):
        answer = self.run_cgi(socket.timeout("The read operation timed out"))
        self.assertEqual(answer["success"], False)
        self.assertEqual(answer["error_code"], "ai_timeout")
        self.assertIn("timed out", answer["error"])

    def test_the_page_gets_no_code_on_other_failures(self):
        answer = self.run_cgi(http_error(502, "Bad Gateway"))
        self.assertEqual(answer["success"], False)
        self.assertNotIn("error_code", answer)


if __name__ == "__main__":
    unittest.main()
