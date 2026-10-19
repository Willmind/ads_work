import { connect, request, subscribe } from './bridge.js';
import { entrance, installDisclosures, showToast, dismiss, refreshFeedback } from './motion.js';
const $ = selector => document.querySelector(selector);
const keys = ['host', 'port', 'username', 'privateKeyPath', 'projectPath', 'firstMenuChoice', 'secondMenuChoice', 'branch'];
let state;
let initialized = false;
let toastTimer;
let branchRefreshDone;
let dialogClosing = false;
installDisclosures();
const connection = $('#connectionDisclosure');
new MutationObserver(() => {
  const expanded = connection.dataset.expanded ?? String(connection.open);
  $('.connection-edit').textContent = expanded === 'true' ? '收起设置' : '展开修改';
}).observe(connection, { attributes: true, attributeFilter: ['open', 'data-expanded'] });
function settings() { return Object.fromEntries(keys.map(key => [key, $(`#${key}`).value.trim()])); }
function applyState(next, force = false) {
  if (!next) return;
  const previous = state?.settings;
  state = next;
  if (!state.busy) { branchRefreshDone?.(); branchRefreshDone = undefined; }
  for (const key of keys) {
    const input = $(`#${key}`);
    if (!initialized || force || (document.activeElement !== input && input.value === previous?.[key])) input.value = next.settings[key];
  }
  if (!initialized) $('#connectionDisclosure').open = next.connectionNeedsAttention;
  else if (next.connectionNeedsAttention) $('#connectionDisclosure').open = true;
  initialized = true;
  $('#connectionSummary').textContent = next.connectionNeedsAttention ? '请完善连接配置' : '连接已配置，保存在本机';
  $('#branchListMessage').textContent = next.branchListMessage;
  const status = next.operation?.state;
  $('#remoteStatus').textContent = next.busy ? '正在执行' : { success: '执行完成', failure: '操作失败', cancelled: '已停止' }[status] || '等待操作';
  for (const input of document.querySelectorAll('.remote-form input, #branch')) input.disabled = next.busy;
  for (const button of document.querySelectorAll('[data-action]')) {
    const action = button.dataset.action;
    button.disabled = button.dataset.refreshing === 'true' || (action === 'cancel' ? next.stopping || !next.busy : action === 'copyLog' ? !next.logs : next.busy);
  }
  $('#openBranches').disabled = next.localBusy;
  $('#deploy').disabled = next.busy || !$('#branch').value.trim();
  for (const id of ['cancel', 'dialogCancel']) $(`#${id}`).hidden = !next.busy || next.localBusy;
  $('[data-action=clearLog]').disabled = next.busy || !next.logs;
  renderProgress(); renderBranches(); renderLog();
  document.documentElement.dataset.ready = 'true';
}
function renderProgress() {
  const section = $('#progressSection');
  const wasHidden = section.hidden;
  section.hidden = !state.operation;
  if (!state.operation) return;
  if (wasHidden) entrance(section);
  const operation = state.operation;
  $('#operationCard').dataset.state = operation.state;
  $('#stage').textContent = operation.state === 'success' ? '完成' : operation.stage;
  $('#status').textContent = operation.message;
  $('#resultSummary').hidden = !operation.summary;
  $('#resultSummary').textContent = operation.summary || '';
  const steps = $('#stages'); steps.replaceChildren();
  for (const [index, stage] of operation.stages.entries()) {
    const item = document.createElement('li'); item.className = 'stage-step'; item.dataset.state = stage.state;
    for (const text of [String(index + 1), stage.title]) { const span = document.createElement('span'); span.textContent = text; item.append(span); }
    steps.append(item);
  }
}
function renderLog() {
  const log = $('#log');
  const bottom = log.scrollHeight - log.scrollTop - log.clientHeight < 28;
  const text = state.logs || '执行日志会显示在这里。';
  if (text !== log.textContent) { log.textContent = text; if (bottom) log.scrollTop = log.scrollHeight; }
  log.dataset.empty = String(!state.logs);
}
function renderBranches() {
  const query = $('#branchSearch').value.toLowerCase().trim();
  const branches = state.branches.filter(branch => branch.toLowerCase().includes(query)).sort((a, b) => Number(b.toLowerCase().startsWith(query)) - Number(a.toLowerCase().startsWith(query)) || a.localeCompare(b));
  $('#branchCount').textContent = `${branches.length} / ${state.branches.length} 个分支`;
  $('#branchStatus').textContent = state.busy ? state.operation?.message || '正在执行…' : branches.length > 200 ? '显示前 200 条，请输入关键词缩小范围' : '';
  const empty = $('#branchEmpty');
  empty.hidden = branches.length > 0 && !state.busy;
  empty.textContent = state.busy ? '正在加载，请稍候…' : state.operation?.state === 'failure' ? state.operation.message : state.branches.length ? '没有匹配的分支，试试其他关键词。' : '暂无分支列表，请点击下方“加载分支”。';
  const results = $('#branchResults'); results.replaceChildren(); results.hidden = state.busy;
  for (const branch of branches.slice(0, 200)) {
    const button = document.createElement('button'); button.type = 'button'; button.className = 'branch-option';
    button.textContent = branch; button.setAttribute('aria-current', String(branch === state.settings.branch));
    button.disabled = button.dataset.refreshing === 'true' || state.busy; button.addEventListener('click', () => { void action('selectBranch', { branch }); });
    results.append(button);
  }
}
function toast(message) {
  clearTimeout(toastTimer); $('#toast').textContent = message; showToast($('#toast'));
  toastTimer = setTimeout(() => dismiss($('#toast')), 4500);
}
async function action(name, extra = {}) {
  if (state?.busy && !['cancel', 'copyLog'].includes(name)) return;
  try {
    const result = await request(name, { settings: settings(), ...extra });
    if (result.snapshot) applyState(result.snapshot, ['choosePrivateKey', 'selectBranch'].includes(name));
    if (result.message) toast(result.message);
    if (name === 'selectBranch') closeBranches();
  } catch (error) { toast(error.message); }
}
function openBranches() {
  if (state?.localBusy) return;
  const dialog = $('#branchDialog'); if (dialog.open) return;
  renderBranches(); dialog.showModal(); entrance(dialog); $('#branchSearch').focus();
}
function closeBranches() {
  const dialog = $('#branchDialog');
  if (!dialog.open || dialogClosing) return;
  dialogClosing = true;
  const finish = () => { dialog.close(); dialogClosing = false; $('#openBranches').focus(); };
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) { finish(); return; }
  const animation = dialog.animate([{ opacity: 1, transform: 'translateY(0)' }, { opacity: 0, transform: 'translateY(5px)' }], { duration: 140, easing: 'ease-out' });
  animation.onfinish = finish;
}
for (const button of document.querySelectorAll('[data-action]')) button.addEventListener('click', () => {
  if (button.hasAttribute('data-refresh')) void refreshFeedback(button, async () => {
    await action(button.dataset.action);
    if (state.busy) await new Promise(resolve => { branchRefreshDone = resolve; });
  }, () => applyState(state));
  else void action(button.dataset.action);
});
for (const key of keys) {
  const input = $(`#${key}`); input.maxLength = key === 'port' ? 5 : ['firstMenuChoice', 'secondMenuChoice'].includes(key) ? 100 : 4000;
  input.addEventListener('input', () => { void action('saveSettings'); });
  input.addEventListener('change', () => { void action('saveSettings'); });
}
$('#branch').addEventListener('input', () => { $('#deploy').disabled = state?.busy || !$('#branch').value.trim(); });
$('#openBranches').addEventListener('click', openBranches);
$('#closeBranches').addEventListener('click', closeBranches);
$('#branchDialog').addEventListener('cancel', event => { event.preventDefault(); closeBranches(); });
$('#branchDialog').addEventListener('keydown', event => {
  if (event.key === 'Escape') { event.preventDefault(); closeBranches(); }
});
$('#branchDialog').addEventListener('click', event => {
  if (event.target !== $('#branchDialog')) return;
  const rect = event.target.getBoundingClientRect();
  if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) closeBranches();
});
$('#branchSearch').addEventListener('input', renderBranches);
$('#branchSearch').addEventListener('keydown', event => {
  if (!['Enter', 'ArrowDown'].includes(event.key) || state?.busy) return;
  event.preventDefault(); const first = $('#branchResults button');
  if (event.key === 'Enter') first?.click(); else first?.focus();
});
$('#branchResults').addEventListener('keydown', event => {
  if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return;
  event.preventDefault(); const buttons = [...$('#branchResults').children]; const index = buttons.indexOf(document.activeElement);
  const next = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : buttons.length - 1)) % buttons.length;
  buttons[next]?.focus();
});
subscribe((event, snapshot) => { if (event === 'state') applyState(snapshot); });
try { await connect(); const result = await request('state'); applyState(result.snapshot); }
catch (error) { $('#progressSection').hidden = false; $('#operationCard').dataset.state = 'failure'; $('#stage').textContent = '无法连接应用'; $('#status').textContent = error.message; }
