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
    const emit = () => listeners.forEach(listener => listener({ data: { type: 'event', event: 'state', data: structuredClone(state) } }));
    window.copyMock = { requests: [], readDelay: 0, copyDelay: 900, error: '', files: [{ name: 'chunks/中文 file.js', size: 10000, modifiedAt: new Date().toISOString() }] };
    window.chrome.webview = { addEventListener: (_, listener) => listeners.push(listener), postMessage: async request => {
      const mock = window.copyMock; mock.requests.push(request);
      const reply = (data, ok = true) => listeners.forEach(listener => listener({ data: { id: request.id, ok, ...(ok ? { data } : { error: data }) } }));
      if (request.action === 'buildFiles') {
        await new Promise(resolve => setTimeout(resolve, mock.readDelay));
        reply({ buildDirectory: { path: request.args.projectPath + '\\build', exists: true, entryCount: mock.files.length, files: structuredClone(mock.files) } }); return;
      }
      if (request.action === 'copyBuildFile') {
        state.busy = true; emit();
        await new Promise(resolve => setTimeout(resolve, mock.copyDelay));
        state.busy = false; emit();
        reply(mock.error || { copiedFile: request.args.fileName, message: 'JS 文件已复制，可直接粘贴到文件夹' }, !mock.error); return;
      }
      reply({ snapshot: structuredClone(state) });
    } };
    window.emitCopyState = emit;
  });
  await page.goto(`${process.env.UI_PREVIEW_URL || 'http://127.0.0.1:18450'}/index.html`);
  await page.waitForSelector('#buildFiles tr');
  check(await page.locator('[data-copy-file]').count() === 1, '每条 JS 有复制文件按钮');
  check(await page.locator('[data-copy-file] use').evaluate(use => use.getBBox().width > 0), 'Lucide 复制图标实际绘制');
  await page.waitForTimeout(1100);
  check(await page.locator('#refreshBuild').evaluate(button => !button.dataset.refreshing && button.querySelector('svg').getAnimations().length === 0), '自动轮询不旋转图标');
  await page.evaluate(() => { window.copyMock.readDelay = 650; });
  const started = Date.now(); await page.locator('#refreshBuild').click();
  check(await page.locator('#refreshBuild').evaluate(button => button.dataset.refreshing === 'true' && button.querySelector('svg').getAnimations().some(a => a.playState === 'running')), '手动刷新立即旋转');
  check(await page.locator('#refreshBuild').isDisabled(), '刷新期间阻止重复点击');
  await page.evaluate(() => window.emitCopyState());
  check(await page.locator('#refreshBuild').isDisabled(), '无关状态更新不提前启用刷新按钮');
  await page.waitForFunction(() => !document.querySelector('#refreshBuild').dataset.refreshing);
  check(Date.now() - started >= 480 && await page.locator('#refreshBuild').isEnabled(), '请求完成且至少一圈后恢复按钮');
  await page.evaluate(() => { window.copyMock.readDelay = 0; });
  await page.locator('[data-refresh]').click();
  check(await page.locator('[data-refresh]').evaluate(button => button.querySelector('svg').getAnimations().some(a => a.playState === 'running')), '历史刷新共用旋转反馈');
  await page.waitForFunction(() => !document.querySelector('[data-refresh]').dataset.refreshing);
  const danger = page.locator('#clearBuild');
  await page.mouse.move(0, 0);
  const normal = await danger.evaluate(button => { const s = getComputedStyle(button); return { color: s.color, border: s.borderTopColor, background: s.backgroundColor }; });
  check(normal.color === normal.border && normal.background === 'rgb(255, 255, 255)', '危险按钮红色文字边框、白底');
  await danger.hover(); await page.waitForTimeout(180);
  const hover = await danger.evaluate(button => { const s = getComputedStyle(button); return { color: s.color, border: s.borderTopColor, background: s.backgroundColor }; });
  check(hover.border === normal.border && hover.background === 'rgb(255, 241, 239)', '悬停保持红框与浅红背景');
  await page.mouse.down(); await page.waitForTimeout(180);
  const pressed = await danger.evaluate(button => { const s = getComputedStyle(button); return { color: s.color, border: s.borderTopColor, background: s.backgroundColor }; });
  check(pressed.color === 'rgb(255, 255, 255)' && pressed.border === pressed.background && pressed.background === 'rgb(184, 46, 36)', '按下红底白字与同色边框');
  await page.mouse.move(0, 0); await page.mouse.up();
  const copy = page.locator('[data-copy-file]'); const width = await copy.evaluate(button => button.getBoundingClientRect().width);
  await copy.click();
  check(await copy.isDisabled() && (await copy.textContent()).includes('复制中'), '复制期间显示状态并禁用重复操作');
  check(await danger.isDisabled() && await page.locator('#addPrimary').isDisabled(), '复制期间禁止清空与打包');
  await page.evaluate(() => window.copyMock.files.push({ name: 'other.js', size: 1, modifiedAt: new Date().toISOString() }));
  await page.locator('#refreshBuild').click();
  await page.waitForFunction(() => document.querySelectorAll('#buildFiles tr').length === 2);
  await page.waitForFunction(() => [...document.querySelectorAll('[data-copy-file]')].some(button => button.textContent.includes('已复制')));
  const copied = page.locator('[data-copy-file]').first();
  check((await copied.textContent()).includes('已复制') && await copied.isEnabled(), '刷新列表后仍保留复制成功反馈');
  check(await copied.evaluate(button => button.getBoundingClientRect().width) === width, '复制前后宽度一致');
  const request = await page.evaluate(() => window.copyMock.requests.find(request => request.action === 'copyBuildFile'));
  check(request.args.fileName === 'chunks/中文 file.js' && request.args.projectPath === 'C:\\install\\mix_client' && !request.args.settings, '文件复制使用项目与相对文件名，不保存配置');
  await page.evaluate(() => { window.copyMock.error = '文件已经被删除，请刷新后重试'; window.copyMock.copyDelay = 50; });
  await copied.click();
  await page.waitForFunction(() => document.querySelector('#toast').textContent.includes('文件已经被删除'));
  check(!(await copied.textContent()).includes('已复制'), '复制失败不会显示成功');
  await page.setViewportSize({ width: 480, height: 900 });
  check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), '新增操作列在窄窗口不溢出');
  check(await page.locator('[data-copy-file]').first().evaluate(button => { const r = button.getBoundingClientRect(); return r.x >= 0 && r.right <= innerWidth; }), '窄窗口复制按钮可见且对齐');
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.locator('#refreshBuild').click();
  check(await page.locator('#refreshBuild svg').evaluate(icon => !icon.getAnimations().some(a => a.playState === 'running')), '减少动态效果时不旋转');
  check(!errors.length, `页面无脚本错误 ${errors}`);
  await mkdir(output, { recursive: true });
  await page.screenshot({ path: path.join(output, 'copy-refresh-480.png'), fullPage: true });
} finally { await browser.close(); }
await mkdir(output, { recursive: true });
await writeFile(path.join(output, 'copy-refresh-report.json'), JSON.stringify({ checks, failures, scope: 'Chrome 中验证刷新动画、危险按钮状态、逐行复制交互与窄窗口；剪贴板消息模拟，原生文件/剪贴板另测。' }, null, 2));
if (failures.length) { console.error(failures.join('\n')); process.exitCode = 1; }
else console.log(`复制与刷新检查通过：${checks} 项断言。`);
