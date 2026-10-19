const listeners = new Set();
const seeded = new URLSearchParams(location.search).get('seed') !== '0';
const now = new Date().toISOString();
let buildFiles = seeded ? [
  { name: 'v2.8.9.4_main.min.js', size: 8804293, modifiedAt: now },
  { name: 'chunks/vendor.js', size: 524288, modifiedAt: now }
] : [];
let state = {
  settings: { projectPath: 'C:\\install\\mix_client', libraryPath: 'C:\\Users\\StandardSoftware\\AppData\\Roaming\\adspower_global\\cwd_global\\lib' },
  records: seeded ? [
    { id: '68cafddd-a92d-4306-a5eb-15b67c732dc3', version: 'v2.8.9.4', note: '窗口同步 · 修复与验证', branch: 'fix/window-sync', sourceLabel: '本地打包' },
    { id: 'c3e90cba-a021-4418-b302-c4755b3bd593', version: 'v2.8.9.3', note: '稳定版本 · 回归测试', branch: null, sourceLabel: '链接下载' },
    { id: 'a548a669-9b20-487d-a4e7-e2df4bc2e111', version: 'v2.8.9.2', note: '修复配置导入问题', branch: 'fix/profile-import', sourceLabel: '本地打包' }
  ].map(record => ({ ...record, fileName: `${record.version}_main.min.js`, createdAt: now, md5: '59fa3b6b43200c3719dcfd361ee6562e', sha256: 'e4bb1c0d6838b0608d45bf7efb40dda8de2e76a15352a7a5a4b41ab93efe3fd5', size: 8804293 })) : [], backups: [], busy: false, logs: '', operation: null
};
export function subscribe(listener) { listeners.add(listener); }
function emit() { for (const listener of listeners) listener('state', structuredClone(state)); }
export async function request(action, args = {}) {
  if (action === 'buildFiles') return { buildDirectory: { path: `${args.projectPath}${args.projectPath.includes('\\') ? '\\' : '/'}build`, exists: true, entryCount: buildFiles.length, files: structuredClone(buildFiles) } };
  if (args.settings) state.settings = { ...args.settings };
  if (action === 'clearBuild') {
    if (!window.confirm('预览：确认清空演示 build 列表？不会删除本机文件。')) return { snapshot: structuredClone(state), message: '已取消清空' };
    buildFiles = [];
    return { snapshot: structuredClone(state), message: '预览：build 列表已清空，本机文件未改动。' };
  }
  if (action === 'state' || action === 'saveSettings') return { snapshot: structuredClone(state), message: action === 'saveSettings' ? '预览：路径已更新' : '' };
  if (action === 'cancel') { state.busy = false; state.operation = { state: 'cancelled', stage: '已停止', message: '预览：操作已停止。' }; emit(); return {}; }
  if (action === 'updateMetadata') {
    state.records = state.records.map(record => record.id === args.id ? { ...record, version: args.version, note: args.note } : record);
    return { snapshot: structuredClone(state), message: '预览：备注已保存' };
  }
  if (['chooseProject', 'chooseLibrary', 'openArchive', 'copyLog'].includes(action)) return { message: '界面预览不会打开本机文件或复制剪贴板。' };
  state.busy = true; state.operation = { state: 'running', stage: '演示处理中', message: '界面预览，不执行真实本地操作。' }; emit();
  await new Promise(resolve => setTimeout(resolve, 800));
  if (!state.busy) return {};
  state.busy = false; state.operation = { state: 'success', stage: '演示完成', message: '实际文件和后台数据均未改动。' };
  state.logs = '这是界面预览日志。没有执行 npm、下载或文件替换。'; emit();
  return { snapshot: structuredClone(state), message: '演示完成' };
}
