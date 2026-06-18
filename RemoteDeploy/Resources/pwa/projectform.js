// Project create / edit / delete UI for the RemoteDeploy PWA, plus the
// filesystem browser and scheme detection that back the path + scheme pickers.
// Mirrors the macOS ProjectFormView. Loaded after app.js; shares its globals
// (state, api, esc, render, slugify, uuid, loadProjects) and registers ACTIONS.

// Validators mirror the macOS boundary: BundleIDValidator (reverse-DNS) and
// ProjectSetupValidators.validateTeamID (10-char uppercase alphanumeric).
const BUNDLE_RE = /^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z][A-Za-z0-9-]*)+$/;
const TEAM_RE = /^[A-Z0-9]{10}$/;

function newProjectDefaults() {
  return {
    id: uuid(), name: '', projectPath: '', projectFile: null, workspaceFile: null,
    scheme: '', bundleID: '', teamID: '', provisioningProfile: null,
    buildConfiguration: 'Release', urlSlug: '', exportMethod: 'development',
    platform: 'iOS', projectType: 'xcode', expoAppDirectory: null,
    localDeploy: false, localDeployPath: null,
  };
}

function openProjectForm(project) {
  if (project) {
    state.editingProject = JSON.parse(JSON.stringify(project));
    state.formMode = 'edit';
    state.detectedSchemes = project.scheme ? [project.scheme] : [];
  } else {
    state.editingProject = newProjectDefaults();
    state.formMode = 'create';
    state.detectedSchemes = [];
  }
  state.formError = '';
  state.view = 'projectForm';
  render();
}

function closeProjectForm() {
  state.view = null;
  state.editingProject = null;
  state.formError = '';
  render();
}

function baseName(path) {
  return (path || '').split('/').filter(Boolean).pop() || '';
}

function renderProjectForm() {
  const p = state.editingProject || newProjectDefaults();
  const isMacOS = p.platform === 'macOS';
  const schemeField = state.detectedSchemes.length
    ? `<select data-change="fScheme">${state.detectedSchemes.map(s =>
        `<option value="${esc(s)}" ${s === p.scheme ? 'selected' : ''}>${esc(s)}</option>`).join('')}</select>
       <button class="btn-sm btn-secondary" data-click="detectSchemes" ${p.projectPath ? '' : 'disabled'}>Re-detect</button>`
    : `<input type="text" placeholder="Scheme" value="${esc(p.scheme)}" data-input="fScheme">
       <button class="btn-sm btn-secondary" data-click="detectSchemes" ${p.projectPath ? '' : 'disabled'}>Detect</button>`;
  return `
    <div class="form-screen">
      <div class="row-between">
        <h1>${state.formMode === 'edit' ? 'Edit Project' : 'New Project'}</h1>
        <button class="btn-sm btn-secondary" data-click="cancelForm">Cancel</button>
      </div>
      ${state.formError ? `<div class="form-error">${esc(state.formError)}</div>` : ''}

      <label class="field-label">Project Folder</label>
      <div class="field-row">
        <input type="text" placeholder="/Users/you/MyApp" value="${esc(p.projectPath)}" data-input="fPath">
        <button class="btn-sm btn-secondary" data-click="openBrowser">Browse</button>
      </div>
      ${p.projectFile ? `<div class="muted-sm" style="margin:-6px 0 12px">${esc(p.projectFile)}</div>` : ''}
      ${p.workspaceFile ? `<div class="muted-sm" style="margin:-6px 0 12px">${esc(p.workspaceFile)}</div>` : ''}

      <label class="field-label">Name</label>
      <input type="text" placeholder="My App" value="${esc(p.name)}" data-input="fName">

      <label class="field-label">Scheme</label>
      <div class="field-row">${schemeField}</div>

      <label class="field-label">Bundle ID</label>
      <input type="text" placeholder="com.example.myapp" value="${esc(p.bundleID)}" data-input="fBundleID" autocapitalize="off" autocorrect="off" spellcheck="false">

      <label class="field-label">Team ID (optional)</label>
      <input type="text" placeholder="ABCDE12345" value="${esc(p.teamID)}" data-input="fTeamID" autocapitalize="characters" autocorrect="off" spellcheck="false">

      <label class="field-label">Provisioning Profile (optional)</label>
      <input type="text" placeholder="Leave empty for automatic signing" value="${esc(p.provisioningProfile || '')}" data-input="fProfile">

      <label class="field-label">Configuration</label>
      <select data-change="fConfig">
        <option value="Debug" ${p.buildConfiguration === 'Debug' ? 'selected' : ''}>Debug</option>
        <option value="Release" ${p.buildConfiguration === 'Release' ? 'selected' : ''}>Release</option>
      </select>

      <label class="field-label">Export Method</label>
      <select data-change="fExport">
        <option value="ad-hoc" ${p.exportMethod === 'ad-hoc' ? 'selected' : ''}>Ad Hoc</option>
        <option value="development" ${p.exportMethod === 'development' ? 'selected' : ''}>Development</option>
      </select>

      <label class="field-label">Platform</label>
      <select data-change="fPlatform">
        <option value="iOS" ${p.platform === 'iOS' ? 'selected' : ''}>iOS</option>
        <option value="macOS" ${isMacOS ? 'selected' : ''}>macOS</option>
      </select>

      ${isMacOS ? `
      <label class="field-toggle"><input type="checkbox" data-change="fLocalDeploy" ${p.localDeploy ? 'checked' : ''}> Auto-deploy locally after build</label>
      ${p.localDeploy ? `
      <label class="field-label">Deploy path (default: /Applications)</label>
      <input type="text" placeholder="/Applications" value="${esc(p.localDeployPath || '')}" data-input="fLocalPath">` : ''}` : ''}

      <label class="field-label">URL Slug</label>
      <input type="text" placeholder="myapp" value="${esc(p.urlSlug)}" data-input="fSlug">

      <div class="form-actions">
        ${state.formMode === 'edit' ? `<button class="btn btn-danger" data-click="deleteFromForm">Delete</button>` : ''}
        <button class="btn btn-primary" data-click="saveProject">Save</button>
      </div>
    </div>`;
}

// ── Filesystem browser ──────────────────────────────────────────────

function renderBrowser() {
  const b = state.browse;
  if (!b) return `<div class="form-screen"><h1>Browse</h1><div class="spinner"></div></div>`;
  const rows = [];
  if (b.parentPath) rows.push(`<div class="browse-row" data-click="browseUp">.. (up a level)</div>`);
  b.directories.forEach(d => rows.push(
    `<div class="browse-row" data-click="browseInto" data-name="${esc(d)}"><span class="browse-icon">[dir]</span> ${esc(d)}</div>`));
  b.xcodeWorkspaces.forEach(w => rows.push(
    `<div class="browse-row browse-pick" data-click="pickWorkspace" data-name="${esc(w)}"><span class="browse-icon">[ws]</span> ${esc(w)}</div>`));
  b.xcodeProjects.forEach(x => rows.push(
    `<div class="browse-row browse-pick" data-click="pickProject" data-name="${esc(x)}"><span class="browse-icon">[proj]</span> ${esc(x)}</div>`));
  return `
    <div class="form-screen">
      <div class="row-between">
        <h1>Choose Project</h1>
        <button class="btn-sm btn-secondary" data-click="closeBrowser">Cancel</button>
      </div>
      ${state.formError ? `<div class="form-error">${esc(state.formError)}</div>` : ''}
      <div class="muted-sm" style="word-break:break-all;margin-bottom:8px">${esc(b.currentPath)}</div>
      <button class="btn-sm btn-primary" data-click="pickFolder" style="margin-bottom:12px">Use this folder</button>
      <div class="browse-list">${rows.join('') || '<div class="muted">Empty.</div>'}</div>
    </div>`;
}

async function browseTo(path) {
  try {
    state.browse = await api('/api/v1/filesystem/browse' + (path ? '?path=' + encodeURIComponent(path) : ''));
    state.formError = '';
  } catch (e) {
    state.formError = e.message;
  }
  render();
}

async function detectSchemesFor(path) {
  if (!path) return;
  try {
    const r = await api('/api/v1/filesystem/schemes?path=' + encodeURIComponent(path));
    state.detectedSchemes = r.schemes || [];
    if (state.detectedSchemes.length && !state.editingProject.scheme) {
      state.editingProject.scheme = state.detectedSchemes[0];
    }
    state.formError = state.detectedSchemes.length ? '' : 'No schemes detected; enter the scheme name manually.';
  } catch (e) {
    state.formError = 'Scheme detection failed: ' + e.message;
  }
  render();
}

function applyPickedName() {
  if (!state.editingProject.name) {
    state.editingProject.name = baseName(state.browse.currentPath);
    state.editingProject.urlSlug = slugify(state.editingProject.name);
  }
}

// ── Validation + save ───────────────────────────────────────────────

function validateProjectForm() {
  const p = state.editingProject;
  if (!p.name.trim()) return 'Project name is required.';
  if (!p.projectPath.trim()) return 'Select a project folder.';
  if (!p.scheme.trim()) return 'Select or enter a scheme.';
  if (!p.bundleID.trim()) return 'Bundle ID is required.';
  if (!BUNDLE_RE.test(p.bundleID)) return 'Bundle ID must be reverse-DNS format (e.g. com.example.app).';
  if (p.teamID && !TEAM_RE.test(p.teamID)) return 'Team ID must be exactly 10 uppercase alphanumeric characters.';
  return null;
}

async function saveProject() {
  const err = validateProjectForm();
  if (err) { state.formError = err; render(); return; }
  const p = { ...state.editingProject };
  if (!p.urlSlug.trim()) p.urlSlug = slugify(p.name);
  p.provisioningProfile = p.provisioningProfile || null;
  p.localDeployPath = p.localDeployPath || null;
  try {
    if (state.formMode === 'create') {
      await api('/api/v1/projects', { method: 'POST', body: JSON.stringify(p) });
    } else {
      await api('/api/v1/projects/' + p.id, { method: 'PUT', body: JSON.stringify(p) });
    }
    state.tab = 'projects';
    closeProjectForm();
    await loadProjects();
  } catch (e) {
    state.formError = e.message;
    render();
  }
}

// ── Action registrations ────────────────────────────────────────────

ACTIONS.cancelForm = () => closeProjectForm();
ACTIONS.saveProject = () => saveProject();
ACTIONS.deleteFromForm = async () => {
  const p = state.editingProject;
  if (!p || !confirm(`Delete "${p.name}"? Your source code is not affected.`)) return;
  try {
    await api('/api/v1/projects/' + p.id, { method: 'DELETE' });
    if (state.selectedProjectId === p.id) state.selectedProjectId = null;
    state.tab = 'projects';
    closeProjectForm();
    await loadProjects();
  } catch (e) { state.formError = e.message; render(); }
};

// Field updaters. Text inputs (data-input) mutate state without re-rendering so
// the field keeps focus; selects/toggles (data-change) that alter form structure
// re-render.
ACTIONS.fPath = (el) => { state.editingProject.projectPath = el.value; };
ACTIONS.fName = (el) => { state.editingProject.name = el.value; };
ACTIONS.fScheme = (el) => { state.editingProject.scheme = el.value; };
ACTIONS.fBundleID = (el) => { state.editingProject.bundleID = el.value; };
ACTIONS.fTeamID = (el) => { state.editingProject.teamID = el.value; };
ACTIONS.fProfile = (el) => { state.editingProject.provisioningProfile = el.value || null; };
ACTIONS.fConfig = (el) => { state.editingProject.buildConfiguration = el.value; };
ACTIONS.fExport = (el) => { state.editingProject.exportMethod = el.value; };
ACTIONS.fPlatform = (el) => { state.editingProject.platform = el.value; render(); };
ACTIONS.fLocalDeploy = (el) => { state.editingProject.localDeploy = el.checked; render(); };
ACTIONS.fLocalPath = (el) => { state.editingProject.localDeployPath = el.value || null; };
ACTIONS.fSlug = (el) => { state.editingProject.urlSlug = el.value; };

// Browser actions.
ACTIONS.openBrowser = () => { state.view = 'browser'; state.formError = ''; browseTo(state.editingProject.projectPath || null); };
ACTIONS.closeBrowser = () => { state.view = 'projectForm'; state.formError = ''; render(); };
ACTIONS.browseUp = () => browseTo(state.browse.parentPath);
ACTIONS.browseInto = (el) => browseTo(state.browse.currentPath + '/' + el.dataset.name);
ACTIONS.pickFolder = () => {
  state.editingProject.projectPath = state.browse.currentPath;
  state.editingProject.projectFile = null;
  state.editingProject.workspaceFile = null;
  applyPickedName();
  state.view = 'projectForm';
  render();
};
ACTIONS.pickProject = (el) => {
  const name = el.dataset.name;
  state.editingProject.projectPath = state.browse.currentPath;
  state.editingProject.projectFile = name;
  state.editingProject.workspaceFile = null;
  applyPickedName();
  state.view = 'projectForm';
  // Detect schemes against the chosen .xcodeproj (the API needs the bundle path).
  detectSchemesFor(state.browse.currentPath + '/' + name);
};
ACTIONS.pickWorkspace = (el) => {
  state.editingProject.projectPath = state.browse.currentPath;
  state.editingProject.workspaceFile = el.dataset.name;
  state.editingProject.projectFile = null;
  applyPickedName();
  state.view = 'projectForm';
  state.formError = 'Workspace selected; enter the scheme name manually (auto-detect supports .xcodeproj only).';
  render();
};
ACTIONS.detectSchemes = () => {
  const p = state.editingProject;
  const path = p.projectFile ? `${p.projectPath}/${p.projectFile}` : p.projectPath;
  detectSchemesFor(path);
};
