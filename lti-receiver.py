#!/usr/bin/env python3
#lti-receiver.py

#URL example https://yourserver.com/cgi-bin/lti-receiver.py?file=/C1-writing-correction-LTI.html

import cgi
import cgitb
import json
import os
import sys
import time
import random
import string
from urllib.parse import parse_qs

# ⚙️ GLOBAL CONFIGURATION
DEBUG = False
REDIRECT_URL = '/C1-writing-correction-LTI.html' # Default destination
SESSION_DIR = '/var/secure/lti_sessions'
SESSION_TIMEOUT = 3600

# LTI Allowed origins
ALLOWED_ORIGINS = [
    'https://youropenedx.com',
    'https://studio.youropenedx.com'
]

if DEBUG:
    cgitb.enable()

def ensure_session_dir():
    """Create directory and clean old files."""
    if not os.path.exists(SESSION_DIR):
        try:
            os.makedirs(SESSION_DIR, mode=0o700)
        except:
            pass
    
    # Garbage Collector (clean expired sessions)
    try:
        now = time.time()
        for f in os.listdir(SESSION_DIR):
            f_path = os.path.join(SESSION_DIR, f)
            if os.stat(f_path).st_mtime < (now - SESSION_TIMEOUT):
                os.remove(f_path)
    except:
        pass

def get_safe_redirect_url(params):
    """
    Makes URL only with HOST and file name,
    ignoring any path.
    """
    host = os.environ.get('HTTP_HOST') or os.environ.get('SERVER_NAME', 'localhost')
    
    requested_file = params.get('file', REDIRECT_URL)
    
    # Get only filename (basename) 
    # Gets rid of any / o ../
    safe_filename = os.path.basename(requested_file)
    
    # Clean URL: https://host/filename.html
    return f"https://{host}/{safe_filename}"

def generate_token():
    chars = string.ascii_letters + string.digits
    return ''.join(random.SystemRandom().choice(chars) for _ in range(32))

def save_session(token, lti_params):
    ensure_session_dir()
    session_data = {
        'lti_params': lti_params,
        'created_at': int(time.time()),
        'expires_at': int(time.time()) + SESSION_TIMEOUT
    }
    try:
        session_file = os.path.join(SESSION_DIR, token + ".json")
        with open(session_file, 'w') as f:
            json.dump(session_data, f)
        os.chmod(session_file, 0o600)
        return True
    except:
        return False

def get_all_params():
    params = {}
    if os.environ.get('QUERY_STRING'):
        get_params = parse_qs(os.environ['QUERY_STRING'])
        for key, values in get_params.items():
            params[key] = values[0] if len(values) == 1 else values
    if os.environ.get('REQUEST_METHOD') == 'POST':
        form = cgi.FieldStorage()
        for key in form.keys():
            value = form[key]
            if isinstance(value, list):
                params[key] = [item.value for item in value]
            else:
                params[key] = value.value
    return params

def validate_origin():
    referer = os.environ.get('HTTP_REFERER', '')
    origin = os.environ.get('HTTP_ORIGIN', '')
    method = os.environ.get('REQUEST_METHOD', 'GET')
    if method == 'GET' and not referer and not origin:
        return True
    for allowed in ALLOWED_ORIGINS:
        if referer.startswith(allowed) or origin == allowed:
            return True
    return False

def validate_lti(params):
    required = ['lis_outcome_service_url', 'lis_result_sourcedid']
    found = [p for p in required if p in params and params[p]]
    return {'is_valid': len(found) >= 2, 'found': found, 'total': len(params)}

def main():
    params = get_all_params()
    redirect_target = get_safe_redirect_url(params)

    origin_header = os.environ.get('HTTP_ORIGIN', '')
    allowed_origin = origin_header if origin_header in ALLOWED_ORIGINS else '*'

    print("Content-Type: text/html; charset=utf-8")
    print(f"Access-Control-Allow-Origin: {allowed_origin}")
    print("Access-Control-Allow-Methods: GET, POST, OPTIONS")
    print("Access-Control-Allow-Headers: Content-Type")
    print("Access-Control-Allow-Credentials: true")
    print()

    method = os.environ.get('REQUEST_METHOD', 'GET')
    if method == 'OPTIONS': return

    if method == 'POST' and not validate_origin():
        print("<html><body><h1>403 Forbidden</h1></body></html>")
        return

    # Debug info 
    referer = os.environ.get('HTTP_REFERER', 'No disponible')
    remote_addr = os.environ.get('REMOTE_ADDR', 'No disponible')

    # Info page if no parameters
    if method == 'GET' and not os.environ.get('QUERY_STRING'):
        print(f"<!DOCTYPE html><html><head><title>Activo</title></head><body><h1>✅ Receptor LTI Activo</h1><p>Destino: {redirect_target}</p></body></html>")
        return

    validation = validate_lti(params)
    token = generate_token()
    
    if validation['is_valid']:
        save_session(token, params)
        status_class, msg, delay, mode = 'success', '✅ LTI Session created', 1500, 'lti'
    elif validation['total'] > 0:
        save_session(token, params)
        status_class, msg, delay, mode = 'warning', '⚠️ Partial session created', 2000, 'partial'
    else:
        status_class, msg, delay, mode = 'error', '❌ Standalone mode', 2000, 'standalone'
        token = None

    debug_css = "" if DEBUG else ".origin-debug { display: none; }"

    print(f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <style>
        body {{ font-family: Arial; padding: 20px; text-align: center; background: #f5f5f5; }}
        .status-box {{ background: white; padding: 20px; border-radius: 5px; max-width: 600px; margin: 0 auto; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }}
        .success {{ color: #28a745; }} .warning {{ color: #ffc107; }} .error {{ color: #dc3545; }}
        .origin-debug {{ background: #eee; padding: 10px; margin-top: 20px; text-align: left; font-size: 11px; }}
        {debug_css}
    </style>
</head>
<body>
    <div class="status-box">
        <h2 class="{status_class}">{msg}</h2>
        <p>Cargando actividad...</p>
        <div class="origin-debug">Ref: {referer} | IP: {remote_addr}</div>
    </div>

    <script>
        const sessionData = {{
            token: {json.dumps(token)},
            mode: {json.dumps(mode)},
            target: {json.dumps(redirect_target)}
        }};

        if (sessionData.token) {{
            localStorage.setItem('lti_session_token', sessionData.token);
            sessionStorage.setItem('lti_session_token', sessionData.token);
        }}
        localStorage.setItem('lti_mode', sessionData.mode);
        
        setTimeout(() => {{
            try {{
                const url = new URL(sessionData.target);
                if (sessionData.token) url.searchParams.set('token', sessionData.token);
                url.searchParams.set('mode', sessionData.mode);
                window.location.href = url.toString();
            }} catch(e) {{
                window.location.href = sessionData.target + "?mode=" + sessionData.mode + (sessionData.token ? "&token=" + sessionData.token : "");
            }}
        }}, {delay});
    </script>
</body>
</html>""")

if __name__ == "__main__":

    main()
