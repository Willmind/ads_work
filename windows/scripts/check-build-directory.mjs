import { createRequire } from 'node:module';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
const output = process.env.UI_CHECK_OUTPUT || path.resolve('web-check-output');
let checks = 0; const failures = [];
function check(value, label) { checks++; if (!value) failures.push(label); }
try {
  const page = await browser.newPage({ viewport: { width: 1120, height: 1000 } });
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript(() => {
    const listeners = [];
    const state = { settings: { projectPath: 'C:\\install\\mix_client', libraryPath: 'C:\\AdsPower\\lib' }, records: [], backups: [], busy: false, logs: '', operation: null };
    window.directoryMock = { requests: [], files: [{ name: 'main.js', size: 42, modifiedAt: new Date().toISOString() }], approve: false, error: '', delay: 0 };
    window.chrome.webview = { addEventListener: (_, listener) => listeners.push(listener), postMessage: async request => {
      const mock = window.directoryMock; mock.requests.push(request);
      const reply = (data, ok = true) => listeners.forEach(listener => listener({ data: { id: request.id, ok, ...(ok ? { data } : { error: data }) } }));
      if (request.action === 'buildFiles') {
        await new Promise(resolve => setTimeout(resolve, mock.delay));
        if (mock.error) { reply(mock.error, false); return; }
        reply({ buildDirectory: { path: request.args.projectPath + '\\build', exists: true, entryCount: mock.files.length, files: structuredClone(mock.files) } }); return;
      }
      if (request.action === 'clearBuild') { if (mock.approve) mock.files = []; reply({ snapshot: structuredClone(state), message: mock.approve ? 'build 已清空' : '已取消清空' }); return; }
      reply({ snapshot: structuredClone(state) });
    } };
    window.setDirectoryBusy = busy => { state.busy = busy; listeners.forEach(listener => listener({ data: { type: 'event', event: 'state', data: structuredClone(state) } })); };
  });
  await page.goto(`${process.env.UI_PREVIEW_URL || 'http://127.0.0.1:18450'}/index.html`);
  await page.waitForSelector('#buildFiles tr');
  check(await page.locator('#buildFiles tr').count() === 1, '初始真实目录列表入口');
  await page.evaluate(() => window.directoryMock.files.push({ name: 'chunks/<img src=x onerror=alert(1)>.js', size: 2048, modifiedAt: new Date().toISOString() }));
  await page.waitForFunction(() => document.querySelectorAll('#buildFiles tr').length === 2);
  check(await page.locator('#buildFiles img').count() === 0 && (await page.locator('#buildFiles').textContent()).includes('<img'), '文件名按纯文字呈现');
  check((await page.locator('#buildFiles').textContent()).includes('2.0 KB'), '显示大小和修改时间');
  await page.evaluate(() => window.directoryMock.files.shift());
  await page.waitForFunction(() => document.querySelectorAll('#buildFiles tr').length === 1);
  check(true, '外部删除自动刷新');
  check(await page.evaluate(() => window.directoryMock.requests.filter(r => r.action === 'saveSettings').length === 0), '自动读取不保存配置或触发构建');
  await page.locator('#projectPath').fill('C:\\other\\mix_client');
  await page.waitForFunction(() => document.querySelector('#buildDirectoryPath').textContent.startsWith('C:\\other'));
  check(await page.evaluate(() => window.directoryMock.requests.filter(r => r.action === 'buildFiles').at(-1).args.projectPath === 'C:\\other\\mix_client'), '项目输入变化更新读取目标');
  await page.evaluate(() => window.setDirectoryBusy(true));
  check(await page.locator('#clearBuild').isDisabled() && await page.locator('#refreshBuild').isEnabled(), '打包忙碌禁止清空，允许只读刷新');
  await page.evaluate(() => window.setDirectoryBusy(false));
  await page.locator('#clearBuild').click();
  check(await page.locator('#buildFiles tr').count() === 1, '取消确认保留目录列表');
  await page.evaluate(() => { window.directoryMock.error = '目录无读取权限'; });
  await page.locator('#refreshBuild').click();
  await page.waitForFunction(() => document.querySelector('#buildDirectoryMessage').textContent.includes('无读取权限'));
  check(await page.locator('#clearBuild').isDisabled(), '读取错误禁用清空并显示原因');
  await page.evaluate(() => { window.directoryMock.error = ''; });
  await page.locator('#refreshBuild').click();
  await page.waitForFunction(() => !document.querySelector('#clearBuild').disabled);
  await page.setViewportSize({ width: 480, height: 900 });
  await page.waitForTimeout(100);
  check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), '长文件名窄窗口不溢出');
  await page.evaluate(() => { window.directoryMock.approve = true; });
  await page.locator('#clearBuild').click();
  await page.waitForFunction(() => document.querySelectorAll('#buildFiles tr').length === 0);
  check(await page.locator('#buildFilesEmpty').isVisible() && await page.locator('#clearBuild').isDisabled(), '确认清空后自动更新为空目录');
  check(errors.length === 0, `无页面脚本错误 ${errors}`);
} finally { await browser.close(); }
await mkdir(output, { recursive: true });
await writeFile(path.join(output, 'build-directory-report.json'), JSON.stringify({ checks, failures, scope: '真实浏览器中的自动刷新、项目变化、忙碌互斥、清空响应、错误、文件名安全及窄窗口；消息通道使用模拟数据，原生文件操作由独立测试覆盖。' }, null, 2));
if (failures.length) { console.error(failures.join('\n')); process.exitCode = 1; }
else console.log(`build 目录界面检查通过：${checks} 项断言。`);
