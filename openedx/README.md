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
| `openedx/excel/ResumenOpenEdX.bas` | instructor's computer (Excel for Windows) | VBA macro: one row per correction (student and problem) from the downloaded report, see "Excel summary" |
| `Resumen_informe_OpenEdX.xlsm` | **Releases** page (not in the tree) | Ready-made workbook with the macro and a button; same code as the `.bas` |
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

The script also reads the *student state* report (`student_state_from_block-….csv`); on a real report
it returned one row per correction. That report carries a huge `state` column (hundreds of KB per
student) that is copied as is, so the output can be very large: delete that column if you do not need it.

Open edX also keeps a snapshot of every submission in the student's state history.

### Excel summary: one row per correction (Windows)

`openedx/excel/ResumenOpenEdX.bas` is a VBA module that reads the *student state* CSV
(`student_state_from_block-….csv`) of **one problem or of a whole section** and builds a sheet
**"Resumen por alumno"** with one row per *corrections line*, that is, per student and per problem:

| Column | Content |
| :--- | :--- |
| Problema | Name of the exercise: the path in `location` without the course name (first part) and without the component (last part), e.g. `Course unit 1 > Paper 2 - WRITING > Exercise 1.1` |
| Identificación | Open edX username |
| Enunciado | Task statement of the last submission |
| Nº de envíos | Number of corrections stored (it can be 1 less than Open edX's `attempts`, which also counts clicks on Submit without a correction) |
| Última nota | Grade of the last correction as the AI returned it (e.g. `12/15`), stored as text so Excel does not turn it into a date |
| Última respuesta | The student's text in the last submission |
| Última corrección de la IA | The AI feedback for that submission |
| Puntuación LTI | `module_score` of the LTI component line of the **same student and the same exercise** (the points the LMS holds). Empty if the report has no such line or no score |

**Which lines are used.** A section report mixes block types. Only two kinds of line are used:

* **Corrections lines**: the `Respuesta` cell holds the stored history (it contains `intentos`) with at
  least one submission. Every one of them becomes a row; students are *not* grouped, so a student with
  three exercises gets three rows.
* **LTI lines**: `block_key` of type `lti_consumer` (or `lti`). Its score is attached to the corrections
  line with the same student and the same exercise path. If an exercise has two LTI components, the last one is used.

Everything else is ignored without an incident: other kinds of problem, a store the student opened but
never used, a store with an empty list. The **"Incidencias"** sheet only lists a line that looks like a
corrections line but cannot be read, with the reason and the failing step and position. Both sheets are
replaced on every run. "Last" is the submission with the most recent `fecha`, not the one listed last.
Comparing *Última nota* with *Puntuación LTI* shows grades that never reached the LMS (a grade of 2/5 on an
LTI component of weight 10 is shown as 4.0).

**Why a macro and not just opening the CSV in Excel:** the `Respuesta` cell holds the student's whole
history as JSON and can exceed 32,767 characters, the limit of an Excel cell, so Excel would silently
truncate it. The macro reads the file itself (UTF-8, quoted fields with embedded line breaks) and never
builds the huge `state` column.

**Option A: ready-made workbook (easiest).** Download `Resumen_informe_OpenEdX.xlsm` from the
[Excel summary release](https://github.com/moocupv/lti-ai-grader/releases/tag/excel-v1.0). It contains the
same macro as `ResumenOpenEdX.bas` and a button on the *Inicio* sheet. Windows blocks the macros of files
downloaded from the internet, so **before opening it**: right-click the file → *Properties* → tick
**Unblock** → *OK* (or run `Unblock-File .\Resumen_informe_OpenEdX.xlsm` in PowerShell). Then open it, click
*Enable Content* and press **Importar informe de Open edX…**. Each release lists the SHA-256 of the file;
compare it with `Get-FileHash .\Resumen_informe_OpenEdX.xlsm` (PowerShell) or
`certutil -hashfile Resumen_informe_OpenEdX.xlsm SHA256` (Command Prompt).

**Option B: import the source (you can read it first).** Create a new workbook, press `Alt+F11`,
*File → Import File…*, choose `ResumenOpenEdX.bas`, and save the workbook as
*Excel Macro-Enabled Workbook (.xlsm)*. This needs no unblocking, because the code is imported into a
workbook of your own. Run it with `Alt+F8` → `ImportarInformeOpenEdX` (or assign it to a button) → pick the CSV.

Notes:

* Requires **Excel for Windows** (it reads the file with `ADODB.Stream`). Everything runs locally.
* The `.xlsm` is intentionally not committed to the tree: a binary cannot be reviewed in a diff and every
  version would stay in the history for good. It is published as an asset of a GitHub Release instead.
  The `.bas` is the source. The VBA editor imports it as Windows-1252 text with **CRLF** line endings, so
  `.gitattributes` marks it `-text`: Git stores and serves the file byte for byte, with CRLF, however it is
  downloaded (clone, ZIP or the Raw button). Do not re-save it with an editor that converts line endings.
* A student text that starts with `=`, `+`, `-` or `@` is prefixed with a space so Excel never treats
  it as a formula. Texts longer than 32,000 characters are truncated with a visible note.
* **Speed** depends mostly on the size of the stored answers, not on the size of the CSV. In the
  LibreOffice Basic test environment, the huge `state` column is skipped at about 0.3 s per MB and the
  `Respuesta` text is analysed at about 8 s per MB. A section report with 100 students × 5 exercises
  (28 MB, 424 corrections lines, 7.7 MB of answers) took 66 s there. Excel's own speed has not been measured.
* **Testing.** The parsing core was run in an independent Basic interpreter (LibreOffice) and compared
  character by character with a separate Python implementation on twelve files: a real single-problem
  report, a real section report, and synthetic ones (emojis, odd JSON escapes, CR/LF/CRLF endings, BOM,
  40 columns, 150 students, 41 submissions in one student, LTI lines before and after their problem,
  duplicated LTI lines, LTI without a usable score, other kinds of problem, damaged JSON). The Excel layer
  (file dialog, sheets, formatting) has been run in Excel on a real section report with a single student
  (and, with the previous version of the macro, on a single-problem report). It has not been exercised
  with many students.

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
