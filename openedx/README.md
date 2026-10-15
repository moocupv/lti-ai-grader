# Open edX: store the student's answer and the AI correction in the LMS (optional)

By default the grader only sends the numeric grade back to the LMS. With this option, every
correction (the student's answer, the AI feedback and the grade string) is also saved inside
Open edX, per student, so instructors can review and download it.

It is **opt-in** (`saveToLms: false` by default) and needs **no change on the Python side**.

## How it works

```
 Unit page in Open edX (all three components live in the same unit)
┌──────────────────────────────────────────────────────────────────────────────┐
│ 1. HTML component  = "bridge" (javascript-for-openedx.html)                  │
│ 2. LTI Consumer    = the grader (iframe, runs aigrader.js on YOUR server)    │
│ 3. Problem         = Custom JavaScript Display and Grading (jsinput)         │
│                      └─ iframe: jsinput_store.html (on YOUR server)          │
└──────────────────────────────────────────────────────────────────────────────┘

 grader iframe ──postMessage 'guardar_correccion'──▶ bridge ──'anadir_intento'──▶ store iframe
                                                       │                              │
                                                       └── clicks the problem's Submit ┘
                                                                    │
                                              Open edX calls getGrade()/getState() on the store
                                                                    ▼
                                         saved in the student's state (student_answers)
```

1. After a successful correction, `aigrader.js` posts the attempt to the parent page.
2. The bridge validates it and hands it to the store iframe.
3. The store keeps **all** attempts (restored with `setState` when the student comes back) and
   exposes them through `getGrade`/`getState` (jsinput, using `jschannel`).
4. The bridge presses the problem's **Submit** button for the student (optionally hidden) so
   that Open edX persists the state. Previous attempts are kept: each submission returns the
   full history plus the new attempt.

## Files

| File | Where it goes | Purpose |
| :--- | :--- | :--- |
| `aigrader.js` | web root (deployed by `deploy_to_server.sh`) | New `saveToLms` option; sends the attempt to the parent page |
| `javascript-for-openedx.html` | Studio, **HTML component** (raw HTML editor) | The bridge. Also sends the task statement to the grader |
| `jsinput_store.html` | web root of **your** server (deployed by `deploy_to_server.sh`) | Store iframe used by the jsinput problem |
| `jschannel.js` | web root, next to `jsinput_store.html` | Mozilla jschannel (**not included**, see below) |
| `openedx/problem-store-corrections.xml` | Studio, problem **advanced editor** | The jsinput problem |
| `openedx/expandir_respuestas.py` | instructor's computer | Expands the downloaded report into one row per attempt |
| `openedx/test-puente-lms.html` | web root, **temporarily** | Test page that simulates a correction (no LLM needed) |

> `openedx/` is deliberately not copied by `deploy_to_server.sh` (it only copies `*.html`,
> `*.js` and `*.css` from the repository root), so the test page is never published by accident.

## Requirements and caveats

* **Host the store on your own server, not in Studio's *Files & Uploads*.** Recent Open edX
  versions serve course assets with `Content-Security-Policy: sandbox`
  (openedx-platform commit `2efdce0`, "sandbox served course assets to prevent stored XSS"),
  which blocks JavaScript in HTML files uploaded as course assets. A jsinput `html_file`
  that points to your server (with `sop="false"`, as in the official Open edX example) is not
  affected.
* **CodeJail must work** in your Open edX. The jsinput problem is a `customresponse` and its
  Python check function runs in CodeJail when the problem is displayed.
* Test the unit in the **student view / Preview**. Studio editing views may render each component
  in its own iframe, in which case the bridge and the problem cannot talk to each other.
* Only **one grader per unit** is supported.

## Setup

### 1. Server

`jsinput_store.html` is deployed with the rest of the static files by
`deploy/deploy_to_server.sh`. Download `jschannel.js` (pinned to a commit and verified with a
checksum, because it is a third-party file under MPL 1.1/GPL 2.0/LGPL 2.1 and is not vendored here):

```bash
cd /usr/share/nginx/html
sudo curl -fsSL -o jschannel.js \
  https://raw.githubusercontent.com/mozilla/jschannel/65356baa89106e698fe14800de67557b2366470a/src/jschannel.js
echo "c67d3b79ee612baac27623847288eac957d6a22d0746d17b3adb9fbda0501531  jschannel.js" | sha256sum -c -
sudo chown root:www-data jschannel.js jsinput_store.html
sudo chmod 644 jschannel.js jsinput_store.html
```

Check that both are reachable and can be framed by the LMS (no `X-Frame-Options: DENY` and no
restrictive `frame-ancestors`):

```bash
curl -I https://yourserver.com/jsinput_store.html
curl -I https://yourserver.com/jschannel.js
```

### 2. The grader's HTML

In the `CONFIG` of each corrector where you want it:

```javascript
saveToLms: true,
allowedOrigins: ['https://youropenedx.es'],   // exact origin of the LMS (no trailing path)
```

### 3. Studio: one unit, three components, in this order

1. **HTML component** → use the *raw HTML editor* (the visual editor can break scripts) and paste
   `javascript-for-openedx.html`. Edit at least:
   * `toolOrigins`: origin of **your** server, e.g. `['https://yourserver.com']`.
   * `enunciadoTarea`: the task statement of this activity.
2. **LTI Consumer** (as already described in the main README).
3. **Problem** → *Advanced* → *Custom JavaScript Display and Grading* → advanced editor → paste
   `openedx/problem-store-corrections.xml` and replace `https://yourserver.com/jsinput_store.html`
   with your URL. In the problem **Settings**:
   * **Maximum Attempts:** empty (unlimited)
   * **Show Reset Button:** False (Reset deletes the student's state)
   * **Show Answer:** Never
   * **Problem Weight:** 0, or place it in an ungraded subsection. The check function returns
     "correct" as soon as one attempt is stored; the real grade is sent by the LTI.

### 4. Test it without the LLM

Copy `openedx/test-puente-lms.html` to the web root (edit `ALLOWED_ORIGINS` inside), and in a test
unit use an HTML component with
`<iframe src="https://yourserver.com/test-puente-lms.html" width="100%" height="320" title="Bridge test"></iframe>`
instead of the LTI component. Press the button; both steps should turn green and the problem should
show "Corrections recorded: 1". Remove the test page afterwards.

## Bridge options (`CONFIG` in `javascript-for-openedx.html`)

| Option | Default | Meaning |
| :--- | :--- | :--- |
| `toolOrigins` | `['https://yourserver.com']` | Exact origins allowed to send messages as the grader |
| `storeSrcMatch` | `'jsinput_store.html'` | Text that must appear in the `src` of the store iframe |
| `autoSubmitSelector` | `'.problems-wrapper button.submit'` | Button pressed to persist the state. `'button.save'` stores without running the check function. `''` disables auto-submit |
| `autoSubmitDelayMs` | `300` | Delay before pressing it after the store confirms |
| `autoSubmitFallbackMs` | `1800` | Press it anyway if the store's confirmation never arrives |
| `ocultarBotonEnviar` | `true` | Hide the Submit button (the bridge presses it) |
| `ocultarSelector` | `'button.submit'` | What is hidden inside the problem |
| `verificarGuardadoMs` | `10000` | If the problem is not re-rendered after pressing Submit within this time, the button is shown again (manual mode) so nothing is lost silently |
| `debug` | `false` | Logs prefixed `[lti-bridge]` in the browser console |

## Message protocol

| Direction | `accion` | Notes |
| :--- | :--- | :--- |
| grader → bridge | `hijo_listo` | Existing handshake; the bridge replies `rellenar_estudiante` with the template |
| grader → bridge | `guardar_correccion` | `{intento: {id, fecha, enunciado, respuesta, correccion, nota}}` |
| bridge → grader | `correccion_almacenada` | `{id, total}`, the store has the attempt (not yet in the LMS database) |
| store → bridge | `almacen_listo`, `intento_guardado` | Handshake and acknowledgement |
| bridge → store | `puente_activo`, `anadir_intento`, `modo_manual` | |

Messages are attributed by **iframe identity** (its `src`), not only by origin, because the grader
and the store are usually served from the same origin.

## What is stored

Each problem submission stores, in `student_answers`, a JSON string of the form
`{"answer": "<json>", "state": "<json>"}` (both hold the same history):

```json
{"v": 1, "intentos": [
  {"id": "…", "fecha": "2026-10-15T00:24:24.539Z", "enunciado": "…",
   "respuesta": "…", "correccion": "…", "nota": "12/15"}
]}
```

A literal `%` is written as `\u0025` (valid JSON): `jsinput.js` calls `decodeURI()` on the returned
string and a bare `%` made the submission fail with `URIError: URI malformed`.

## Instructors: view and download

1. **Instructor Dashboard → Data Download → Problem Responses Report**, select the problem's
   location and generate the CSV.
2. Expand it into one row per attempt:

   ```bash
   python3 openedx/expandir_respuestas.py report.csv -o corrections.csv
   ```

   The script detects the `Answer`/`Respuesta` column (if yours is named differently, pass
   `--columna "<name>"`) and keeps the other columns. It was tested with the `student_answers`
   format described above; check it against a real report from your instance.

Open edX also keeps a snapshot of every submission in the student's state history.

## Troubleshooting

Set `debug: true` in the bridge and look for `[lti-bridge]` lines in the console. Open the unit
in the student view or Preview and select the unit's iframe in the console context selector.

| Symptom | Likely cause |
| :--- | :--- |
| The store says "bridge component not detected" | The HTML component is missing, has an old version, is in another unit, or you are in a Studio editing view |
| `mensaje … DESCARTADO` with an `origin` | `toolOrigins` does not contain that exact origin |
| Corrections are queued but never confirmed | The store iframe is not in the page, or `storeSrcMatch` does not match its `src` |
| Submit button reappears after ~10 s ("manual mode") | The submission failed. Look for errors from `jsinput.js` in the console |
| `URIError: URI malformed` from `jsinput.js` | Fixed by escaping `%`; make sure `jsinput_store.html` is the current version (hard refresh) |
| Grader says "Server Error: HTTP Error 500" | Not related to this feature: the LLM provider returned a 500 |

## Security notes

* The data is produced in the student's browser: treat it as a **log, not proof**. If integrity
  matters, have the evaluator sign each attempt (e.g. HMAC) and verify it offline.
* Hiding the Submit button is cosmetic; the real grade still travels through the LTI.
* Incoming messages are accepted only from iframes of the page with the expected `src`, and
  `aigrader.js` compares origins exactly.
* The AI feedback is rendered as plain text (`textContent`), never as HTML.

## Known limitations

* One grader per unit.
* Each submission stores the whole history twice and Open edX keeps a copy of every submission, so
  data grows roughly quadratically with the number of attempts (the store caps it at 100 attempts).
* Verified on a single Open edX instance; behaviour of `jsinput` and of the problem's Submit button
  may differ between versions. The comments and log messages in the bridge/store are in Spanish.
