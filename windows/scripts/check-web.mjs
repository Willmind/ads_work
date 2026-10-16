import { createRequire } from 'node:module';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
const base = process.env.UI_PREVIEW_URL || 'http://127.0.0.1:18450';
const output = process.env.UI_CHECK_OUTPUT || path.resolve('web-check-output');
await mkdir(output, { recursive: true });
let checks = 0;
const failures = [];
function check(condition, message) { checks++; if (!condition) failures.push(message); }
try {
  for (const width of [1120, 760, 480]) {
    const page = await browser.newPage({ viewport: { width, height: 1000 }, deviceScaleFactor: 1 });
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    const remote = []; page.on('request', request => { if (!request.url().startsWith(base)) remote.push(request.url()); });
    await page.goto(`${base}/index.html?preview=1&seed=1`);
    await page.waitForSelector('html[data-ready=true]');
    check(await page.locator('#records tr').count() === 3, `初始历史 ${width}`);
    for (const source of ['build', 'download', 'file']) {
      await page.locator(`#tab-${source}`).click();
      check(await page.locator(`#panel-${source}`).isVisible(), `来源切换 ${width} ${source}`);
      const layout = await page.evaluate(() => {
        const errors = [];
        if (document.documentElement.scrollWidth > innerWidth + 1) errors.push('页面横向溢出');
        for (const button of document.querySelectorAll('button')) {
          if (!button.getClientRects().length) continue;
          const rect = button.getBoundingClientRect();
          if (button.scrollWidth > button.clientWidth + 2 || button.scrollHeight > button.clientHeight + 2) errors.push(`按钮文字溢出 ${button.textContent}`);
          if (rect.right > innerWidth + 1 || rect.left < -1) errors.push(`按钮越出窗口 ${button.textContent}`);
          if (rect.height < 25) errors.push(`按钮高度不足 ${button.textContent}`);
        }
        return errors;
      });
      check(layout.length === 0, `${width} ${source}: ${layout.join(', ')}`);
      await page.screenshot({ path: path.join(output, `${width}-${source}.png`), fullPage: true });
    }
    await page.locator('#search').fill('不存在的版本');
    check(await page.locator('#emptyTitle').textContent() === '没有匹配的记录', `搜索空结果 ${width}`);
    check(await page.locator('#selection').isHidden(), `空结果隐藏编辑操作 ${width}`);
    await page.locator('#search').fill('窗口 同步');
    check(await page.locator('#records tr').count() === 1, `组合搜索 ${width}`);
    await page.locator('#editNote').fill('<img src=x onerror=alert(1)>');
    await page.locator('[data-action=updateMetadata]').click();
    await page.locator('#search').fill('');
    await page.waitForTimeout(50);
    check(await page.locator('#records img').count() === 0, `备注以纯文字呈现 ${width}`);
    check((await page.locator('#records').textContent()).includes('<img src=x'), `备注保存 ${width}`);
    await page.locator('#tab-build').click();
    await page.locator('#addPrimary').click();
    await page.waitForFunction(() => !document.querySelector('#operationCard').hidden);
    check(await page.locator('#addPrimary').isDisabled(), `忙碌禁止重复操作 ${width}`);
    check(await page.locator('#cancel').isVisible(), `提供停止入口 ${width}`);
    await page.locator('#cancel').click();
    await page.waitForFunction(() => document.querySelector('#stage').textContent === '已停止');
    check(await page.locator('#addPrimary').isEnabled(), `取消后恢复操作 ${width}`);
    check(errors.length === 0, `无脚本错误 ${width}: ${errors}`);
    check(remote.length === 0, `无外部页面请求 ${width}: ${remote}`);
    await page.close();
  }
  const empty = await browser.newPage({ viewport: { width: 1120, height: 950 } });
  await empty.goto(`${base}/index.html?preview=1&seed=0`);
  await empty.waitForSelector('html[data-ready=true]');
  check(await empty.locator('#emptyState').isVisible(), '首次空历史提示');
  check(await empty.locator('#selection').isHidden(), '无历史时不显示安装按钮');
  await empty.screenshot({ path: path.join(output, '1120-empty.png'), fullPage: true });
  await empty.close();
} finally { await browser.close(); }
await writeFile(path.join(output, 'report.json'), JSON.stringify({ checks, failures, scope: 'Chrome HTML/CSS 渲染、交互与响应式布局；不替代 Windows WebView2 实机验证' }, null, 2));
if (failures.length) { console.error(failures.join('\n')); process.exitCode = 1; }
else console.log(`浏览器界面自检全部通过：${checks} 项断言。截图：${output}`);
