"""Regression test: the OAuth 1.0 signature of the LTI grade passback must verify the way Open edX
(xblock-lti-consumer) verifies it.

History: aigrader.py percent-encoded the OAuth parameters with urllib.parse.quote(), which leaves '/'
unencoded. When the base64 oauth_body_hash contained a '/' (about 1 request in 3) Open edX computed a
different signature, raised "OAuth signature verification has failed" and answered HTTP 500, so the
grade never reached the gradebook.

Run:   python3 -m unittest discover -s tests -v          (needs: pip install oauthlib)
Other aigrader.py:   AIGRADER_PATH=/path/to/aigrader.py python3 -m unittest discover -s tests
"""
import base64
import hashlib
import importlib.util
import os
import random
import re
import sys
import unittest
import urllib.parse
import uuid
from types import SimpleNamespace
from unittest import mock

try:
    from oauthlib.oauth1.rfc5849 import signature
except ImportError:                                           # pragma: no cover
    signature = None

HERE = os.path.dirname(os.path.abspath(__file__))
AIGRADER = os.environ.get("AIGRADER_PATH", os.path.join(HERE, "..", "aigrader.py"))

OUTCOME_URL = ("https://lms.example.org/courses/course-v1:org+course+2026/xblock/"
               "block-v1:org+course+2026+type@lti_consumer+block@abc123/handler_noauth/outcome_service_handler")


def load_aigrader():
    """aigrader.py replaces sys.stdout when imported (UTF-8 for CGI); keep the test runner's stdout intact."""
    saved = sys.stdout
    spec = importlib.util.spec_from_file_location("aigrader_under_test", AIGRADER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module._wrapper_keepalive = sys.stdout                    # a reference keeps the wrapper (and its buffer) alive
    sys.stdout = saved
    return module


class FakeResponse:
    def getcode(self):
        return 200

    def read(self):
        return b"<imsx_codeMajor>success</imsx_codeMajor>"

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def verify_like_open_edx(request, secret, service_url):
    """Same checks as lti_consumer.lti_1p1.oauth.verify_oauth_body_signature (body hash + HMAC-SHA1)."""
    headers = {"Authorization": request.get_header("Authorization"), "Content-Type": "application/xml"}
    params = dict(signature.collect_parameters(headers=headers, exclude_oauth_signature=False))
    provided = params.pop("oauth_signature")
    body_hash = base64.b64encode(hashlib.sha1(request.data).digest()).decode("utf-8")
    if body_hash != params.get("oauth_body_hash"):
        return False
    signed = SimpleNamespace(uri=urllib.parse.unquote(service_url), http_method="POST",
                             params=list(params.items()), signature=provided)
    return signature.verify_hmac_sha1(signed, secret)


@unittest.skipIf(signature is None, "oauthlib is not installed (pip install oauthlib)")
class OAuthSignatureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.grader = load_aigrader()

    def send(self, secret, consumer_key="openedx_key", count=400, seed=2026):
        """Send `count` grades (random message identifiers => random body hashes) and verify each one."""
        rng = random.Random(seed)
        config = {"DEBUG": False, "LTI_ALLOWED_DOMAINS": "lms.example.org",
                  "lti_consumer_secrets": {consumer_key: secret}}
        captured, failures, with_slash = [], 0, 0

        def fake_urlopen(request, timeout=None):
            captured.append(request)
            return FakeResponse()

        for _ in range(count):
            captured.clear()
            with mock.patch("urllib.request.urlopen", fake_urlopen), \
                 mock.patch("uuid.uuid4", lambda: uuid.UUID(int=rng.getrandbits(128), version=4)):
                self.grader.send_grade_to_lti(OUTCOME_URL, "sourcedid-" + str(rng.random()), consumer_key,
                                              rng.random(), config)
            request = captured[0]
            sent_hash = urllib.parse.unquote(re.search(r'oauth_body_hash="([^"]+)"', request.get_header("Authorization")).group(1))
            with_slash += "/" in sent_hash
            if not verify_like_open_edx(request, secret, OUTCOME_URL):
                failures += 1
        return failures, with_slash

    def test_signature_verifies_for_every_body_hash(self):
        failures, with_slash = self.send("a-normal-secret")
        self.assertGreater(with_slash, 50, "the test must exercise body hashes that contain '/'")
        self.assertEqual(failures, 0, f"{failures} of 400 grades would be rejected by Open edX")

    def test_secret_and_consumer_key_with_special_characters(self):
        for secret, key in (("ab/cd/ef", "openedx_key"), ("a+b&c=d%e", "openedx_key"),
                            ("ñandú ~ok", "openedx_key"), ("secret", "org/course:key")):
            with self.subTest(secret=secret, key=key):
                failures, _ = self.send(secret, key, count=100)
                self.assertEqual(failures, 0)


if __name__ == "__main__":
    unittest.main()
