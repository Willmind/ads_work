import { connect, request, subscribe } from './bridge.js';
import { entrance, resizeCard, dismiss, showToast, installDisclosures, createTabs, createBackupPicker } from './motion.js';
import { createBuildDirectory } from './build-directory.js';
const $ = selector => document.querySelector(selector);
let state = { records: [], backups: [], busy: false, logs: '', operation: null };
let selectedId;
let mode = 'build';
let toastTimer;
let initialized = false;
installDisclosures();
const moveTabIndicator = createTabs(document.querySelector('.segmented'));
const backupPicker = createBackupPicker(document.querySelector('#backups'));
const inputs = ['libraryPath', 'projectPath', 'newNote', 'downloadUrl', 'downloadMd5', 'editVersion', 'editNote'];
const date = value => new Intl.DateTimeFormat('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date(value));
const buildDirectory = createBuildDirectory({ getProjectPath: () => $('#projectPath').value, isBusy: () => state.busy, formatDate: date });
function settings() { return { projectPath: $('#projectPath').value.trim(), libraryPath: $('#libraryPath').value.trim() }; }
function filtered() {
  const keywords = $('#search').value.toLowerCase().trim().split(/\s+/).filter(Boolean);
  return state.records.filter(record => keywords.every(keyword => [record.version, record.note, record.branch, record.fileName, record.sourceLabel].join(' ').toLowerCase().includes(keyword)));
}
function applyState(next, updatePaths = false) {
  if (!next) return;
  state = next;
  if (!initialized || updatePaths) {
    $('#projectPath').value = state.settings.projectPath;
    $('#libraryPath').value = state.settings.libraryPath;
  }
  initialized = true;
  document.documentElement.dataset.ready = "true";
  if (next.selectedId && next.records.some(record => record.id === next.selectedId)) selectedId = next.selectedId;
  renderRecords(); renderBackups(); renderOperation(); setBusy();
  $('#log').textContent = state.logs || '';
  $('#logDisclosure').hidden = !state.logs;
  void buildDirectory.refresh();
}
function renderRecords() {
  const records = filtered();
  const body = $('#records'); body.replaceChildren();
  if (!records.some(record => record.id === selectedId)) selectedId = records[0]?.id;
  $('#recordCount').textContent = records.length === state.records.length ? `${records.length} 条` : `${records.length} / ${state.records.length} 条`;
  $('#tableWrap').hidden = records.length === 0;
  $('#emptyState').hidden = records.length !== 0;
  $('#emptyTitle').textContent = state.records.length ? '没有匹配的记录' : '还没有保存的 JS';
  $('#emptyDescription').textContent = state.records.length ? '试试其他版本、备注或分支关键词。' : '打包、下载或导入后，每个版本都会保留在这里。';
  for (const record of records) {
    const row = document.createElement('tr');
    row.tabIndex = 0; row.dataset.id = record.id; row.setAttribute('aria-selected', String(record.id === selectedId));
    for (const [key, text] of [['version', record.version], ['note', record.note || '—'], ['source', record.sourceLabel], ['branch', record.branch || '—'], ['date', date(record.createdAt)]]) {
      const cell = document.createElement('td');
      if (key === 'source') { const badge = document.createElement('span'); badge.className = 'source-badge'; badge.textContent = text; cell.append(badge); }
      else cell.textContent = text;
      cell.title = text; row.append(cell);
    }
    row.addEventListener('click', () => select(record.id));
    row.addEventListener('keydown', event => {
      if (['Enter', ' '].includes(event.key)) { event.preventDefault(); select(record.id); }
      if (['ArrowDown', 'ArrowUp'].includes(event.key)) {
        event.preventDefault(); const index = records.indexOf(record) + (event.key === 'ArrowDown' ? 1 : -1);
        if (records[index]) { select(records[index].id); $('#records').children[index]?.focus(); }
      }
    });
    body.append(row);
  }
  renderSelection();
}
function select(id) {
  if (state.busy) return;
  selectedId = id;
  for (const row of $('#records').children) row.setAttribute('aria-selected', String(row.dataset.id === id));
  renderSelection(); entrance($('#selection'));
}
function renderSelection() {
  const record = state.records.find(item => item.id === selectedId);
  $('#selection').hidden = !record;
  if (!record) return;
  // Preserve a draft while an unrelated status/progress event arrives.
  if ($('#selection').dataset.id !== record.id || !['editVersion', 'editNote'].includes(document.activeElement?.id)) {
    $('#editVersion').value = record.version; $('#editNote').value = record.note;
  }
  $('#selection').dataset.id = record.id;
  $('#fileDetails').textContent = `${record.fileName} · ${(record.size / 1048576).toFixed(2)} MB\nMD5: ${record.md5}\nSHA-256: ${record.sha256}`;
}
function renderBackups() {
  const previous = $('#backups').value;
  $('#backups').replaceChildren();
  for (const backup of state.backups) {
    const option = document.createElement('option'); option.value = backup.id;
    option.textContent = `${date(backup.createdAt)} · ${backup.label}`; $('#backups').append(option);
  }
  if (state.backups.some(backup => backup.id === previous)) $('#backups').value = previous;
  $('#backupCount').textContent = String(state.backups.length);
  $('#backupEmpty').hidden = state.backups.length > 0;
  $('#backupControls').hidden = state.backups.length === 0;
  backupPicker.refresh();
}
function renderOperation() {
  const operation = state.operation;
  const wasHidden = $('#operationCard').hidden;
  $('#operationCard').hidden = !operation;
  if (operation && wasHidden) entrance($('#operationCard'));
  if (!operation) return;
  $('#operationCard').dataset.state = operation.state;
  $('#stage').textContent = operation.stage;
  $('#status').textContent = operation.message;
  $('#cancel').hidden = !state.busy;
}
function setBusy() {
  for (const button of document.querySelectorAll('button')) {
    if (button.dataset.action === 'cancel') { button.disabled = !!state.stopping; continue; }
    button.disabled = state.busy;
  }
  for (const id of inputs) $(`#${id}`).disabled = state.busy;
  $('#backups').disabled = state.busy;
  if (state.busy) backupPicker.close();
  $('#search').disabled = state.busy;
  $('#addPrimary').disabled = state.busy || (mode === 'download' && !$('#downloadUrl').value.trim());
  buildDirectory.setBusy();
}
function setMode(next) {
  if (state.busy) return;
  const previousHeight = $('.add-card').getBoundingClientRect().height;
  const changed = mode !== next;
  mode = next;
  for (const button of document.querySelectorAll('[data-mode]')) {
    const active = button.dataset.mode === next;
    button.setAttribute('aria-selected', String(active)); button.tabIndex = active ? 0 : -1;
    $(`#panel-${button.dataset.mode}`).hidden = !active;
  }
  const primary = $('#addPrimary');
  const names = { build: ['buildSave', '打包保存', 'package'], download: ['download', '下载并保存', 'download'], file: ['import', '选择 JS 并导入', 'file-input'] };
  primary.dataset.action = names[next][0]; primary.querySelector('span').textContent = names[next][1];
  primary.querySelector('use').setAttribute('href', `icons.svg#${names[next][2]}`);
  $('#buildInstall').hidden = next !== 'build'; setBusy();
  moveTabIndicator();
  if (changed) { resizeCard($('.add-card'), previousHeight); entrance($(`#panel-${next}`)); }
}
function toast(message) {
  clearTimeout(toastTimer); $('#toast').textContent = message; showToast($('#toast'));
  toastTimer = setTimeout(() => dismiss($('#toast')), 4500);
}
async function action(name) {
  if (state.busy && name !== 'cancel' && name !== 'copyLog') return;
  const args = { settings: settings(), id: selectedId, note: $('#newNote').value };
  if (name === 'download') { args.url = $('#downloadUrl').value.trim(); args.md5 = $('#downloadMd5').value.trim(); }
  if (name === 'updateMetadata') { args.version = $('#editVersion').value; args.note = $('#editNote').value; }
  if (name === 'restore') args.id = $('#backups').value;
  try {
    const result = await request(name, args);
    if (result?.snapshot) applyState(result.snapshot, ['chooseProject', 'chooseLibrary', 'saveSettings'].includes(name));
    if (result?.message) toast(result.message);
  } catch (error) { toast(error.message); }
}
for (const button of document.querySelectorAll('[data-action]')) button.addEventListener('click', () => { void action(button.dataset.action); });
for (const button of document.querySelectorAll('[data-mode]')) {
  button.addEventListener('click', () => setMode(button.dataset.mode));
  button.addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const modes = ['build', 'download', 'file'];
    const index = event.key === 'Home' ? 0 : event.key === 'End' ? 2 : (modes.indexOf(mode) + (event.key === 'ArrowRight' ? 1 : 2)) % 3;
    setMode(modes[index]); $(`#tab-${modes[index]}`).focus();
  });
}
$('#search').addEventListener('input', renderRecords);
$('#downloadUrl').addEventListener('input', setBusy);
$('#libraryPath').addEventListener('change', () => { void action('saveSettings'); });
subscribe((event, data) => {
  if (event === 'state') applyState(data);
  if (event === 'progress') {
    state.busy = data.busy; state.stopping = data.stopping; state.operation = data.operation;
    state.logs = data.logs; renderOperation(); setBusy();
    $('#log').textContent = data.logs; $('#logDisclosure').hidden = !data.logs;
  }
});
try { await connect(); const result = await request('state'); applyState(result.snapshot); buildDirectory.start(); }
catch (error) { $('#stage').textContent = '无法连接本地功能'; $('#status').textContent = error.message; $('#operationCard').hidden = false; $('#operationCard').dataset.state = 'failure'; }
