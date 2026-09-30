#!/usr/bin/env python3
"""Send a plain-text monitoring report using SMTP settings from the environment."""

import os
import smtplib
import ssl
import sys
from email.message import EmailMessage


def truthy(value):
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} SUBJECT BODY_FILE", file=sys.stderr)
        return 2

    required = ["MAIL_TO", "MAIL_FROM", "SMTP_HOST"]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        print("Email skipped; missing: " + ", ".join(missing), file=sys.stderr)
        return 3

    subject, body_file = sys.argv[1], sys.argv[2]
    with open(body_file, "r", encoding="utf-8", errors="replace") as fh:
        body = fh.read()

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = os.environ["MAIL_FROM"]
    msg["To"] = os.environ["MAIL_TO"]
    msg.set_content(body)

    host = os.environ["SMTP_HOST"]
    use_ssl = truthy(os.environ.get("SMTP_SSL", "false"))
    port = int(os.environ.get("SMTP_PORT", "465" if use_ssl else "587"))
    user = os.environ.get("SMTP_USER", "")
    password = os.environ.get("SMTP_PASSWORD", "")
    starttls = truthy(os.environ.get("SMTP_STARTTLS", "true"))
    timeout = int(os.environ.get("SMTP_TIMEOUT", "20"))

    context = ssl.create_default_context()
    if use_ssl:
        smtp = smtplib.SMTP_SSL(host, port, timeout=timeout, context=context)
    else:
        smtp = smtplib.SMTP(host, port, timeout=timeout)

    with smtp:
        smtp.ehlo()
        if not use_ssl and starttls:
            smtp.starttls(context=context)
            smtp.ehlo()
        if user:
            smtp.login(user, password)
        smtp.send_message(msg)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
