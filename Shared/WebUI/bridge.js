const pending = new Map();
const listeners = new Set();
const windows = window.chrome?.webview;
const mac = window.webkit?.messageHandlers.adswork;
const native = windows || mac;
let preview;
export async function connect() {
  if (!native) {
    if (!new URLSearchParams(location.search).has('preview')) throw new Error('请从桌面程序打开此页面。');
    preview = await import('./preview.js');
    document.querySelector('#previewBanner').hidden = false;
    preview.subscribe(notify);
    return;
  }
  const receive = message => {
    if (message?.type === 'event') { notify(message.event, message.data); return; }
    const entry = pending.get(message?.id);
    if (!entry) return;
    pending.delete(message.id);
    clearTimeout(entry.timer);
    message.ok ? entry.resolve(message.data) : entry.reject(new Error(message.error || '操作失败，请重试。'));
  };
  if (windows) windows.addEventListener('message', event => receive(event.data));
  else window.__adsWorkReceive = receive;
}
function notify(event, data) { for (const listener of listeners) listener(event, data); }
export function subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); }
export function request(action, args = {}) {
  if (preview) return preview.request(action, args);
  if (!native) return Promise.reject(new Error('本地功能尚未连接。'));
  const id = typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : uuid();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error('本地操作响应超时。请查看状态，不要重复安装；必要时停止后重试。'));
    }, ['buildSave', 'buildInstall', 'download', 'import', 'install', 'restore'].includes(action) ? 17 * 60 * 1000 : 30000);
    pending.set(id, { resolve, reject, timer });
    try { native.postMessage({ id, action, args }); }
    catch (error) { clearTimeout(timer); pending.delete(id); reject(error); }
  });
}

function uuid() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = [...bytes].map(value => value.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
