/**
 * 🛠️ AIGRADER ENGINE v2.8 (waiting message with elapsed time and a tip; clear message on server timeout;
 *                         optional return of answer + AI correction to the LMS; feedback rendered as plain text)
 */

const EvaluatorEngine = {
    // 🌎 LANGUAGE DICTIONARY
    i18n: {
        en: {
            ltiConnected: "🔗 <strong>LTI Mode:</strong> Your grade will be sent to the platform.",
            standalone: "ℹ️ <strong>Practice Mode:</strong> Results are not saved.",
            loading: "⏳ Analyzing your writing... please wait.",
            elapsed: "Time elapsed:",
            waitTip: "This usually takes one or two minutes, and sometimes longer (up to five). You can keep working in the meantime if you are in a computer: open the course in another browser tab, carry on with another activity and come back to this tab later to see the result. Please do not close or reload this tab, and do not leave this page in it. If you are using the evaluator from a mobile phone this may not work",
            timeoutError: "The correction took too long and was cancelled by the server. Please try again in a few minutes.",
            evaluateBtn: "Evaluate",
            evaluatingBtn: "Evaluating...",
            newBtn: "New Evaluation",
            emptyError: "Please write something before evaluating.",
            labelInput: "Your Response:",
            privacyLabel: "Data Protection & Privacy",
            connError: "Connection Error: ",
            serverError: "Server Error: ",
			emptySubmissionError: "ERROR: No response provided. Please write your task before submitting.\n\nGrade: 0 / 10",
			invalidResponseError: "The AI model did not return a valid response. Please resubmit your answer as it may be a one-off error."
        },
        es: {
            ltiConnected: "🔗 <strong>Modo LTI:</strong> Tu nota se enviará a la plataforma.",
            standalone: "ℹ️ <strong>Modo Práctica:</strong> Los resultados no se guardan.",
            loading: "⏳ Analizando tu texto... por favor espera.",
            elapsed: "Tiempo transcurrido:",
            waitTip: "Suele tardar uno o dos minutos y a veces más (hasta cinco en algunos casos). Mientras tanto puedes seguir con el curso si estás trabajando en un ordenador: abre el curso en otra pestaña del navegador, continúa con otra actividad y vuelve a esta pestaña pasado un rato para ver el resultado. No cierres ni recargues esta pestaña, ni cambies de página en ella. Esto puede no funcionar desde un móvil.",
            timeoutError: "La corrección ha tardado demasiado y el servidor la ha cancelado. Inténtalo de nuevo dentro de unos minutos.",
            evaluateBtn: "Evaluar",
            evaluatingBtn: "Evaluando...",
            newBtn: "Nueva Evaluación",
            emptyError: "Por favor, escribe algo antes de evaluar.",
            labelInput: "Tu Respuesta:",
            privacyLabel: "Información de Protección de Datos",
            connError: "Error de conexión: ",
            serverError: "Error del servidor: ",
			emptySubmissionError: "ERROR: No has escrito ninguna respuesta. Por favor, realiza la tarea antes de enviar.\n\nNota: 0 / 10",
		    invalidResponseError: "El modelo de inteligencia artificial no ha devuelto una respuesta válida. Vuelve a enviar tu respuesta, puede ser un fallo puntual."
	    },
        va: {
            ltiConnected: "🔗 <strong>Mode LTI:</strong> La teua nota s'enviarà a la plataforma.",
            standalone: "ℹ️ <strong>Mode Pràctica:</strong> Els resultats no es guarden.",
            loading: "⏳ Analitzant el teu text... per favor espera.",
            elapsed: "Temps transcorregut:",
            waitTip: "Sol tardar un o dos minuts i, de vegades, més (fins a cinc). Mentrestant pots continuar amb el curs si estàs treballant en un ordinador: obri el curs en una altra pestanya del navegador, continua amb una altra activitat i torna a esta pestanya passat un temps per a vore el resultat. No tanques ni recarregues esta pestanya, ni canvies de pàgina en ella. En un telèfon mòbil pot no funcionar.",
            timeoutError: "La correcció ha tardat massa i el servidor l'ha cancel·lada. Torna-ho a provar d'ací a uns minuts.",
            evaluateBtn: "Avaluar",
            evaluatingBtn: "Avaluant...",
            newBtn: "Nova Avaluació",
            emptyError: "Per favor, escriu alguna cosa abans d'avaluar.",
            labelInput: "La teua Resposta:",
            privacyLabel: "Informació de Protecció de Dades",
            connError: "Error de connexió: ",
            serverError: "Error del servidor: ",
			emptySubmissionError: "ERROR: No has escrit cap resposta. Per favor, realitza la tasca abans d'enviar.\n\nNota: 0 / 10",
			invalidResponseError: "El model d'intel·ligència artificial no ha retornat una resposta vàlida. Torna a enviar la teua resposta, pot ser una fallada puntual."
        }
    },

    // 🎨 TEMPLATE
    getTemplate() {
        return `
        <style>
            body { font-family: 'Segoe UI', Arial, sans-serif; max-width: 850px; margin: 0 auto; padding: 20px; line-height: 1.6; background-color: #f0f2f5; color: #333; }
            .container { background: white; padding: 40px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.08); }
            h1 { color: #1a73e8; text-align: center; margin-top: 0; }
            .status-msg { padding: 15px; border-radius: 8px; margin-bottom: 20px; font-size: 14px; border: 1px solid transparent; }
            #lti-status { background: #e6f4ea; border-color: #34a853; color: #137333; }
            #standalone-mode { background: #fef7e0; border-color: #fbbc04; color: #b05a00; }
            .task-box { background: #f8f9fa; padding: 25px; border-radius: 8px; margin-bottom: 25px; border-left: 5px solid #1a73e8; }
            textarea { width: 100%; min-height: 380px; padding: 18px; border: 2px solid #dadce0; border-radius: 8px; font-size: 16px; box-sizing: border-box; font-family: inherit; transition: border-color 0.2s; }
            textarea:focus { border-color: #1a73e8; outline: none; }
            .btn-group { text-align: center; margin: 30px 0; }
            button { background: #1a73e8; color: white; padding: 14px 40px; border: none; border-radius: 30px; font-size: 16px; font-weight: bold; cursor: pointer; transition: transform 0.1s, background 0.2s; }
            button:hover { background: #1557b0; transform: translateY(-1px); }
            button:disabled { background: #bdc1c6; cursor: not-allowed; }
            .feedback { display: none; padding: 25px; border-radius: 8px; margin-top: 30px; white-space: pre-wrap; border: 1px solid #dadce0; background: #fff; line-height: 1.8; }
            .error { background: #fce8e6; color: #c5221f; border-color: #fad2cf; }
            .success { border-top: 5px solid #34a853;background-color: #e8f5e9;color: #1b5e20;border: 1px solid #c3e6cb; }
            .loading { display: none; color: #5f6368; font-weight: 500; margin-top: 15px; }
            .loading .loading-time { font-weight: 400; margin-top: 6px; font-variant-numeric: tabular-nums; }
            .loading .loading-tip { font-weight: 400; font-size: 0.92em; margin-top: 10px; padding: 8px 12px; background: #fff8e1; border-left: 4px solid #f9ab00; border-radius: 4px; color: #4a4a4a; }
            #privacy-footer { margin-top: 50px; padding-top: 20px; border-top: 1px solid #eee; text-align: center; font-size: 13px; }
            a { color: #1a73e8; text-decoration: none; } a:hover { text-decoration: underline; }
        </style>
        <div class="container">
            <h1 id="ui-title"></h1>
            <div id="lti-status" class="status-msg" style="display:none"></div>
            <div id="standalone-mode" class="status-msg" style="display:none"></div>
            <div id="task-html" class="task-box"></div>
            <form id="evaluation-form">
                <label for="student-input"><strong id="ui-label-input"></strong></label>
                <textarea id="student-input" required></textarea>
                <div class="btn-group">
                    <button type="submit" id="evaluate-btn"></button>
                    <div id="loading" class="loading"></div>
                </div>
            </form>
            <div id="feedback" class="feedback"><div id="feedback-content"></div></div>
            <div id="new-eval-section" style="display:none; text-align:center; margin-top:20px;">
                <button type="button" id="new-eval-btn" style="background:#34a853"></button>
            </div>
            <div id="privacy-footer"></div>
        </div>`;
    },

    init() {
        // 1. Inject HTML inmediately
        const root = document.getElementById('app-root');
        if (!root) return;
        root.innerHTML = this.getTemplate();

        // 2. Language detection
        const browserLang = navigator.language.split('-')[0];
        this.lang = CONFIG.lang || (this.i18n[browserLang] ? browserLang : 'en');
        this.txt = this.i18n[this.lang];

        // 3. Token capture (URL > SessionStorage > LocalStorage)
        const urlParams = new URLSearchParams(window.location.search);
        this.token = urlParams.get('token') || sessionStorage.getItem('lti_session_token') || localStorage.getItem('lti_session_token');

        const mode = urlParams.get('mode') || localStorage.getItem('lti_mode') || 'standalone';
        this.isLTI = (mode === 'lti' && !!this.token);

        // Persistence storing
        if (this.token) {
            sessionStorage.setItem('lti_session_token', this.token);
            localStorage.setItem('lti_session_token', this.token);
        }

        // LMS bridge (optional, see CONFIG.saveToLms): origin of the parent page, learned from its first message
        this.lmsOrigin = null;

        this.renderUI();
        this.bindEvents();
        this.setupPostMessage();
    },

    renderUI() {
        document.getElementById('ui-title').innerText = CONFIG.title;
        document.getElementById('task-html').innerHTML = CONFIG.taskHTML;
        document.getElementById('ui-label-input').innerText = this.txt.labelInput;
        document.getElementById('evaluate-btn').innerText = this.txt.evaluateBtn;
        document.getElementById('new-eval-btn').innerText = this.txt.newBtn;
        this.buildLoadingBox();
        document.getElementById('student-input').value = CONFIG.initialValue;

        if (CONFIG.privacyUrl) {
            const footer = document.getElementById('privacy-footer');
            footer.innerHTML = `<a href="${CONFIG.privacyUrl}" target="_blank">${this.txt.privacyLabel}</a>`;
        }
        if (CONFIG.debug) {
            if (this.isLTI) {
                const el = document.getElementById('lti-status');
                el.innerHTML = this.txt.ltiConnected;
                el.style.display = 'block';
            } else {
                const el = document.getElementById('standalone-mode');
                el.innerHTML = this.txt.standalone;
                el.style.display = 'block';
            }
            console.log("Debug Mode: ON", { isLTI: this.isLTI, token: !!this.token });
        }
    },

    // Waiting box: message, elapsed time and a tip. Built with textContent (no HTML from the dictionary).
    buildLoadingBox() {
        const box = document.getElementById('loading');
        box.textContent = '';
        const parts = [['loading-main', this.txt.loading], ['loading-time', ''], ['loading-tip', this.txt.waitTip]];
        parts.forEach(([cls, text]) => {
            const div = document.createElement('div');
            div.className = cls;
            div.textContent = text;
            box.appendChild(div);
        });
    },

    // The timer is computed from timestamps, so it stays right when the browser throttles a background tab.
    startWaitTimer() {
        this.stopWaitTimer();
        this.loadingSince = Date.now();
        this.updateWaitTimer();
        this.waitTimerId = setInterval(() => this.updateWaitTimer(), 1000);
    },

    stopWaitTimer() {
        if (this.waitTimerId) {
            clearInterval(this.waitTimerId);
            this.waitTimerId = null;
        }
    },

    updateWaitTimer() {
        const el = document.querySelector('#loading .loading-time');
        if (!el) return;
        const total = Math.max(0, Math.floor((Date.now() - this.loadingSince) / 1000));
        el.textContent = this.txt.elapsed + ' ' + Math.floor(total / 60) + ':' + String(total % 60).padStart(2, '0');
    },

    bindEvents() {
        // When the student comes back to this tab, refresh the elapsed time at once
        document.addEventListener('visibilitychange', () => {
            if (!document.hidden && this.waitTimerId) this.updateWaitTimer();
        });

        // Form handler
        document.getElementById('evaluation-form').addEventListener('submit', async (e) => {
            e.preventDefault();
            const text = document.getElementById('student-input').value.trim();
            if (!text) return alert(this.txt.emptyError);
            // We use the stored valuen or the initial CONFIG if no message from parent page
            const templateToCompare = this.currentValueFromLMS || CONFIG.initialValue;
            
			
			this.setLoading(true);
            try {
                const resp = await fetch(CONFIG.evaluatorUrl, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        studentInput: text,
                        session_token: this.token,
                        defaultValue: templateToCompare.replace(/\s+/g, ''),
                        emptyErrorMsg: this.txt.emptySubmissionError
                    })
                });

                if (resp.status === 504) {            // the server gave up waiting for the AI
                    this.showFeedback(this.txt.timeoutError, false);
                    return;                           // "finally" below still hides the waiting box
                }
                const rawText = await resp.text();
                const start = rawText.indexOf('{');
                const end = rawText.lastIndexOf('}') + 1;

                if (start === -1) throw new Error(this.txt.invalidResponseError);

                const res = JSON.parse(rawText.substring(start, end));
                this.showFeedback(res.success ? res.feedback : this.txt.serverError + res.error, res.success);
                if (res.success) {
                    this.sendCorrectionToLms({
                        fullText: text,
                        template: templateToCompare,
                        feedback: res.feedback,
                        scoreInfo: res.score_info
                    });
                }
            } catch (err) {
                this.showFeedback(this.txt.connError + err.message, false);
            } finally {
                this.setLoading(false);
            }
        });

        // ✅ New Evaluation button handler
        document.getElementById('new-eval-btn').addEventListener('click', () => {
            // 1. Hide feedback and reset button
            document.getElementById('feedback').style.display = 'none';
            document.getElementById('new-eval-section').style.display = 'none';
            
            // 2. Initial value reset
            document.getElementById('student-input').value = CONFIG.initialValue;
            
            // 3. Scroll to top
            window.scrollTo({ top: 0, behavior: 'smooth' });

            // 4. Ask for re-synchronization to parent page
            window.parent.postMessage({ accion: 'hijo_listo' }, '*');
            
            if (CONFIG.debug) console.log("New evaluation started: asking for parent re-synchronization.");
        });
    },

    setLoading(isLoading) {
        const btn = document.getElementById('evaluate-btn');
        btn.disabled = isLoading;
        btn.innerText = isLoading ? this.txt.evaluatingBtn : this.txt.evaluateBtn;
        document.getElementById('loading').style.display = isLoading ? 'block' : 'none';
        if (isLoading) this.startWaitTimer(); else this.stopWaitTimer();
    },

    showFeedback(content, isSuccess) {
        const fb = document.getElementById('feedback');
        // SECURITY: LLM output and server/connection errors are untrusted text. textContent never parses HTML,
        // so markup echoed by the model (or injected via the student's text) cannot run scripts.
        // Line breaks are preserved by the CSS rule `white-space: pre-wrap` on .feedback.
        document.getElementById('feedback-content').textContent = String(content);
        fb.className = `feedback ${isSuccess ? 'success' : 'error'}`;
        fb.style.display = 'block';
        document.getElementById('new-eval-section').style.display = 'block';
        fb.scrollIntoView({ behavior: 'smooth' });
    },

    // 📤 OPTIONAL: send student answer + AI correction back to the LMS page (postMessage).
    // The parent HTML component (javascript-for-openedx.html) stores it in a jsinput problem.
    sendCorrectionToLms({ fullText, template, feedback, scoreInfo }) {
        if (!CONFIG.saveToLms || !this.lmsOrigin || window.parent === window) return false;

        // Same check as the server: an untouched template is not a real submission, nothing to store
        const clean = (t) => String(t || '').replace(/\s+/g, '');
        if (clean(fullText) === clean(template)) return false;

        // Split "####TASK ... ####ANSWER ..." template
        const marker = '####ANSWER';
        const idx = fullText.indexOf(marker);
        const task = idx === -1 ? '' : fullText.slice(0, idx).replace('####TASK', '').trim();
        const answer = (idx === -1 ? fullText : fullText.slice(idx + marker.length)).trim();

        const hasScore = scoreInfo && scoreInfo.score !== null && scoreInfo.score !== undefined;
        const grade = hasScore ? `${scoreInfo.score}/${scoreInfo.max}` : '';

        window.parent.postMessage({
            accion: 'guardar_correccion',
            intento: {
                id: Date.now().toString(36) + Math.random().toString(36).slice(2, 8),
                fecha: new Date().toISOString(),
                enunciado: task,
                respuesta: answer,
                correccion: String(feedback || ''),
                nota: grade
            }
        }, this.lmsOrigin);

        if (CONFIG.debug) console.log("Correction sent to LMS bridge", grade);
        return true;
    },

	setupPostMessage() {
        // 1. Get allowed domains from CONFIG (with safe fallback)
        const allowed = CONFIG.allowedOrigins || ['https://youropenedx.es', 'https://studio.youropenedx.es'];
        
        // 2. Notify to parent page (LMS)
        window.parent.postMessage({ accion: 'hijo_listo' }, '*');

        // 3. Listen messages with dynamic validation
        window.addEventListener("message", (event) => {
            // ✅ Only the parent page, and only an origin in our whitelist (exact match, trailing slash tolerated)
            if (event.source !== window.parent) return;
            const normalize = (o) => String(o).replace(/\/+$/, '');
            const isAuthorized = allowed.some(origin => normalize(origin) === event.origin);
            
            if (!isAuthorized) {
                if (CONFIG.debug) console.warn("Blocked message from unauthorized origin:", event.origin);
                return;
            }

            if (!event.data || typeof event.data !== 'object') return;

            if (event.data.accion === 'rellenar_estudiante') {
                this.lmsOrigin = event.origin; // used to address the LMS bridge messages
                const campo = document.getElementById('student-input');
                if (campo) {
					this.currentValueFromLMS = event.data.texto;
                    campo.value = event.data.texto;
                    campo.focus();
                }
            }
        });
    }
};

// 🚀 SAFE LAUNCH
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => EvaluatorEngine.init());
} else {
    EvaluatorEngine.init();
}
