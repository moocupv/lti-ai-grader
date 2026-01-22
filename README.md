# LTI AI Grader: Deployment & Configuration Instructions

This document provides technical instructions for the deployment and maintenance of the **LTI AI Grader**. This system utilizes a decoupled architecture to leverage a Large Language Model (LLM) to grade tasks and send the grades to a Learning Management System (LMS) using LTI 1.1 via the standard CGI-bin.

The system is highly configurable: it supports different LLM models (Gemini API or OpenAI-compatible APIs), custom grading prompts, HTML templates with multi-language support, and an optional URL for legal terms. It can function as a standalone AI grader or integrated with platforms that support LTI 1.1 (tested with Open edX and Moodle). Every stage includes a debug mode to assist with setup.

---

## 1. Directory Structure and Permission Schema

The security of this application relies on a **"Private/Public" split**. All Python logic resides in `/usr/lib/cgi-bin/` and sensitive data remains in `/var/secure/`, both of which are inaccessible to the web server’s direct file requests.

| Path | File / Purpose | Recommended Permissions |
| :--- | :--- | :--- |
| `/usr/lib/cgi-bin/` | lti-receiver.py (Handshake) | 755 (Owner: root, Group: www-data) |
| `/usr/lib/cgi-bin/` | evaluate-certacles-writing-c1-LTI-conf.py and aigrader.py | 755 (Owner: root, Group: www-data) |
| `/var/www/html/` | B2-writing-correction-LTI.html and aigrader.js | 644 (Owner: www-data) |
| `/var/secure/lti_sessions/` | Temporary session tokens (JSON) | 770 (Owner: www-data) |
| `/var/secure/aigrader.env` | API Keys and LTI Secrets | 640 (Owner: root, Group: www-data) |

To install the system, any missing folders must be created with sudo permissions and the correct ownership assigned. A bash script is provided in the repository to automate this.

### Critical Permission Commands
```bash
# Secure the environment file (Only root edits, Nginx reads)
sudo chown root:www-data /var/secure/aigrader.env
sudo chmod 640 /var/secure/aigrader.env

# Allow scripts to manage session tokens in the secure folder
sudo chown www-data:www-data /var/secure/lti_sessions/
sudo chmod 770 /var/secure/lti_sessions/

# Set execution rights for the CGI scripts
sudo chmod +x /usr/lib/cgi-bin/lti-receiver.py
sudo chmod +x /usr/lib/cgi-bin/evaluate-certacles-writing-c1-LTI-conf.py
sudo chmod +x /usr/lib/cgi-bin/aigrader.py
```
---

## 2. Server Configuration (Nginx)

When using Nginx, you must configure the cgi-bin section within a configuration file (.conf). 
1. Files should be created in `/etc/nginx/sites-available/`.
2. A symlink must then be created in `/etc/nginx/sites-enabled/` to activate the site.

Add the following block to your configuration file:

```nginx
location /cgi-bin/ {
    gzip off;
    fastcgi_buffering off; # Required for real-time AI feedback

    alias /usr/lib/cgi-bin/;
    fastcgi_pass unix:/var/run/fcgiwrap.socket;
    include fastcgi_params;

    # Ensures 'alias' resolves the script path correctly
    fastcgi_param SCRIPT_FILENAME $request_filename;

    # Timeouts adjusted for LLM inference latency
    fastcgi_read_timeout 180s;
    fastcgi_send_timeout 180s;
}
```
Aquí tienes el resto del documento desde ese punto exacto, manteniendo el formato de bloque de código para que puedas copiar el Markdown íntegro:

Markdown

* Validate the config with `nginx -t`.
* Restart the service with `systemctl restart nginx`.

---

## 3. Launch Mechanism (The Entry Point)

The system uses a highly flexible entry point. Instead of hardcoding which exam a student takes, the `lti-receiver.py` script acts as a data collector and session initializer.

**Standard Launch URL Format:**
`https://yourserver.com/cgi-bin/lti-receiver.py?file=/B2-writing-correction-LTI.html`

**How it works:**
* **LTI Parameter Gathering:** The `get_all_params()` function extracts all GET and POST data sent by the LMS (user IDs, outcome URLs, OAuth parameters).
* **Session Initialization:** The script creates a secure JSON file in `/var/secure/lti_sessions/` containing these parameters.
* **Dynamic Redirect:** After creating the session, the script reads the `?file=` parameter and redirects the student's browser to the specific HTML interface.
* **CGI-bin Grading & LTI Return:** The HTML page contains a form that calls the grader configuration script (e.g., `evaluate-certacles-writing-c1-LTI-conf.py`). This script selects the model and prompt, executes the logic via `aigrader.py`, and finally **sends the AI-generated grades after checking the LTI shared secret**. The integrity of the LTI parameters is verified by the LMS at this final stage when the grade is submitted.

---

## 4. Security Audit and Best Practices

### Security Mechanisms included in Configuration:
* **Path Traversal Protection:** Scripts use `os.path.basename()` and strict validation on the `?file=` parameter to ensure only authorized files within the web root are loaded, preventing access to sensitive system files like `/etc/passwd`.
* **Session Integrity:** The evaluation script (`evaluate-certacles-writing-c1-LTI-conf.py`) will **refuse to use LMS parameters** unless it finds a valid token in `/var/secure/lti_sessions/`. This ensures the AI API can only be called after successful LMS connection.
* **CORS & Domain Whitelisting:** `CORS_ALLOWED_ORIGINS` (for the server hosting the html, usually the same) and `LTI_ALLOWED_DOMAINS` (for the lms) restrict communication to trusted servers and LMS platforms.
* **Environment Isolation:** Sensitive keys are loaded from `/var/secure/aigrader.env`, keeping them out of the web-accessible directory and the code.
* **Debug mode in each section** A debug mode can be activated both in the html and the python scripts to solve setup problems.
---

## 5. Configuration Options

### In the HTML file:
```javascript
title: "C1 Writing",
allowedOrigins: ['[https://youropenedx.es](https://youropenedx.es)', '[https://studio.youropenedx.es](https://studio.youropenedx.es)'],
lang: 'en',
taskHTML: `
    <h2>Instructions</h2>
    <p>Please enter the text of the task description and your solution following the template.</p>
`,
initialValue: "####TASK\n\nTask description text\n\n####ANSWER\n\nYour answer",
placeholder: "Type your text here...",
evaluatorUrl: '/cgi-bin/evaluate-certacles-writing-c1-LTI-conf.py',
privacyUrl: "/evaluator_privacy_policy_Certacles_C1.html",
debug: false
```
### In the Python (.py) file:
```python
# Load .env file before defining CONFIG
load_env_file("/var/secure/aigrader.env") 

CONFIG = {
    "DEBUG": False,
    "BASE_URL": "[https://mi-lms.com](https://mi-lms.com)", # Base URL for relative paths
    "CORS_ALLOWED_ORIGINS": "[https://yourserver.com](https://yourserver.com)", #"[https://mi-lms.com](https://mi-lms.com), [https://otro-dominio.es](https://otro-dominio.es)" or "*" . With the url of the server where the scripts are located is enough.
    "LTI_ALLOWED_DOMAINS": "yourlms.com, canvas.instructure.com",
    "api_key": os.getenv("AI_GRADER_API_KEY_GOOGLE",""),
    #"api_key": os.getenv("AI_GRADER_API_KEY_OPENAI",""),
    "provider": "google", # Options: "google" o "openai"
    "api_url": None,  # Optional for OpenAI compatible APIs (ej. Azure o Proxies). If None, uses the openai url.
    "model_name": "gemini-2.5-flash-lite",
    "grade_identifier": "FINAL_GRADE", # What parser is going to look for from the llm to get the grade (ej: FINAL_GRADE: 12/15), include its generation in prompt 
    # ✅ LTI secrets (to be included in Moodle or Open EdX configuration)  
    "lti_consumer_secrets": {
        'openedx_key': os.getenv("LTI_OPENEDX_SECRET",""),
        'moodle_key': os.getenv("LTI_MOODLE_SECRET",""),
    },
    "session_dir": '/var/secure/lti_sessions',
    "send_grade_to_lms": True,
    "system_instructions": """
       PROMPT for the LLM
    """
}
```

## 6. Open edX Integration

1.  In the course, go to **Settings > Advanced Settings**.
2.  In **Advanced modules lists**, add `lti_consumer`.
3.  Look for **LTI passports** and add `LTI_KEY_NAME:LTI_SECRET`.
4.  In a unit, select **Advanced** in **Add a new component** and select **LTI Consumer**.
5.  Edit the component:
    * **LTI ID:** Enter the `LTI_KEY_NAME` used in the passport.
    * **LTI URL:** Enter the full URL pointing to `lti-receiver.py?file=...`.
    * **LTI version:** 1.1/1.2.
    * **Scored:** Set to `True` and define the points possible.

---

## 7. Deployment Checklist
* [ ] Scripts placed in `/usr/lib/cgi-bin/` and made executable.
* [ ] `.html` and `.js` files placed in `/var/www/html/`.
* [ ] `/var/secure/aigrader.env` created with valid API keys and LTI secrets.
* [ ] Nginx configured with the `cgi-bin` block and services restarted.
* [ ] LTI component configured in the LMS with matching URL, Key, and Secret.

---

## 8. Dynamic Task Definition (Advanced Use)

It is possible to dynamically override the task instructions (`taskHTML`) and the `initialValue` template without modifying the shared HTML file. This allows you to **reuse the same LTI tool and exam interface** across different Open edX units while grading entirely different prompts.

To achieve this:
1.  In Open edX, place a **Text component** in the unit immediately **before** the LTI component.
2.  In the HTML editor of that text component, include a JavaScript function that overrides the global configuration variables of the grader.
3.  The repository includes a specific HTML file example demonstrating how to implement this script.

This method enables high scalability, as a single deployment of the evaluator can handle a diverse range of specific writing tasks across an entire course.
