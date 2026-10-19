import { request } from './bridge.js';
import { refreshFeedback } from './motion.js';

export function createBuildDirectory({ getProjectPath, isBusy, formatDate, notify }) {
  const $ = selector => document.querySelector(selector);
  let running = false;
  let readPromise;
  let timer;
  let copiedTimer;
  let directory;
  let loadedProject;
  let signature;
  let copying;
  let copied;
  const fileKey = name => `${getProjectPath().trim()}\0${name}`;

  function setBusy() {
    $('#refreshBuild').disabled = $('#refreshBuild').dataset.refreshing === 'true';
    const unavailable = !!isBusy() || !!copying || loadedProject !== getProjectPath().trim();
    $('#clearBuild').disabled = unavailable || !directory?.entryCount;
    for (const button of document.querySelectorAll('[data-copy-file]')) {
      const key = fileKey(button.dataset.copyFile);
      button.disabled = unavailable;
      button.querySelector('span').textContent = copying === key ? '复制中' : copied === key ? '已复制' : '复制';
      button.setAttribute('aria-label', `复制文件 ${button.dataset.copyFile}`);
    }
  }

  function copyButton(name) {
    const button = document.createElement('button'); button.type = 'button'; button.className = 'build-copy'; button.dataset.copyFile = name;
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.classList.add('icon'); svg.setAttribute('aria-hidden', 'true'); svg.setAttribute('viewBox', '0 0 24 24');
    const use = document.createElementNS(svg.namespaceURI, 'use'); use.setAttribute('href', 'icons.svg#copy'); svg.append(use);
    const text = document.createElement('span'); text.textContent = '复制'; button.append(svg, text);
    button.addEventListener('click', () => { void copyFile(name); });
    return button;
  }

  async function copyFile(name) {
    if (isBusy() || copying || loadedProject !== getProjectPath().trim()) return;
    const projectPath = getProjectPath().trim(); const key = fileKey(name);
    copying = key; copied = undefined; clearTimeout(copiedTimer); setBusy();
    try {
      const result = await request('copyBuildFile', { projectPath, fileName: name });
      copied = key; clearTimeout(copiedTimer);
      copiedTimer = setTimeout(() => { copied = undefined; setBusy(); }, 2000);
      notify(result.message || 'JS 文件已复制，可粘贴到文件夹');
    } catch (error) { notify(error.message); void refresh(); }
    finally { copying = undefined; setBusy(); }
  }

  function render(value, error = '') {
    directory = value;
    const next = JSON.stringify([value, error]);
    if (signature !== next) {
      signature = next;
      const files = value?.files || [];
      $('#buildFileCount').textContent = error ? '读取失败' : `${files.length} 个 JS`;
      $('#buildDirectoryPath').textContent = value?.path || '所选项目 / build';
      $('#buildDirectoryPath').title = value?.path || '';
      $('#buildDirectoryMessage').textContent = error || (value?.exists === false ? 'build 目录尚未生成，打包后会自动显示。' : '自动读取当前目录；清空会删除所有文件和子目录，保留 build 目录本身。');
      $('#buildDirectoryMessage').classList.toggle('field-error', !!error);
      $('#buildFilesTable').hidden = files.length === 0;
      $('#buildFilesEmpty').hidden = files.length !== 0;
      $('#buildFilesEmpty').textContent = error ? '请检查本地项目路径及目录权限。' : 'build 中暂无 JS 文件';
      const body = $('#buildFiles'); body.replaceChildren();
      for (const file of files) {
        const row = document.createElement('tr');
        const size = file.size < 1024 ? `${file.size} B` : file.size < 1048576 ? `${(file.size / 1024).toFixed(1)} KB` : `${(file.size / 1048576).toFixed(2)} MB`;
        for (const text of [file.name, size, formatDate(file.modifiedAt)]) {
          const cell = document.createElement('td'); cell.textContent = text; cell.title = text; row.append(cell);
        }
        const actions = document.createElement('td'); actions.append(copyButton(file.name)); row.append(actions);
        body.append(row);
      }
    }
    setBusy();
  }

  function refresh() {
    if (!running) return Promise.resolve();
    if (readPromise) return readPromise;
    clearTimeout(timer);
    const projectPath = getProjectPath().trim();
    readPromise = (async () => {
      try {
        const result = await request('buildFiles', { projectPath });
        if (projectPath === getProjectPath().trim()) { loadedProject = projectPath; render(result.buildDirectory); }
      } catch (error) {
        if (projectPath === getProjectPath().trim()) { loadedProject = projectPath; render(undefined, error.message); }
      } finally {
        readPromise = undefined;
        if (running) timer = setTimeout(refresh, projectPath !== getProjectPath().trim() ? 0 : document.hidden ? 5000 : 1000);
      }
    })();
    return readPromise;
  }

  $('#refreshBuild').addEventListener('click', () => { void refreshFeedback($('#refreshBuild'), refresh, setBusy); });
  $('#projectPath').addEventListener('input', () => {
    copied = undefined; render(undefined);
    clearTimeout(timer); timer = setTimeout(refresh, 300);
  });
  document.addEventListener('visibilitychange', () => { if (!document.hidden) void refresh(); });
  window.addEventListener('pagehide', () => { running = false; clearTimeout(timer); clearTimeout(copiedTimer); });
  return { start() { running = true; void refresh(); }, refresh, setBusy };
}
