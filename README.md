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

Aquí tienes la segunda parte del documento, comenzando desde la configuración de Nginx, manteniendo el formato Markdown estrictamente dentro del bloque de código para evitar que el navegador lo interprete.

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
