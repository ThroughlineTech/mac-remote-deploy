// RemoteDeploy PWA — vanilla JS app for controlling builds from any device.
// Talks to the same /api/v1/ endpoints as the iOS companion app.

const state = {
  token: localStorage.getItem('rd_token') || '',
  tab: 'projects',
  projects: [],
  buildStatus: null,
  buildLog: [],
  installs: [],
  status: null,
  selectedProjectId: null,
  ws: null,
};

// ── API Client ──────────────────────────────────────────────────────

async function api(path, opts = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (state.token) headers['Authorization'] = `Bearer ${state.token}`;
  const res = await fetch(path, { ...opts, headers });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.message || `HTTP ${res.status}`);
  }
  return res.json();
}

// ── WebSocket ───────────────────────────────────────────────────────

function connectWS() {
  if (state.ws) state.ws.close();
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
        state.buildLog.push(msg.payload);
        if (state.tab === 'build') renderBuildLog();
      } else if (msg.type === 'buildstatus') {
        state.buildStatus = JSON.parse(msg.payload);
        if (state.tab === 'build') renderBuildStatus();
      }
    } catch (e) { console.error('WS message parse error:', e); }
  };
  ws.onclose = () => setTimeout(connectWS, 3000);
  state.ws = ws;
}

// ── Rendering ───────────────────────────────────────────────────────

function render() {
  const app = document.getElementById('app');
  if (!state.token) {
    app.innerHTML = renderConnect();
    return;
  }
  app.innerHTML = renderTabs() + renderTabContent();
  connectWS();
}

function renderConnect() {
  return `
    <div class="connect-screen">
      <h1>RemoteDeploy</h1>
      <p>Enter your API token to connect.</p>
      <input type="password" id="token-input" placeholder="Paste your bearer token" autocomplete="off">
      <button class="btn btn-primary" onclick="doConnect()" style="margin-top:12px">Connect</button>
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
    `<div class="tab ${state.tab === t.id ? 'active' : ''}" onclick="switchTab('${t.id}')">${t.label}</div>`
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

function renderProjects() {
  if (!state.projects.length) return '<div class="spinner"></div>';
  return `<h1>Projects</h1>` + state.projects.map(p => `
    <div class="card" onclick="selectProject('${esc(p.id)}')">
      <div class="card-header">
        <div>
          <div class="card-title">${esc(p.name)}</div>
          <div class="card-subtitle">${esc(p.bundleID)}${p.platform && p.platform.toLowerCase() === 'macos' ? ' <span style="font-size:11px;border:1px solid #c7c7cc;border-radius:4px;padding:1px 5px;margin-left:4px;color:#8e8e93">macOS</span>' : ''}</div>
        </div>
        <div style="font-size:13px;color:var(--text2)">${esc(p.buildConfiguration)}</div>
      </div>
    </div>`).join('');
}

function renderBuild() {
  const proj = state.projects.find(p => p.id === state.selectedProjectId);
  const isMacOS = proj && proj.platform && proj.platform.toLowerCase() === 'macos';
  const statusHtml = state.buildStatus
    ? `<div style="margin:8px 0"><span class="status-dot ${statusColor(state.buildStatus.state)}"></span>${state.buildStatus.state}${state.buildStatus.message ? ': ' + esc(state.buildStatus.message) : ''}</div>`
    : '';
  const buildBtnLabel = isMacOS ? 'Build & Package' : 'Build & Deploy';
  return `
    <h1>Build</h1>
    <select onchange="state.selectedProjectId=this.value;render()">
      <option value="">Select project...</option>
      ${state.projects.map(p => `<option value="${esc(p.id)}" ${p.id === state.selectedProjectId ? 'selected' : ''}>${esc(p.name)}${p.platform && p.platform.toLowerCase() === 'macos' ? ' (macOS)' : ''}</option>`).join('')}
    </select>
    ${statusHtml}
    <button class="btn btn-primary" onclick="triggerBuild()" ${state.selectedProjectId ? '' : 'disabled'}>${buildBtnLabel}</button>
    ${isMacOS && state.buildStatus && state.buildStatus.state === 'success' ? `<a class="btn btn-primary" href="/${esc(proj.urlSlug)}/app.zip" style="display:inline-block;margin-left:8px;text-decoration:none">Download .zip</a>` : ''}
    <div style="margin-top:4px">
      <button class="btn btn-secondary" onclick="state.buildLog=[];renderBuildLog()" style="font-size:13px;padding:8px">Clear Log</button>
    </div>
    <h2>Build Log</h2>
    <div class="log" id="build-log">${state.buildLog.map(l => `<div class="${logClass(l)}">${esc(l)}</div>`).join('')}</div>`;
}

function renderBuildLog() {
  const el = document.getElementById('build-log');
  if (el) {
    el.innerHTML = state.buildLog.map(l => `<div class="${logClass(l)}">${esc(l)}</div>`).join('');
    el.scrollTop = el.scrollHeight;
  }
}

function renderBuildStatus() {
  // Re-render the build tab to update status
  if (state.tab === 'build') {
    const app = document.getElementById('app');
    app.innerHTML = renderTabs() + renderBuild();
  }
}

function renderInstalls() {
  if (!state.installs.length) return '<h1>Installs</h1><p style="color:var(--text2)">No installs yet.</p>';
  return `<h1>Installs</h1>` + state.installs.map(i => `
    <div class="card">
      <div class="card-title">${esc(i.projectName)}</div>
      <div class="card-subtitle">${esc(i.sourceIP)} &mdash; ${new Date(i.timestamp).toLocaleString()}</div>
    </div>`).join('');
}

function renderSettings() {
  const s = state.status;
  return `
    <h1>Settings</h1>
    <div class="card">
      <div class="list-item"><span>Server</span><span>${s ? (s.serverRunning ? '<span class="status-dot green"></span>Running' : '<span class="status-dot red"></span>Stopped') : '...'}</span></div>
      <div class="list-item"><span>Tailscale</span><span>${s ? (s.tailscaleConnected ? '<span class="status-dot green"></span>Connected' : '<span class="status-dot red"></span>Disconnected') : '...'}</span></div>
      ${s?.hostname ? `<div class="list-item"><span>Hostname</span><span style="font-size:13px">${esc(s.hostname)}</span></div>` : ''}
      <div class="list-item"><span>Port</span><span>${s?.serverPort || '...'}</span></div>
    </div>
    <button class="btn btn-danger" onclick="doDisconnect()" style="margin-top:24px">Disconnect</button>`;
}

// ── Actions ─────────────────────────────────────────────────────────

async function doConnect() {
  const token = document.getElementById('token-input').value.trim();
  if (!token) return;
  state.token = token;
  localStorage.setItem('rd_token', token);
  render();
  await loadData();
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
  if (tab === 'settings') loadStatus();
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

function handleApiError(e) {
  console.error('API error:', e.message);
  if (e.message && e.message.includes('401')) { doDisconnect(); }
}

// ── Helpers ─────────────────────────────────────────────────────────

function esc(s) { const d = document.createElement('div'); d.textContent = s || ''; return d.innerHTML.replace(/'/g, '&#39;').replace(/"/g, '&quot;'); }
function statusColor(s) { return { building: 'orange', success: 'green', failure: 'red' }[s] || 'gray'; }
function logClass(l) { if (l.includes('error:')) return 'error'; if (l.includes('warning:')) return 'warning'; return ''; }

// ── Init ────────────────────────────────────────────────────────────

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/app/sw.js');
}

render();
if (state.token) loadData();
