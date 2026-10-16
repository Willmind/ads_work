import { createRequire } from 'node:module';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
const output = process.env.UI_CHECK_OUTPUT || path.resolve('web-check-output');
let checks = 0;
const failures = [];
function check(value, message) { checks++; if (!value) failures.push(message); }
try {
  const page = await browser.newPage({ viewport: { width: 1100, height: 1000 } });
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript(() => {
    const listeners = [];
    const snapshot = { settings: { projectPath: 'C:\\install\\mix_client', libraryPath: 'C:\\AdsPower\\lib' }, records: [{ id: '68cafddd-a92d-4306-a5eb-15b67c732dc3', version: 'v2.8.9.4', note: '动画验证', branch: 'test/motion', fileName: 'main.min.js', sourceLabel: '本地打包', createdAt: new Date().toISOString(), size: 42, md5: 'a'.repeat(32), sha256: 'a'.repeat(64) }], backups: [1, 2, 3].map(n => ({ id: `backup-${n}`, label: `测试备份 ${n}`, createdAt: new Date().toISOString() })), busy: false, logs: '动画检查日志', operation: null };
    window.chrome.webview = { addEventListener: (_, fn) => listeners.push(fn), postMessage: request => queueMicrotask(() => listeners.forEach(fn => fn({ data: { id: request.id, ok: true, data: { snapshot } } }))) };
  });
  await page.goto(`${process.env.UI_PREVIEW_URL || 'http://127.0.0.1:18450'}/index.html`);
  await page.waitForSelector('html[data-ready=true]');
  check(await page.evaluate(() => { document.querySelector('#tab-download').click(); return document.querySelector('.add-card').getAnimations().some(a => a.playState === 'running'); }), '来源切换平滑调整高度');
  check(await page.evaluate(() => document.querySelector('#panel-download').getAnimations().some(a => a.playState === 'running')), '来源内容淡入');
  for (const selector of ['.file-details', '#backupDisclosure', '#logDisclosure']) {
    check(await page.evaluate(selector => { const d = document.querySelector(selector); d.querySelector('summary').click(); return d.open && d.getAnimations().some(a => a.playState === 'running'); }, selector), `展开动画 ${selector}`);
    await page.waitForTimeout(260);
    check(await page.evaluate(selector => { const d = document.querySelector(selector); d.querySelector('summary').click(); return d.open && d.dataset.expanded === 'false' && d.getAnimations().some(a => a.playState === 'running'); }, selector), `关闭期间保留内容以完成动画 ${selector}`);
    await page.waitForFunction(selector => !document.querySelector(selector).open, selector);
    check(await page.evaluate(selector => { const s = document.querySelector(selector).querySelector('summary'); s.click(); s.click(); s.click(); return true; }, selector), `快速反复切换 ${selector}`);
    await page.waitForTimeout(260);
    check(await page.locator(selector).evaluate(d => d.open && d.dataset.expanded === 'true' && !d.getAnimations().some(a => a.playState === 'running')), `动画结束状态一致 ${selector}`);
  }
  await page.locator('#backupPicker').scrollIntoViewIfNeeded();
  check(await page.evaluate(() => { document.querySelector('#backupPicker').click(); return document.querySelector('#backupMenu').getAnimations().some(a => a.playState === 'running'); }), '下拉菜单淡入');
  await page.waitForTimeout(200);
  check(await page.locator('#backupMenu [role=option]').count() === 3, '下拉备份完整显示');
  await page.keyboard.press('End'); await page.keyboard.press('Enter');
  await page.waitForFunction(() => document.querySelector('#backupMenu').hidden);
  check(await page.locator('#backups').inputValue() === 'backup-3', '键盘选择同步真实备份 ID');
  check((await page.locator('#backupPicker').textContent()).includes('测试备份 3'), '下拉按钮显示所选备份');
  await page.locator('#backupPicker').press('ArrowDown');
  await page.keyboard.press('Escape');
  check(await page.locator('#backupPicker').getAttribute('aria-expanded') === 'false', 'Escape 收起菜单');
  await page.waitForFunction(() => document.querySelector('#backupMenu').hidden);
  check(await page.locator('#backupPicker').evaluate(e => e === document.activeElement), '收起后焦点回到按钮');
  await page.locator('#backupPicker').click(); await page.locator('#historyTitle').click();
  await page.waitForFunction(() => document.querySelector('#backupMenu').hidden);
  check(true, '点击菜单外部收起');
  await page.setViewportSize({ width: 480, height: 700 });
  await page.locator('#backupPicker').click();
  check(await page.locator('#backupMenu').evaluate(e => { const r = e.getBoundingClientRect(); return r.x >= 0 && r.right <= innerWidth && r.y >= 0 && r.bottom <= innerHeight; }), '窄窗口菜单留在视口内');
  await page.keyboard.press('Escape');
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.waitForTimeout(200);
  check(await page.evaluate(() => { const d = document.querySelector('.file-details'); d.querySelector('summary').click(); return !d.open && !d.getAnimations().some(a => a.playState === 'running'); }), '遵循系统减少动态效果设置');
  check(errors.length === 0, `无脚本错误 ${errors}`);
  await mkdir(output, { recursive: true });
  await writeFile(path.join(output, 'motion-report.json'), JSON.stringify({ checks, failures, scope: '真实浏览器动画、快速切换、键盘下拉、窄窗口与减少动态效果；本地通道使用模拟数据' }, null, 2));
} finally { await browser.close(); }
if (failures.length) { console.error(failures.join('\n')); process.exitCode = 1; }
else console.log(`过渡动画与下拉检查通过：${checks} 项断言。`);
