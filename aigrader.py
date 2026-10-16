#!/usr/bin/python3
# -*- coding: utf-8 -*-

import json
import sys
import os
import time
import cgitb
import urllib.request
import urllib.parse
import urllib.error
import re
import hashlib
import hmac
import base64
import uuid
import io
from urllib.parse import urlparse

# Enforce UTF-8 to prevent formatting errors with long rubrics.
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

def setup_environment(debug_mode):
    if debug_mode:
        cgitb.enable()
    else:
        sys.tracebacklimit = 0

def log_debug(message, config):
    if config.get("DEBUG"):
        sys.stderr.write(f"[DEBUG] {message}\n")

def _clean_for_log(text):
    """Single line, no secrets (API keys in URLs, bearer tokens)."""
    text = re.sub(r"(?i)\b(key|api_key|token|access_token)=[^&\s\"']+", r"\1=***", str(text))
    text = re.sub(r"(?i)bearer\s+\S+", "Bearer ***", text)
    return re.sub(r"\s+", " ", text).strip()

def log_event(event, **fields):
    """Write ONE line per notable event to stderr, for the monitoring scripts.

    The web server keeps CGI stderr in its error log, so no extra file or permission is needed.
    Format:  [lti-ai-grader] event=ai_error ts=... script=... key=value ...
    Values are percent-encoded (no spaces or quotes) so a line is easy to parse.
    It never includes the student's text, and it must never break the grader.
    """
    try:
        parts = ["[lti-ai-grader]", f"event={event}",
                 "ts=" + time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                 "script=" + os.path.basename(sys.argv[0])]
        for key, value in fields.items():
            if value is None or value == "":
                continue
            parts.append(f"{key}=" + urllib.parse.quote(_clean_for_log(value)[:300], safe="._-:/,"))
        sys.stderr.write(" ".join(parts) + "\n")
        sys.stderr.flush()
    except Exception:
        pass

def _provider_error_message(body):
    """Pull the human-readable message out of an API error body (JSON), else the raw text."""
    try:
        data = json.loads(body)
        err = data.get("error", data) if isinstance(data, dict) else data
        if isinstance(err, dict):
            return err.get("message") or json.dumps(err)
        return str(err)
    except Exception:
        return body

def is_safe_url(url, allowed_domains_str):
    try:
        if not url:
            return False, "URL vacía"
        parsed_url = urlparse(url)
        if parsed_url.scheme != 'https':
            return False, "Only HTTPS connections"
        allowed_list = [d.strip().lower() for d in allowed_domains_str.split(",") if d.strip()]
        domain = (parsed_url.hostname or parsed_url.netloc).lower()
        if any(domain == d or domain.endswith('.' + d) for d in allowed_list):
            return True, url
        return False, f"Non authorised domain: {domain}"
    except Exception as e:
        sys.stderr.write(f"[DEBUG is_safe_url ERROR] {type(e).__name__}: {str(e)}\n")
        return False, "Error in URL processing"

def extract_flexible_grade(text, grade_identifier):
    try:
        pattern = rf"{re.escape(grade_identifier)}[:\s]*([\d.]+)\s*/\s*([\d.]+)"
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return float(match.group(1)), float(match.group(2))
    except Exception:
        pass
    return None, None

def _outcome_url_problem(url):
    """Why was the outcome URL rejected? -> (reason, domain). Never raises."""
    try:
        if not url:
            return "no_outcome_url", None
        parsed = urlparse(url)
        if not parsed.hostname:
            return "url_without_domain", None      # relative URL, typical of launches from Studio
        if parsed.scheme != "https":
            return "url_not_https", parsed.hostname
        return "domain_not_allowed", parsed.hostname
    except Exception:
        return "url_invalid", None

def send_grade_to_lti(outcome_url, result_sourcedid, consumer_key, score_normalized, config):
    try:
        log_debug(f"Iniciando envio de nota LTI a: {outcome_url}", config)

        is_safe, final_url = is_safe_url(outcome_url, config.get("LTI_ALLOWED_DOMAINS", ""))
        if not is_safe:
            log_debug(f"URL rechazada por is_safe_url. Permitidos: {config.get('LTI_ALLOWED_DOMAINS')}", config)
            reason, domain = _outcome_url_problem(outcome_url)
            log_event("lms_grade_failed", reason=reason, domain=domain)
            return False

        secret = config.get("lti_consumer_secrets", {}).get(consumer_key)
        if not secret:
            log_debug(f"No hay secret configurado para consumer_key: '{consumer_key}'", config)
            log_event("lms_grade_failed", reason="no_secret", consumer_key=consumer_key)
            return False

        xml_body = f"""<?xml version="1.0" encoding="UTF-8"?>
<imsx_POXEnvelopeRequest xmlns="http://www.imsglobal.org/services/ltiv1p1/xsd/imsoms_v1p0">
  <imsx_POXHeader><imsx_POXRequestHeaderInfo><imsx_version>V1.0</imsx_version>
  <imsx_messageIdentifier>{uuid.uuid4()}</imsx_messageIdentifier></imsx_POXRequestHeaderInfo></imsx_POXHeader>
  <imsx_POXBody><replaceResultRequest><resultRecord>
  <sourcedGUID><sourcedId>{result_sourcedid}</sourcedId></sourcedGUID>
  <result><resultScore><language>en</language><textString>{float(score_normalized):.4f}</textString></resultScore></result>
  </resultRecord></replaceResultRequest></imsx_POXBody></imsx_POXEnvelopeRequest>"""

        body_hash = base64.b64encode(hashlib.sha1(xml_body.encode('utf-8')).digest()).decode('utf-8')
        oauth_params = {
            'oauth_body_hash': body_hash,
            'oauth_consumer_key': consumer_key,
            'oauth_nonce': uuid.uuid4().hex,
            'oauth_signature_method': 'HMAC-SHA1',
            'oauth_timestamp': str(int(time.time())),
            'oauth_version': '1.0',
        }
        encoded_url = urllib.parse.quote(final_url, safe='')
        sorted_params = '&'.join([f"{urllib.parse.quote(k)}={urllib.parse.quote(v)}" for k, v in sorted(oauth_params.items())])
        base_string = f"POST&{encoded_url}&{urllib.parse.quote(sorted_params)}"
        signing_key = f"{urllib.parse.quote(secret)}&".encode('utf-8')
        signature = base64.b64encode(hmac.new(signing_key, base_string.encode('utf-8'), hashlib.sha1).digest()).decode('utf-8')
        oauth_params['oauth_signature'] = signature
        auth_header = 'OAuth ' + ', '.join([f'{k}="{urllib.parse.quote(v)}"' for k, v in oauth_params.items()])

        req = urllib.request.Request(
            final_url,
            data=xml_body.encode('utf-8'),
            headers={'Content-Type': 'application/xml', 'Authorization': auth_header}
        )

        with urllib.request.urlopen(req, timeout=15) as response:
            res_code = response.getcode()
            res_body = response.read().decode('utf-8', errors='ignore')
            log_debug(f"Respuesta de Open edX -> Code: {res_code}, Body: {res_body}", config)
            if res_code != 200:
                log_event("lms_grade_failed", reason="unexpected_status", code=res_code)
            elif re.search(r"<imsx_codeMajor>\s*failure", res_body, re.IGNORECASE):
                # LTI Basic Outcomes: HTTP 200 can still carry "failure". The return value is unchanged.
                description = re.search(r"<imsx_description>(.*?)</imsx_description>", res_body, re.IGNORECASE | re.DOTALL)
                log_event("lms_grade_failed", reason="lms_reported_failure",
                          detail=description.group(1) if description else "")
            return res_code == 200

    except urllib.error.HTTPError as e:
        err_body = e.read().decode('utf-8', errors='ignore') if e.fp else ""
        log_debug(f"HTTPError al conectar con Open edX -> {e.code} {e.reason}: {err_body}", config)
        log_event("lms_grade_failed", reason="http_error", code=e.code, detail=err_body)
        return False
    except Exception as e:
        log_debug(f"Excepcion en send_grade_to_lti -> {type(e).__name__}: {str(e)}", config)
        log_event("lms_grade_failed", reason="exception", kind=type(e).__name__, detail=str(e))
        return False

def call_ai_api(student_input, config):
    provider = config.get("provider", "openai").lower()
    started = time.monotonic()
    try:
        if provider == "openai":
            url = config.get("api_url", "https://api.openai.com").rstrip('/')
            if "/chat/completions" not in url:
                url += "/v1/chat/completions"

            headers = {"Content-Type": "application/json", "Authorization": f"Bearer {config['api_key']}"}
            body = {
                "model": config["model_name"],
                "messages": [
                    {"role": "system", "content": config["system_instructions"]},
                    {"role": "user", "content": f"Student Text:\n{student_input}"}
                ],
                "temperature": 0.2
            }
        else: # Google
            url = f"https://generativelanguage.googleapis.com/v1beta/models/{config['model_name']}:generateContent?key={config['api_key']}"
            headers = {'Content-Type': 'application/json'}
            body = {"contents": [{"parts": [{"text": f"{config['system_instructions']}\n\nStudent Text:\n{student_input}"}]}]}

        req = urllib.request.Request(url, data=json.dumps(body).encode('utf-8'), headers=headers, method='POST')
        with urllib.request.urlopen(req, timeout=config.get("api_timeout", 300)) as response:
            res = json.loads(response.read().decode('utf-8'))
            if provider == "openai":
                feedback = res['choices'][0]['message']['content']
            else:
                feedback = res['candidates'][0]['content']['parts'][0]['text']
            log_event("ai_ok", provider=provider, model=config.get("model_name"),
                      ms=int((time.monotonic() - started) * 1000))
            return {'success': True, 'feedback': feedback}
    except Exception as e:
        detail = ""
        if isinstance(e, urllib.error.HTTPError):
            try:
                detail = _provider_error_message(e.read().decode("utf-8", "replace"))
            except Exception:
                detail = ""
        log_event("ai_error", provider=provider, model=config.get("model_name"),
                  kind=type(e).__name__, code=getattr(e, "code", None),
                  ms=int((time.monotonic() - started) * 1000), detail=detail or str(e))
        return {'success': False, 'error': str(e)}

def run(config):
    setup_environment(config.get("DEBUG", False))

    origin = os.environ.get('HTTP_ORIGIN', '')
    allowed_config = config.get("CORS_ALLOWED_ORIGINS", "*")
    header_origin = origin if allowed_config == "*" or origin in [d.strip() for d in allowed_config.split(",")] else "null"

    # Encabezados CGI
    sys.stdout.write("Content-Type: application/json; charset=utf-8\n")
    sys.stdout.write(f"Access-Control-Allow-Origin: {header_origin}\n")
    sys.stdout.write("Access-Control-Allow-Methods: POST, OPTIONS\n")
    sys.stdout.write("Access-Control-Allow-Headers: Content-Type\n\n")
    sys.stdout.flush()

    if os.environ.get('REQUEST_METHOD') == 'OPTIONS':
        return

    try:
        content_length = int(os.environ.get('CONTENT_LENGTH', 0))
        raw_data = sys.stdin.read(content_length)
        data = json.loads(raw_data)

        student_input = data.get('studentInput', '').strip()
        default_value = data.get('defaultValue', '').strip()
        session_token = data.get('session_token') or data.get('token', '')

        # Verificación previa
        clean_input = re.sub(r'\s+', '', student_input)
        clean_default = re.sub(r'\s+', '', default_value)

        if not student_input or clean_input == clean_default:
            sys.stdout.write(json.dumps({
                'success': True,
                'feedback': data.get('emptyErrorMsg', 'Error: Empty submission'),
                'score_info': {'score': 0, 'max': 5},
                'lti_notified': False
            }, ensure_ascii=False))
            return

        result = call_ai_api(student_input, config)

        if result.get('success'):
            feedback = result['feedback']
            score, maximum = extract_flexible_grade(feedback, config['grade_identifier'])
            grade_sent = False
            if score is None:
                log_event("no_grade", model=config.get("model_name"))

            if session_token and score is not None:
                token_file = f"{session_token}.json"
                session_path = os.path.normpath(os.path.join(config["session_dir"], token_file))
                if session_path.startswith(os.path.abspath(config["session_dir"])) and os.path.exists(session_path):
                    with open(session_path, 'r') as f:
                        session_data = json.load(f)
                    lti_params = session_data.get('lti_params', {})
                    if config.get("send_grade_to_lms") and lti_params:
                        grade_sent = send_grade_to_lti(
                            lti_params.get('lis_outcome_service_url'),
                            lti_params.get('lis_result_sourcedid'),
                            lti_params.get('oauth_consumer_key'),
                            score/maximum if maximum > 0 else 0,
                            config
                        )
                else:
                    log_event("session_missing")

            sys.stdout.write(json.dumps({
                'success': True, 'feedback': feedback,
                'score_info': {'score': score, 'max': maximum},
                'lti_notified': grade_sent
            }, ensure_ascii=False))
        else:
            sys.stdout.write(json.dumps({'success': False, 'error': result.get('error')}))

    except Exception as e:
        log_event("cgi_error", kind=type(e).__name__, detail=str(e))
        sys.stdout.write(json.dumps({'success': False, 'error': str(e)}))

    sys.stdout.flush()

