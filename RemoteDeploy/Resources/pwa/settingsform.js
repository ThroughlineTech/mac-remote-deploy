// Settings editor for the RemoteDeploy PWA, backed by GET/PUT /api/v1/settings.
// Loaded after app.js; shares its globals (state, api, esc, render, loadSettings,
// loadStatus) and registers ACTIONS. Embedded into the Settings tab by
// renderSettings() in app.js.
//
// GET redacts cert/key paths to "[configured]" and push secrets to "[redacted]".
// The server preserves any field left at its placeholder on PUT (TKT-059), so the
// editor can safely round-trip the whole SettingsData object.

function renderSettingsForm() {
  const s = state.settings;
  if (!s) return `<div class="card"><div class="spinner"></div></div>`;
  const push = s.pushNotificationConfig || {};
  const chk = (v) => v ? 'checked' : '';
  return `
    ${state.settingsMsg ? `<div class="form-ok">${esc(state.settingsMsg)}</div>` : ''}
    ${state.settingsError ? `<div class="form-error">${esc(state.settingsError)}</div>` : ''}

    <h2>Server</h2>
    <label class="field-label">Port</label>
    <input type="number" min="1024" max="65535" value="${esc(s.serverPort)}" data-input="sPort">
    <label class="field-label">Hostname</label>
    <input type="text" value="${esc(s.hostname)}" data-input="sHostname" autocapitalize="off" autocorrect="off" spellcheck="false">

    <h2>TLS</h2>
    <p class="muted-sm">Leave "[configured]" to keep the current file.</p>
    <label class="field-label">Certificate path</label>
    <input type="text" value="${esc(s.certPath)}" data-input="sCertPath" autocapitalize="off" autocorrect="off" spellcheck="false">
    <label class="field-label">Private key path</label>
    <input type="text" value="${esc(s.keyPath)}" data-input="sKeyPath" autocapitalize="off" autocorrect="off" spellcheck="false">

    <h2>Push Notifications</h2>
    <p class="muted-sm">Leave "[redacted]" to keep a stored secret.</p>
    <label class="field-toggle"><input type="checkbox" data-change="pProwlEnabled" ${chk(push.prowlEnabled)}> Prowl</label>
    <input type="text" placeholder="Prowl API key" value="${esc(push.prowlAPIKey)}" data-input="pProwlKey" autocapitalize="off" autocorrect="off" spellcheck="false">
    <label class="field-toggle"><input type="checkbox" data-change="pPushoverEnabled" ${chk(push.pushoverEnabled)}> Pushover</label>
    <input type="text" placeholder="Pushover app token" value="${esc(push.pushoverAppToken)}" data-input="pPushoverToken" autocapitalize="off" autocorrect="off" spellcheck="false">
    <input type="text" placeholder="Pushover user key" value="${esc(push.pushoverUserKey)}" data-input="pPushoverUser" autocapitalize="off" autocorrect="off" spellcheck="false">
    <label class="field-toggle"><input type="checkbox" data-change="pNtfyEnabled" ${chk(push.ntfyEnabled)}> ntfy</label>
    <input type="text" placeholder="ntfy server URL (e.g. https://ntfy.sh)" value="${esc(push.ntfyServerURL)}" data-input="pNtfyServer" autocapitalize="off" autocorrect="off" spellcheck="false">
    <input type="text" placeholder="ntfy topic" value="${esc(push.ntfyTopic)}" data-input="pNtfyTopic" autocapitalize="off" autocorrect="off" spellcheck="false">

    <h2>Notify on</h2>
    <label class="field-toggle"><input type="checkbox" data-change="pNotifyStarted" ${chk(push.notifyOnBuildStarted)}> Build started</label>
    <label class="field-toggle"><input type="checkbox" data-change="pNotifySuccess" ${chk(push.notifyOnBuildSuccess)}> Build succeeded</label>
    <label class="field-toggle"><input type="checkbox" data-change="pNotifyFailure" ${chk(push.notifyOnBuildFailure)}> Build failed</label>

    <button class="btn btn-primary" data-click="saveSettings" style="margin-top:16px">Save Settings</button>`;
}

async function saveSettings() {
  const s = state.settings;
  state.settingsMsg = '';
  state.settingsError = '';
  const port = parseInt(s.serverPort, 10);
  if (isNaN(port) || port < 1024 || port > 65535) {
    state.settingsError = 'Port must be between 1024 and 65535.';
    render();
    return;
  }
  s.serverPort = port;
  try {
    state.settings = await api('/api/v1/settings', { method: 'PUT', body: JSON.stringify(s) });
    state.settingsMsg = 'Settings saved.';
    render();
    loadStatus();
  } catch (e) {
    state.settingsError = e.message;
    render();
  }
}

// ── Action registrations ────────────────────────────────────────────

ACTIONS.saveSettings = () => saveSettings();

// Text fields mutate state.settings in place (no re-render, to keep focus).
ACTIONS.sPort = (el) => { state.settings.serverPort = el.value; };
ACTIONS.sHostname = (el) => { state.settings.hostname = el.value; };
ACTIONS.sCertPath = (el) => { state.settings.certPath = el.value; };
ACTIONS.sKeyPath = (el) => { state.settings.keyPath = el.value; };
ACTIONS.pProwlKey = (el) => { state.settings.pushNotificationConfig.prowlAPIKey = el.value; };
ACTIONS.pPushoverToken = (el) => { state.settings.pushNotificationConfig.pushoverAppToken = el.value; };
ACTIONS.pPushoverUser = (el) => { state.settings.pushNotificationConfig.pushoverUserKey = el.value; };
ACTIONS.pNtfyServer = (el) => { state.settings.pushNotificationConfig.ntfyServerURL = el.value; };
ACTIONS.pNtfyTopic = (el) => { state.settings.pushNotificationConfig.ntfyTopic = el.value; };

// Checkboxes mutate state.settings (no re-render needed).
ACTIONS.pProwlEnabled = (el) => { state.settings.pushNotificationConfig.prowlEnabled = el.checked; };
ACTIONS.pPushoverEnabled = (el) => { state.settings.pushNotificationConfig.pushoverEnabled = el.checked; };
ACTIONS.pNtfyEnabled = (el) => { state.settings.pushNotificationConfig.ntfyEnabled = el.checked; };
ACTIONS.pNotifyStarted = (el) => { state.settings.pushNotificationConfig.notifyOnBuildStarted = el.checked; };
ACTIONS.pNotifySuccess = (el) => { state.settings.pushNotificationConfig.notifyOnBuildSuccess = el.checked; };
ACTIONS.pNotifyFailure = (el) => { state.settings.pushNotificationConfig.notifyOnBuildFailure = el.checked; };
