/**
 * 🛠️ AIGRADER ENGINE v2.6
 */

const EvaluatorEngine = {
    // 🌎 LANGUAGE DICTIONARY
    i18n: {
        en: {
            ltiConnected: "🔗 <strong>LTI Mode:</strong> Your grade will be sent to the platform.",
            standalone: "ℹ️ <strong>Practice Mode:</strong> Results are not saved.",
            loading: "⏳ Analyzing your writing... please wait.",
            evaluateBtn: "Evaluate",
            evaluatingBtn: "Evaluating...",
            newBtn: "New Evaluation",
            emptyError: "Please write something before evaluating.",
            labelInput: "Your Response:",
            privacyLabel: "Data Protection & Privacy",
            connError: "Connection Error: ",
            serverError: "Server Error: ",
			emptySubmissionError: "ERROR: No response provided. Please write your task before submitting.\n\nGrade: 0 / 10"
        },
        es: {
            ltiConnected: "🔗 <strong>Modo LTI:</strong> Tu nota se enviará a la plataforma.",
            standalone: "ℹ️ <strong>Modo Práctica:</strong> Los resultados no se guardan.",
            loading: "⏳ Analizando tu texto... por favor espera.",
            evaluateBtn: "Evaluar",
            evaluatingBtn: "Evaluando...",
            newBtn: "Nueva Evaluación",
            emptyError: "Por favor, escribe algo antes de evaluar.",
            labelInput: "Tu Respuesta:",
            privacyLabel: "Información de Protección de Datos",
            connError: "Error de conexión: ",
            serverError: "Error del servidor: ",
			emptySubmissionError: "ERROR: No has escrito ninguna respuesta. Por favor, realiza la tarea antes de enviar.\n\nNota: 0 / 10"
        },
        va: {
            ltiConnected: "🔗 <strong>Mode LTI:</strong> La teua nota s'enviarà a la plataforma.",
            standalone: "ℹ️ <strong>Mode Pràctica:</strong> Els resultats no es guarden.",
            loading: "⏳ Analitzant el teu text... per favor espera.",
            evaluateBtn: "Avaluar",
            evaluatingBtn: "Avaluant...",
            newBtn: "Nova Avaluació",
            emptyError: "Per favor, escriu alguna cosa abans d'avaluar.",
            labelInput: "La teua Resposta:",
            privacyLabel: "Informació de Protecció de Dades",
            connError: "Error de connexió: ",
            serverError: "Error del servidor: ",
			emptySubmissionError: "ERROR: No has escrit cap resposta. Per favor, realitza la tasca abans d'enviar.\n\nNota: 0 / 10"
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
        document.getElementById('loading').innerText = this.txt.loading;
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

    bindEvents() {
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

                const rawText = await resp.text();
                const start = rawText.indexOf('{');
                const end = rawText.lastIndexOf('}') + 1;

                if (start === -1) throw new Error("Invalid response format");

                const res = JSON.parse(rawText.substring(start, end));
                this.showFeedback(res.success ? res.feedback : this.txt.serverError + res.error, res.success);
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
    },

    showFeedback(content, isSuccess) {
        const fb = document.getElementById('feedback');
        document.getElementById('feedback-content').innerHTML = content;
        fb.className = `feedback ${isSuccess ? 'success' : 'error'}`;
        fb.style.display = 'block';
        document.getElementById('new-eval-section').style.display = 'block';
        fb.scrollIntoView({ behavior: 'smooth' });
    },

	setupPostMessage() {
        // 1. Get allowed domains from CONFIG (with safe fallback)
        const allowed = CONFIG.allowedOrigins || ['https://youropenedx.es', 'https://studio.youropenedx.es'];
        
        // 2. Notify to parent page (LMS)
        window.parent.postMessage({ accion: 'hijo_listo' }, '*');

        // 3. Listen messages with dynamic validation
        window.addEventListener("message", (event) => {
            // ✅ Check if message origin is in our whitelist
            const isAuthorized = allowed.some(origin => event.origin.startsWith(origin));
            
            if (!isAuthorized) {
                if (CONFIG.debug) console.warn("Blocked message from unauthorized origin:", event.origin);
                return;
            }

            if (event.data.accion === 'rellenar_estudiante') {
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

