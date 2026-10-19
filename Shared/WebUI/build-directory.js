import { request } from './bridge.js';

export function createBuildDirectory({ getProjectPath, isBusy, formatDate }) {
  const $ = selector => document.querySelector(selector);
  let running = false;
  let inFlight = false;
  let timer;
  let directory;
  let loadedProject;
  let signature;

  function setBusy() {
    $('#refreshBuild').disabled = false;
    $('#clearBuild').disabled = !!isBusy() || !directory?.entryCount || loadedProject !== getProjectPath().trim();
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
        body.append(row);
      }
    }
    setBusy();
  }

  async function refresh() {
    if (!running || inFlight) return;
    clearTimeout(timer);
    inFlight = true;
    const projectPath = getProjectPath().trim();
    try {
      const result = await request('buildFiles', { projectPath });
      if (projectPath === getProjectPath().trim()) { loadedProject = projectPath; render(result.buildDirectory); }
    } catch (error) {
      if (projectPath === getProjectPath().trim()) { loadedProject = projectPath; render(undefined, error.message); }
    } finally {
      inFlight = false;
      if (running) timer = setTimeout(refresh, projectPath !== getProjectPath().trim() ? 0 : document.hidden ? 5000 : 1000);
    }
  }

  $('#refreshBuild').addEventListener('click', () => { void refresh(); });
  $('#projectPath').addEventListener('input', () => {
    render(undefined);
    clearTimeout(timer); timer = setTimeout(refresh, 300);
  });
  document.addEventListener('visibilitychange', () => { if (!document.hidden) void refresh(); });
  window.addEventListener('pagehide', () => { running = false; clearTimeout(timer); });
  return { start() { running = true; void refresh(); }, refresh, setBusy };
}
