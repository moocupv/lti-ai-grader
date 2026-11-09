#!/usr/bin/env python3
"""Tests for deploy/monitoring/lti-health-watchdog.sh: real certificates served by `openssl s_server`,
synthetic metrics, a fake systemctl and a fake mailer. Nothing is sent and nothing outside a temporary
directory is touched.

Run from the repository root:   python3 tests/test_watchdog.py
Needs: bash, openssl, python3 and `pip install cryptography`. `ss` (iproute2) is used when present.
Another script can be tested with:   python3 tests/test_watchdog.py /path/to/lti-health-watchdog.sh
"""
import datetime as dt
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

if __name__ != "__main__":      # imported by `python3 -m unittest discover`: this file is a script
    import unittest
    raise unittest.SkipTest("run it directly: python3 tests/test_watchdog.py")

try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
except ImportError:
    print("SKIPPED: the python package 'cryptography' is not installed (pip install cryptography)")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HERE, "..", "deploy", "monitoring", "lti-health-watchdog.sh")
W = tempfile.mkdtemp(prefix="wdtest_")
BIN, LOG, STATE, CERTS = (os.path.join(W, d) for d in ("bin", "log", "state", "certs"))
for d in (BIN, LOG, STATE, CERTS):
    os.makedirs(d)
PORT = 18443
HOST = "test.local"
MAILS = os.path.join(W, "mails.txt")
fails = 0


def ok(cond, msg):
    global fails
    print(("  OK     " if cond else "  FALLA  ") + msg)
    if not cond:
        fails += 1


# ---------------------------------------------------------------- fakes
open(os.path.join(BIN, "systemctl"), "w").write('#!/bin/sh\n[ "${3:-}" = "${FAKE_INACTIVE:-}" ] && exit 3\nexit 0\n')
open(os.path.join(BIN, "sendmail.sh"), "w").write(
    '#!/bin/sh\nn=$(cat "%s.n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "%s.n"\n'
    'printf "=== MAIL %%s\\nSUBJECT: %%s\\n" "$n" "$1" >> "%s"; cat "$2" >> "%s"\n' % (MAILS, MAILS, MAILS, MAILS))
for f in ("systemctl", "sendmail.sh"):
    os.chmod(os.path.join(BIN, f), 0o755)


def mail_count():
    try:
        return int(open(MAILS + ".n").read())
    except FileNotFoundError:
        return 0


def last_mail():
    txt = open(MAILS).read() if os.path.exists(MAILS) else ""
    return txt.split("=== MAIL ")[-1] if txt else ""


# ---------------------------------------------------------------- certificates
def key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def name(cn):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def make_ca(tag):
    k = key()
    now = dt.datetime.now(dt.timezone.utc)
    c = (x509.CertificateBuilder().subject_name(name("Test CA " + tag)).issuer_name(name("Test CA " + tag))
         .public_key(k.public_key()).serial_number(x509.random_serial_number())
         .not_valid_before(now - dt.timedelta(days=3650)).not_valid_after(now + dt.timedelta(days=3650))
         .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
         .sign(k, hashes.SHA256()))
    return k, c


CA_KEY, CA_CERT = make_ca("A")
OTHER_KEY, OTHER_CERT = make_ca("B")
CA_FILE = os.path.join(CERTS, "ca.pem")
OTHER_CA_FILE = os.path.join(CERTS, "other_ca.pem")
open(CA_FILE, "wb").write(CA_CERT.public_bytes(serialization.Encoding.PEM))
open(OTHER_CA_FILE, "wb").write(OTHER_CERT.public_bytes(serialization.Encoding.PEM))


def make_leaf(tag, days_left, san=HOST):
    k = key()
    now = dt.datetime.now(dt.timezone.utc)
    c = (x509.CertificateBuilder().subject_name(name(san)).issuer_name(CA_CERT.subject).public_key(k.public_key())
         .serial_number(x509.random_serial_number())
         .not_valid_before(now - dt.timedelta(days=90)).not_valid_after(now + dt.timedelta(days=days_left))
         .add_extension(x509.SubjectAlternativeName([x509.DNSName(san)]), critical=False)
         .sign(CA_KEY, hashes.SHA256()))
    cp, kp = os.path.join(CERTS, tag + ".pem"), os.path.join(CERTS, tag + ".key")
    open(cp, "wb").write(c.public_bytes(serialization.Encoding.PEM))
    open(kp, "wb").write(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
                                         serialization.NoEncryption()))
    return cp, kp


# ---------------------------------------------------------------- servers
server = None


def stop_server():
    global server
    if server:
        server.kill()
        server.wait()
        server = None
        time.sleep(0.3)


def wait_port(up=True):
    for _ in range(60):
        s = socket.socket()
        s.settimeout(0.2)
        r = s.connect_ex(("127.0.0.1", PORT))
        s.close()
        if (r == 0) == up:
            return True
        time.sleep(0.1)
    return False


def serve_tls(cert, keyfile):
    global server
    stop_server()
    server = subprocess.Popen(["openssl", "s_server", "-accept", str(PORT), "-cert", cert, "-key", keyfile, "-www", "-quiet"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert wait_port(True), "s_server did not start"


def serve_plain_http():
    global server
    stop_server()
    server = subprocess.Popen(["python3", "-m", "http.server", str(PORT), "--bind", "127.0.0.1"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert wait_port(True)


# ---------------------------------------------------------------- metrics
def write_metrics(low_mem_minutes=(), high_load_minutes=(), last_age_s=10, mem=2000, load=1.0):
    """One sample every 30 s for the last 60 minutes. *_minutes: minutes-ago of samples to degrade."""
    now = dt.datetime.now()
    path = os.path.join(LOG, "metrics-%s.csv" % now.strftime("%Y-%m"))
    rows = ["timestamp,load1,mem_available_mb,disk_used_pct,evaluators,oldest_evaluator_sec,lti_receivers,fcgi_general,fcgi_receiver,queue_general,queue_receiver"]
    low = {round(m, 1) for m in low_mem_minutes}
    high = {round(m, 1) for m in high_load_minutes}
    t = 60.0
    while t >= 0:
        age = round(t, 1)
        ts = now - dt.timedelta(minutes=t) - dt.timedelta(seconds=last_age_s)
        m = 100 if age in low else mem
        ld = 55.0 if age in high else load
        rows.append("%s,%s,%d,50,0,0,0,17,6,0,0" % (ts.strftime("%Y-%m-%d %H:%M:%S"), ld, m))
        t -= 0.5
    open(path, "w").write("\n".join(rows) + "\n")
    y = (now - dt.timedelta(days=1)).strftime("%Y-%m-%d")
    open(os.path.join(LOG, "report-%s.txt" % y), "w").write("daily report\n")


def reset_state():
    for f in ("watchdog.state", "watchdog-tls-fails"):
        p = os.path.join(STATE, f)
        if os.path.exists(p):
            os.remove(p)
    for p in (MAILS, MAILS + ".n"):
        if os.path.exists(p):
            os.remove(p)


def run(extra=None, args=(), tls=True):
    env = dict(os.environ, PATH=BIN + ":" + os.environ["PATH"], LOG_DIR=LOG, STATE_DIR=STATE,
               LTI_HEALTH_SEND_MAIL=os.path.join(BIN, "sendmail.sh"), MAIL_TO="a@b.c", MAIL_FROM="x@y.z", SMTP_HOST="smtp.test",
               MAX_DISK_USED="100")
    if tls:
        env.update(TLS_HOST=HOST, TLS_CONNECT="127.0.0.1", TLS_PORT=str(PORT), TLS_CAFILE=CA_FILE)
    if extra:
        env.update(extra)
    return subprocess.run(["bash", SCRIPT, *args], env=env, capture_output=True, text=True, timeout=60)


def state():
    p = os.path.join(STATE, "watchdog.state")
    return open(p).read().strip() if os.path.exists(p) else None


# ================================================================= scenarios
print("== 1. Todo sano: certificado a 300 días, fichero igual, memoria y carga normales")
reset_state(); write_metrics()
good, good_key = make_leaf("good", 300)
serve_tls(good, good_key)
old = time.time() - 7200
os.utime(good, (old, old))
r = run({"CERT_FILE": good}); r = run({"CERT_FILE": good})
ok(mail_count() == 0 and state() == "OK", "dos pasadas sin ningún correo y estado OK (%s)" % (r.stderr.strip()[:80] or "sin errores"))

print("\n== 2. Certificado a 15 días: UN aviso y no se repite")
reset_state(); write_metrics()
c15, k15 = make_leaf("c15", 15); serve_tls(c15, k15)
run(); ok(mail_count() == 1 and "expires in less than 21 days" in last_mail(), "primer aviso: «expires in less than 21 days»")
run(); ok(mail_count() == 1, "segunda pasada: sin correo nuevo")
c14, k14 = make_leaf("c14", 14); serve_tls(c14, k14)
run(); ok(mail_count() == 1, "un día después (14 días): sigue sin repetirse dentro de la ventana de 21 días")
ok("Expires" in last_mail() and "days left" in last_mail(), "las cifras exactas van en el apartado de detalles")

print("\n== 3. Certificado a menos de 7 días: aviso diario con la cifra")
c5, k5 = make_leaf("c5", 4.5); serve_tls(c5, k5)
run(); ok(mail_count() == 2 and "expires in 4 day(s)" in last_mail(), "entra en la última semana: «expires in 4 day(s)»")
run(); ok(mail_count() == 2, "misma pasada del mismo día: sin duplicado")
c4, k4 = make_leaf("c4", 3.5); serve_tls(c4, k4)
run(); ok(mail_count() == 3 and "expires in 3 day(s)" in last_mail(), "al día siguiente: nuevo recordatorio «expires in 3 day(s)»")

print("\n== 4. Certificado caducado y recuperación")
cx, kx = make_leaf("cx", -1); serve_tls(cx, kx)
run(); ok(mail_count() == 4 and "has EXPIRED" in last_mail(), "aviso «has EXPIRED»")
serve_tls(good, good_key)
run(); ok(mail_count() == 5 and "recovered" in last_mail().lower() and state() == "OK", "certificado renovado: correo de «recovered»")

print("\n== 5. Fichero renovado en disco pero Nginx sigue sirviendo el viejo")
reset_state(); write_metrics()
new_file, _ = make_leaf("renewed", 300)
os.utime(new_file, (old, old))
serve_tls(good, good_key)
run({"CERT_FILE": new_file}); ok(mail_count() == 1 and "not the one nginx is serving" in last_mail(), "fichero distinto y antiguo: aviso «reload nginx?»")
ok("Served:" in last_mail() and "On disk" in last_mail(), "el correo da las dos huellas")
reset_state(); os.utime(new_file, None)
run({"CERT_FILE": new_file}); ok(mail_count() == 0, "fichero escrito hace menos de 10 min: no avisa (margen para recargar)")
run({"CERT_FILE": "/nonexistent/cert.pem"}); ok("missing or unreadable" in last_mail(), "fichero inexistente: «missing or unreadable»")
reset_state(); garbage = os.path.join(CERTS, "garbage.pem"); open(garbage, "w").write("not a certificate\n")
run({"CERT_FILE": garbage}); ok("No certificate could be read" in last_mail(), "fichero que no es un certificado: aviso")

print("\n== 6. Nginx caído: se exige más de una comprobación fallida")
reset_state(); write_metrics(); stop_server(); wait_port(False)
run(); ok(mail_count() == 0, "primera comprobación fallida: todavía no avisa (podría ser una recarga)")
run(); ok(mail_count() == 1 and "Nothing is listening" in last_mail(), "segunda seguida: aviso «Nothing is listening»")
run(); ok(mail_count() == 1, "tercera: sin repetir")
serve_tls(good, good_key); run()
ok(mail_count() == 2 and "recovered" in last_mail().lower(), "Nginx vuelve: «recovered»")
ok(open(os.path.join(STATE, "watchdog-tls-fails")).read().strip() == "0", "el contador de fallos se pone a 0")
reset_state(); serve_plain_http()
run(); run(); ok(mail_count() == 1 and "No TLS certificate received" in last_mail(), "algo escucha pero no habla TLS: «No TLS certificate received»")
stop_server()

print("\n== 7. Cadena y nombre del sitio")
serve_tls(good, good_key)
reset_state(); write_metrics()
run({"TLS_CAFILE": OTHER_CA_FILE}); ok("does not verify" in last_mail() and "Verify return code" in last_mail(), "cadena que no verifica: aviso con el código de OpenSSL")
reset_state(); run({"TLS_HOST": "wrong.example"}); ok("does not verify" in last_mail(), "nombre del sitio que no coincide con el certificado: aviso")
reset_state(); run({"TLS_CAFILE": OTHER_CA_FILE, "TLS_VERIFY": "0"}); ok(mail_count() == 0, "con TLS_VERIFY=0 no se comprueba la cadena")

print("\n== 8. Memoria baja (4 muestras de 300 MB o menos en 15 minutos)")
reset_state(); write_metrics(low_mem_minutes=(1, 2, 3))
run(tls=False); ok(mail_count() == 0, "3 muestras bajas: no avisa")
reset_state(); write_metrics(low_mem_minutes=(1, 2, 3, 4))
run(tls=False); ok(mail_count() == 1 and "Available memory is below 300 MB" in last_mail(), "4 muestras bajas: aviso")
ok("lowest 100 MB" in last_mail() and "4 of" in last_mail(), "el detalle da el mínimo y el recuento")
write_metrics(low_mem_minutes=(1, 2, 3, 4, 5, 6)); run(tls=False)
ok(mail_count() == 1, "el episodio empeora (6 muestras): NO se repite el correo (las cifras no cuentan para la clave)")
reset_state(); write_metrics(low_mem_minutes=(20, 21, 22, 23, 24))
run(tls=False); ok(mail_count() == 0, "muestras bajas de hace más de 15 min: no avisa")
reset_state(); write_metrics(low_mem_minutes=(1, 2, 3, 4)); run(tls=False)
write_metrics(); run(tls=False); ok(mail_count() == 2 and "recovered" in last_mail().lower(), "al normalizarse: «recovered»")

print("\n== 9. Carga alta")
reset_state(); write_metrics(high_load_minutes=(1, 2, 3, 4))
run(tls=False); ok("load average is above 20" in last_mail() and "highest 55" in last_mail(), "4 muestras con carga 55: aviso con el máximo")
reset_state(); run({"LOAD_ALERT": "0"}, tls=False); ok(mail_count() == 0, "LOAD_ALERT=0 desactiva la alarma de carga")

print("\n== 10. TLS_HOST sin definir: las comprobaciones TLS están apagadas")
stop_server(); reset_state(); write_metrics()
r = run({"TLS_HOST": ""}, tls=False); ok(mail_count() == 0 and state() == "OK", "sin servidor ni TLS_HOST: no hay avisos")
ok(not os.path.exists(os.path.join(STATE, "watchdog-tls-fails")), "y no se intenta ninguna conexión (no se crea el contador)")

print("\n== 11. Simulacro (LTI_HEALTH_DRYRUN=1): muestra y no cambia nada")
reset_state(); write_metrics(low_mem_minutes=(1, 2, 3, 4)); stop_server()
before_state = state()
r = run({"LTI_HEALTH_DRYRUN": "1"})
ok("Dry run: problems that would be reported" in r.stdout and "Available memory" in r.stdout and "Nothing is listening" in r.stdout,
   "lista los problemas, incluido Nginx caído, sin esperar a la segunda comprobación")
ok(mail_count() == 0 and state() == before_state and not os.path.exists(os.path.join(STATE, "watchdog-tls-fails")), "no envía correo, no guarda estado ni contador")
serve_tls(good, good_key); write_metrics()
r = run({"LTI_HEALTH_DRYRUN": "1"}); ok("no problems detected" in r.stdout, "sano: «Dry run: no problems detected.»")

print("\n== 12. --tls-summary (para el informe semanal)")
r = run(args=["--tls-summary"]); ok("expires" in r.stdout and "days left" in r.stdout and HOST in r.stdout, "una línea con caducidad y días: %r" % r.stdout.strip().splitlines()[0][:90])
ok("Issuer:" in r.stdout, "y el emisor")
r = run({"TLS_HOST": ""}, args=["--tls-summary"], tls=False); ok("not configured" in r.stdout, "sin TLS_HOST: «not configured»")
stop_server(); r = run(args=["--tls-summary"]); ok("Could not get a certificate" in r.stdout, "sin servidor: «Could not get a certificate»")

print("\n== 13. Las comprobaciones que ya existían siguen funcionando")
serve_tls(good, good_key)
reset_state(); write_metrics(last_age_s=600); run(); ok("Last health sample is" in last_mail(), "muestra antigua: aviso")
reset_state(); write_metrics(); run({"FAKE_INACTIVE": "lti-health-sample.timer"}); ok("lti-health-sample.timer is not active" in last_mail(), "unidad inactiva: aviso")
reset_state(); write_metrics(); run({"MAX_DISK_USED": "1"}); ok("Root filesystem usage" in last_mail(), "disco por encima del umbral: aviso")
if dt.datetime.now().hour >= 2:
    reset_state(); write_metrics()
    y = (dt.datetime.now() - dt.timedelta(days=1)).strftime("%Y-%m-%d"); os.remove(os.path.join(LOG, "report-%s.txt" % y))
    run(); ok("Daily report for" in last_mail(), "informe diario ausente: aviso")

print("\n== 14. Varios problemas a la vez en un solo correo")
reset_state(); write_metrics(low_mem_minutes=(1, 2, 3, 4)); c5b, k5b = make_leaf("c5b", 4.5); serve_tls(c5b, k5b)
run(); body = last_mail(); ok(mail_count() == 1 and "expires in 4 day(s)" in body and "Available memory" in body, "memoria baja y certificado a punto de caducar: un único correo con los dos")

stop_server()
shutil.rmtree(W, ignore_errors=True)
print("\nRESULTADO:", "TODO CORRECTO" if fails == 0 else "%d FALLO(S)" % fails)
sys.exit(1 if fails else 0)
