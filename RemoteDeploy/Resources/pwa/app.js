// RemoteDeploy PWA - vanilla JS app for controlling builds from any device.
// Talks to the same /api/v1/ endpoints as the iOS companion app.
//
// Event handling is CSP-clean: the document CSP is `default-src 'self'` with no
// `script-src 'unsafe-inline'`, so inline on* attributes are blocked. Instead,
// interactive elements carry data-click / data-change / data-input / data-submit
// attributes that name an entry in the ACTIONS table, dispatched by delegated
// listeners on the persistent #app element (initEvents). projectform.js and
// settingsform.js register additional ACTIONS and share this file's globals.

const state = {
  token: localStorage.getItem('rd_token') || '',
  tab: 'projects',
  projects: [],
  buildStatus: null,
  buildLog: [],
  installs: [],
  status: null,
  settings: null,
  selectedProjectId: null,
  ws: null,
  // Overlay screens layered over the tabbed UI (set by projectform.js).
  view: null,            // null | 'projectForm' | 'browser'
  editingProject: null,  // working copy of a ProjectConfig while the form is open
  formMode: 'create',    // 'create' | 'edit'
  formError: '',
  detectedSchemes: [],
  browse: null,          // last /filesystem/browse response
};

// Action registry: name -> handler(el, event). Populated here and by the
// projectform.js / settingsform.js scripts loaded after this file.
const ACTIONS = {};

// ── API Client ──────────────────────────────────────────────────────

async function api(path, opts = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (state.token) headers['Authorization'] = `Bearer ${state.token}`;
  const res = await fetch(path, { ...opts, headers });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    const e = new Error(err.message || `HTTP ${res.status}`);
    e.status = res.status;
    throw e;
  }
  // Some endpoints (204-ish deletes) may return an empty body; tolerate it.
  return res.json().catch(() => ({}));
}

// ── WebSocket ───────────────────────────────────────────────────────

function connectWS() {
  // Reuse a live socket instead of churning one per render.
  if (state.ws && (state.ws.readyState === WebSocket.OPEN || state.ws.readyState === WebSocket.CONNECTING)) return;
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  // Browsers can't set Authorization on a WS handshake, so the bearer token is
  // passed via the Sec-WebSocket-Protocol subprotocol list ("bearer, <token>").
  const ws = new WebSocket(`${proto}//${location.host}/api/v1/ws`, ['bearer', state.token]);
  ws.onopen = () => {
    ws.send(JSON.stringify({ type: 'subscribe', payload: 'buildlog' }));
    ws.send(JSON.stringify({ type: 'subscribe', payload: 'buildstatus' }));
  };
  ws.onmessage = (e) => {
    try {
      const msg = JSON.parse(e.data);
      if (msg.type === 'buildlog') {
        state.buildLog.push({ t: Date.now(), text: msg.payload });
        if (state.tab === 'build' && !state.view) renderBuildLog();
      } else if (msg.type === 'buildstatus') {
        state.buildStatus = JSON.parse(msg.payload);
        if (state.tab === 'build' && !state.view) renderBuildStatus();
      }
    } catch (e) { console.error('WS message parse error:', e); }
  };
  ws.onclose = () => { state.ws = null; setTimeout(connectWS, 3000); };
  state.ws = ws;
}

// ── Rendering ───────────────────────────────────────────────────────

function render() {
  const app = document.getElementById('app');
  if (!state.token) { app.innerHTML = renderHeader(false) + renderConnect(); return; }
  // Overlay screens (defined in projectform.js) take over the whole viewport.
  if (state.view === 'browser') { app.innerHTML = renderBrowser(); return; }
  if (state.view === 'projectForm') { app.innerHTML = renderProjectForm(); return; }
  app.innerHTML = renderHeader() + renderTabs() + renderTabContent();
  connectWS();
}

// Top toolbar: brand mark + theme toggle. showBrand=false on the connect screen
// (which already shows the large app icon) leaves just the theme control.
function renderHeader(showBrand) {
  const brand = showBrand === false
    ? '<span></span>'
    : `<div class="brand"><span class="brand-mark"></span><span class="brand-name">RemoteDeploy</span></div>`;
  return `<header class="appbar">${brand}<button class="theme-toggle" data-click="toggleTheme" aria-label="Toggle theme" title="Theme: tap to cycle auto / light / dark"></button></header>`;
}

// Theme: auto (follow system) | light | dark, persisted in localStorage and
// reflected as data-theme on <html>. Applied before first render to avoid flash.
function applyTheme() {
  const t = localStorage.getItem('rd_theme') || 'dark';
  document.documentElement.setAttribute('data-theme', t);
}
ACTIONS.toggleTheme = () => {
  const order = ['dark', 'light', 'auto'];
  const cur = localStorage.getItem('rd_theme') || 'dark';
  const next = order[(order.indexOf(cur) + 1) % order.length];
  localStorage.setItem('rd_theme', next);
  applyTheme();
  render();
};

function renderConnect() {
  // Pairing requires HTTPS; the server rejects /api/v1/pair over plain HTTP.
  const insecure = location.protocol !== 'https:';
  return `
    <div class="connect-screen">
      <h1>RemoteDeploy</h1>
      <p>Pair this browser to connect.</p>
      ${insecure ? `<div class="connect-warning">Pairing requires a secure connection. Open this page over HTTPS (for example <code>https://your-mac:8443/</code>), then pair.</div>` : ''}
      <form class="connect-form" data-submit="pair">
        <input type="text" id="code-input" placeholder="Enter pairing code" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false">
        <button class="btn btn-primary" type="submit"${insecure ? ' disabled' : ''}>Pair</button>
      </form>
      <div id="connect-error" class="connect-error"></div>
      <p class="connect-hint">On your Mac: Settings &gt; Devices &gt; Pair Browser to get a code.</p>
    </div>`;
}

function renderTabs() {
  const tabs = [
    { id: 'projects', label: 'Projects' },
    { id: 'build', label: 'Build' },
    { id: 'installs', label: 'Installs' },
    { id: 'settings', label: 'Settings' },
  ];
  return `<div class="tabs">${tabs.map(t =>
    `<div class="tab ${state.tab === t.id ? 'active' : ''}" data-click="tab" data-tab="${t.id}">${t.label}</div>`
  ).join('')}</div>`;
}

function renderTabContent() {
  switch (state.tab) {
    case 'projects': return renderProjects();
    case 'build': return renderBuild();
    case 'installs': return renderInstalls();
    case 'settings': return renderSettings();
    default: return '';
  }
}

function macBadge(p) {
  return p.platform && p.platform.toLowerCase() === 'macos'
    ? ' <span class="badge">macOS</span>' : '';
}

function renderProjects() {
  const header = `<div class="row-between"><h1>Projects</h1><button class="btn-sm btn-primary" data-click="newProject">+ New</button></div>`;
  if (!state.projects.length) return header + '<p class="muted">No projects yet. Tap <b>+ New</b> to add one.</p>';
  return header + state.projects.map(p => `
    <div class="card">
      <div class="card-header" data-click="selectProject" data-id="${esc(p.id)}" style="cursor:pointer">
        <div>
          <div class="card-title">${esc(p.name)}</div>
          <div class="card-subtitle">${esc(p.bundleID)}${macBadge(p)}</div>
        </div>
        <div class="muted-sm">${esc(p.buildConfiguration)}</div>
      </div>
      <div class="card-actions">
        <button class="btn-sm btn-secondary" data-click="editProject" data-id="${esc(p.id)}">Edit</button>
        <button class="btn-sm btn-danger" data-click="deleteProject" data-id="${esc(p.id)}">Delete</button>
      </div>
    </div>`).join('');
}

function renderBuild() {
  const proj = state.projects.find(p => p.id === state.selectedProjectId);
  const isMacOS = proj && proj.platform && proj.platform.toLowerCase() === 'macos';
  const building = state.buildStatus && state.buildStatus.state === 'building';
  const statusHtml = state.buildStatus
    ? `<div class="build-status ${statusColor(state.buildStatus.state)}"><span class="status-dot ${statusColor(state.buildStatus.state)}"></span><span class="bs-label">${esc(state.buildStatus.state)}</span>${state.buildStatus.message ? `<span class="bs-msg">${esc(state.buildStatus.message)}</span>` : ''}</div>`
    : '';
  const buildBtnLabel = building ? (isMacOS ? 'Building…' : 'Deploying…') : (isMacOS ? 'Build & Package' : 'Build & Deploy');
  const zipBtn = isMacOS && state.buildStatus && state.buildStatus.state === 'success'
    ? `<a class="btn btn-secondary" href="/${esc(proj.urlSlug)}/app.zip">Download .zip</a>` : '';
  return `
    <h1>Build</h1>
    <select data-change="selectBuildProject">
      <option value="">Select a project…</option>
      ${state.projects.map(p => `<option value="${esc(p.id)}" ${p.id === state.selectedProjectId ? 'selected' : ''}>${esc(p.name)}${p.platform && p.platform.toLowerCase() === 'macos' ? ' (macOS)' : ''}</option>`).join('')}
    </select>
    ${statusHtml}
    <div class="build-actions">
      <button class="btn btn-primary${building ? ' loading' : ''}" data-click="triggerBuild" ${state.selectedProjectId && !building ? '' : 'disabled'}>${buildBtnLabel}</button>
      ${zipBtn}
    </div>
    <div class="row-between"><h2>Build Log</h2><button class="btn-sm btn-secondary" data-click="clearLog">Clear Log</button></div>
    <div class="log" id="build-log">${state.buildLog.map(logRow).join('')}</div>`;
}

function renderBuildLog() {
  const el = document.getElementById('build-log');
  if (el) {
    el.innerHTML = state.buildLog.map(logRow).join('');
    el.scrollTop = el.scrollHeight;
  }
}

function renderBuildStatus() {
  // Re-render the build tab to update status
  if (state.tab === 'build') {
    const app = document.getElementById('app');
    app.innerHTML = renderHeader() + renderTabs() + renderBuild();
  }
}

function renderInstalls() {
  const header = state.installs.length
    ? `<div class="row-between"><h1>Installs</h1><button class="btn-sm btn-danger" data-click="clearInstalls">Clear All</button></div>`
    : '<h1>Installs</h1>';
  if (!state.installs.length) return header + '<p class="muted">No installs yet.</p>';
  return header + state.installs.map(i => `
    <div class="card">
      <div class="card-header">
        <div>
          <div class="card-title">${esc(i.projectName)}</div>
          <div class="card-subtitle">${esc(i.sourceIP)} &mdash; ${new Date(i.timestamp).toLocaleString()}</div>
        </div>
        <button class="btn-sm btn-secondary" data-click="deleteInstall" data-id="${esc(i.id)}">Delete</button>
      </div>
    </div>`).join('');
}

function renderSettings() {
  const s = state.status;
  const statusCard = `
    <div class="card">
      <div class="list-item"><span>Server</span><span>${s ? (s.serverRunning ? '<span class="status-dot green"></span>Running' : '<span class="status-dot red"></span>Stopped') : '...'}</span></div>
      <div class="list-item"><span>Tailscale</span><span>${s ? (s.tailscaleConnected ? '<span class="status-dot green"></span>Connected' : '<span class="status-dot red"></span>Disconnected') : '...'}</span></div>
      ${s?.hostname ? `<div class="list-item"><span>Hostname</span><span style="font-size:13px">${esc(s.hostname)}</span></div>` : ''}
    </div>`;
  // renderSettingsForm is defined in settingsform.js; it shows a spinner until
  // state.settings has loaded.
  return `<h1>Settings</h1>${statusCard}${renderSettingsForm()}
    <button class="btn btn-danger" data-click="disconnect" style="margin-top:24px">Disconnect</button>`;
}

// ── Core actions ────────────────────────────────────────────────────

ACTIONS.pair = (el, e) => doPair(e);
ACTIONS.disconnect = () => doDisconnect();
ACTIONS.tab = (el) => switchTab(el.dataset.tab);
ACTIONS.selectProject = (el) => selectProject(el.dataset.id);
ACTIONS.newProject = () => openProjectForm(null);
ACTIONS.editProject = (el) => openProjectForm(projectById(el.dataset.id));
ACTIONS.deleteProject = (el) => deleteProject(el.dataset.id);
ACTIONS.selectBuildProject = (el) => { state.selectedProjectId = el.value || null; render(); };
ACTIONS.triggerBuild = () => triggerBuild();
ACTIONS.clearLog = () => { state.buildLog = []; renderBuildLog(); };
ACTIONS.deleteInstall = (el) => deleteInstall(el.dataset.id);
ACTIONS.clearInstalls = () => clearInstalls();

async function doPair(event) {
  if (event) event.preventDefault();
  const input = document.getElementById('code-input');
  const errEl = document.getElementById('connect-error');
  if (errEl) errEl.textContent = '';
  const code = input ? input.value.trim() : '';
  if (!code) return;
  try {
    // The pairing code is the raw token; POST it to claim a paired-device record.
    const res = await fetch('/api/v1/pair', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: code, deviceName: 'Browser' }),
    });
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      // Surface the server's reason (invalid/expired code, HTTPS required, rate limit).
      throw new Error(body.message || `Pairing failed (HTTP ${res.status})`);
    }
    // Pairing succeeded: the code doubles as the bearer token from now on.
    state.token = code;
    localStorage.setItem('rd_token', code);
    render();
    await loadData();
  } catch (e) {
    if (errEl) errEl.textContent = e.message;
    else alert(e.message);
  }
}

function doDisconnect() {
  state.token = '';
  localStorage.removeItem('rd_token');
  if (state.ws) state.ws.close();
  state.ws = null;
  render();
}

function switchTab(tab) {
  state.tab = tab;
  render();
  if (tab === 'projects') loadProjects();
  if (tab === 'installs') loadInstalls();
  if (tab === 'settings') { loadStatus(); loadSettings(); }
}

function selectProject(id) {
  state.selectedProjectId = id;
  state.tab = 'build';
  render();
}

async function triggerBuild() {
  if (!state.selectedProjectId) return;
  state.buildLog = [];
  try {
    state.buildStatus = await api(`/api/v1/projects/${state.selectedProjectId}/build`, { method: 'POST', body: '{}' });
    render();
  } catch (e) { alert(e.message); }
}

async function deleteProject(id) {
  const p = projectById(id);
  if (!p) return;
  if (!confirm(`Delete "${p.name}"? This removes the project from RemoteDeploy; your source code is not affected.`)) return;
  try {
    await api(`/api/v1/projects/${id}`, { method: 'DELETE' });
    if (state.selectedProjectId === id) state.selectedProjectId = null;
    await loadProjects();
  } catch (e) { alert(e.message); }
}

async function deleteInstall(id) {
  try {
    await api(`/api/v1/installs/${id}`, { method: 'DELETE' });
    await loadInstalls();
  } catch (e) { alert(e.message); }
}

async function clearInstalls() {
  if (!confirm('Clear all install records?')) return;
  try {
    await api('/api/v1/installs', { method: 'DELETE' });
    await loadInstalls();
  } catch (e) { alert(e.message); }
}

// ── Data loading ────────────────────────────────────────────────────

async function loadData() {
  await Promise.all([loadProjects(), loadInstalls(), loadStatus()]);
}

async function loadProjects() {
  try { state.projects = await api('/api/v1/projects'); render(); } catch (e) { handleApiError(e); }
}

async function loadInstalls() {
  try { state.installs = await api('/api/v1/installs'); render(); } catch (e) { handleApiError(e); }
}

async function loadStatus() {
  try { state.status = await api('/api/v1/status'); render(); } catch (e) { handleApiError(e); }
}

async function loadSettings() {
  try { state.settings = await api('/api/v1/settings'); if (state.tab === 'settings' && !state.view) render(); } catch (e) { handleApiError(e); }
}

function handleApiError(e) {
  console.error('API error:', e.message);
  if (e.status === 401 || (e.message && e.message.includes('401'))) { doDisconnect(); }
}

// ── Helpers ─────────────────────────────────────────────────────────

function projectById(id) { return state.projects.find(p => p.id === id); }
function esc(s) { const d = document.createElement('div'); d.textContent = s == null ? '' : String(s); return d.innerHTML.replace(/'/g, '&#39;').replace(/"/g, '&quot;'); }
function statusColor(s) { return { building: 'orange', success: 'green', failure: 'red' }[s] || 'gray'; }
function logClass(l) { const s = (l && typeof l === 'object') ? l.text : l; if (s.includes('error:')) return 'error'; if (s.includes('warning:')) return 'warning'; return ''; }
// Build-log line -> structured row: client-stamped time + severity chip + text.
// Tolerates legacy plain-string entries.
function logLevel(t) { if (/(^|\s)error:|\bfatal\b|❌/i.test(t)) return 'error'; if (/(^|\s)warning:|⚠/i.test(t)) return 'warn'; return 'info'; }
function fmtLogTime(ms) { return new Date(ms || Date.now()).toTimeString().slice(0, 8); }
function logRow(l) {
  const text = (l && typeof l === 'object') ? l.text : l;
  const t = (l && typeof l === 'object') ? l.t : Date.now();
  const lvl = logLevel(text || '');
  const chip = lvl === 'error' ? '<span class="log-chip">Error</span>'
    : lvl === 'warn' ? '<span class="log-chip">Warn</span>'
    : '<span class="log-chip" aria-hidden="true"></span>';
  return `<div class="log-row level-${lvl}"><span class="log-time">${fmtLogTime(t)}</span>${chip}<span class="log-text">${esc(text)}</span></div>`;
}
function uuid() { return (crypto && crypto.randomUUID) ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16); }); }
function slugify(name) {
  return (name || '').toLowerCase().replace(/\s+/g, '-').replace(/[^a-z0-9-]/g, '');
}

// ── Init ────────────────────────────────────────────────────────────

function initEvents() {
  const app = document.getElementById('app');
  const dispatch = (kind, e) => {
    const el = e.target.closest(`[data-${kind}]`);
    if (!el) return;
    const fn = ACTIONS[el.getAttribute(`data-${kind}`)];
    if (!fn) return;
    if (kind === 'submit') e.preventDefault();
    fn(el, e);
  };
  ['click', 'change', 'input', 'submit'].forEach(kind =>
    app.addEventListener(kind, (e) => dispatch(kind, e)));
}

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js');
}

applyTheme();
initEvents();
render();
if (state.token) loadData();
