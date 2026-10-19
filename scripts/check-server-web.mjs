import { createRequire } from 'node:module';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const output = process.env.UI_CHECK_OUTPUT || path.join(root, '.build/server-browser-report');
const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
let checks = 0;
const failures = [];
function check(value, message) { checks++; if (!value) failures.push(message); }
try {
  await mkdir(output, { recursive: true });
  for (const width of [1120, 760, 480]) {
    const page = await browser.newPage({ viewport: { width, height: 1000 } });
    const errors = []; page.on('pageerror', error => errors.push(error.message));
    const requests = []; page.on('request', request => requests.push(request.url()));
    await page.addInitScript(() => {
      const listeners = [];
      const state = { settings: { host: 'jump.example.invalid', port: '22', username: 'tester@example.invalid', privateKeyPath: '/example/keys/test.pem', projectPath: '/path/to/project', firstMenuChoice: '1', secondMenuChoice: '1', branch: 'main' }, branches: ['main', 'feature/login', 'release/2.8', 'feature/<img src=x onerror=alert(1)>'], branchListMessage: '服务器已有记录 · 4 个分支', connectionNeedsAttention: false, busy: false, localBusy: false, stopping: false, logs: '', operation: null };
      const emit = () => listeners.forEach(fn => fn({ data: { type: 'event', event: 'state', data: structuredClone(state) } }));
      window.serverRequests = [];
      window.chrome.webview = { addEventListener: (_, fn) => listeners.push(fn), postMessage: request => {
        window.serverRequests.push(request);
        if (request.args.settings) state.settings = request.args.settings;
        if (request.action === 'choosePrivateKey') state.settings.privateKeyPath = '/example/keys/selected.pem';
        if (request.action === 'selectBranch') state.settings.branch = request.args.branch;
        if (request.action === 'clearLog') { state.logs = ''; state.operation = null; }
        if (request.action === 'cancel') { state.busy = false; state.operation.state = 'cancelled'; state.operation.message = '模拟操作已停止'; }
        if (['test', 'branches', 'syncBranches'].includes(request.action)) {
          state.busy = true; state.operation = { state: 'running', stage: '连接服务器', message: '离线模拟处理中', summary: '', stages: [{ title: '连接服务器', state: 'running' }, { title: '完成', state: 'pending' }] };
          setTimeout(() => {
            if (!state.busy) return;
            state.busy = false; state.logs = '[16:00:00] 离线模拟检查完成'; state.operation.state = 'success'; state.operation.message = '检查完成';
            state.operation.stages.forEach(stage => { stage.state = 'done'; }); emit();
          }, 1500);
        }
        queueMicrotask(() => listeners.forEach(fn => fn({ data: { id: request.id, ok: true, data: { snapshot: structuredClone(state) } } })));
      } };
    });
    await page.route('http://adswork-server.test/**', async route => {
      const name = path.basename(new URL(route.request().url()).pathname);
      const folder = name.startsWith('server.') ? 'Resources/ServerUI' : 'Shared/WebUI';
      const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml' };
      await route.fulfill({ contentType: types[path.extname(name)], body: await readFile(path.join(root, folder, name)) });
    });
    await page.goto('http://adswork-server.test/server.html');
    await page.waitForSelector('html[data-ready=true]');
    check(await page.locator('#connectionDisclosure').evaluate(e => !e.open), `配置默认折叠 ${width}`);
    await page.locator('#connectionDisclosure > summary').click(); await page.waitForTimeout(250);
    check(await page.locator('#host').isVisible(), `配置展开 ${width}`);
    check(await page.locator('svg.icon:visible use').evaluateAll(icons => icons.length > 0 && icons.every(icon => icon.getBBox().width > 0 && icon.getBBox().height > 0)), `服务器功能图标实际渲染 ${width}`);
    const layout = await page.evaluate(() => {
      const errors = [];
      if (document.documentElement.scrollWidth > innerWidth + 1) errors.push('页面横向溢出');
      for (const button of document.querySelectorAll('button')) {
        if (!button.getClientRects().length) continue;
        const rect = button.getBoundingClientRect();
        if (rect.x < 0 || rect.right > innerWidth + 1) errors.push('按钮越出窗口');
        if (button.scrollWidth > button.clientWidth + 2) errors.push('按钮文字溢出');
      }
      return errors;
    });
    check(!layout.length, `表单及按钮布局 ${width}: ${layout}`);
    await page.screenshot({ path: path.join(output, `server-${width}.png`), fullPage: true });
    const refresh = page.locator('[data-refresh]');
    await refresh.click();
    check(await refresh.evaluate(button => button.dataset.refreshing === 'true' && button.querySelector('svg').getAnimations().some(animation => animation.playState === 'running')), `服务器刷新立即旋转 ${width}`);
    await page.waitForTimeout(600);
    check(await refresh.evaluate(button => button.dataset.refreshing === 'true' && button.disabled), `服务器刷新等待实际操作完成 ${width}`);
    await page.waitForFunction(() => !document.querySelector('[data-refresh]').dataset.refreshing);
    check(await refresh.isEnabled(), `服务器刷新结束后恢复 ${width}`);
    await page.locator('#host').fill('updated.example.invalid'); await page.locator('#port').focus();
    await page.waitForTimeout(30);
    check(await page.evaluate(() => window.serverRequests.some(r => r.action === 'saveSettings' && r.args.settings.host === 'updated.example.invalid')), `字段自动保存 ${width}`);
    await page.locator('[data-action=choosePrivateKey]').click();
    check(await page.locator('#privateKeyPath').inputValue() === '/example/keys/selected.pem', `选私钥回填 ${width}`);
    await page.locator('#openBranches').click();
    check(await page.locator('#branchDialog').isVisible(), `分支弹窗 ${width}`);
    check(await page.locator('#branchDialog').evaluate(e => { const r = e.getBoundingClientRect(); return r.x >= 0 && r.right <= innerWidth + 1 && r.y >= 0 && r.bottom <= innerHeight + 1; }), `弹窗留在视口内 ${width}`);
    check(await page.locator('#branchResults img').count() === 0, `分支名称纯文字 ${width}`);
    await page.locator('#branchSearch').fill('login');
    check(await page.locator('#branchResults button').count() === 1, `搜索分支 ${width}`);
    await page.locator('#branchSearch').press('Enter');
    await page.waitForFunction(() => !document.querySelector('#branchDialog').open);
    check(await page.locator('#branch').inputValue() === 'feature/login', `选择回填 ${width}`);
    await page.locator('#openBranches').click(); await page.keyboard.press('Escape');
    await page.waitForFunction(() => !document.querySelector('#branchDialog').open);
    check(await page.locator('#openBranches').evaluate(e => e === document.activeElement), `关闭恢复焦点 ${width}`);
    await page.locator('#deploy').click();
    check(await page.evaluate(() => window.serverRequests.at(-1).action === 'deploy'), `部署仅发原生确认请求 ${width}`);
    await page.locator('[data-action=test]').click();
    await page.waitForFunction(() => !document.querySelector('#cancel').hidden);
    check(await page.locator('#host').isDisabled(), `运行期间禁止修改配置 ${width}`);
    await page.locator('#cancel').click();
    await page.waitForFunction(() => document.querySelector('#operationCard').dataset.state === 'cancelled');
    check(await page.locator('#host').isEnabled(), `停止后恢复操作 ${width}`);
    await page.locator('[data-action=test]').click();
    await page.waitForFunction(() => document.querySelector('#operationCard').dataset.state === 'success');
    check((await page.locator('#log').textContent()).includes('模拟检查完成'), `日志回传 ${width}`);
    await page.locator('[data-action=clearLog]').click();
    check(await page.locator('#progressSection').isHidden(), `清空重置状态 ${width}`);
    check(errors.length === 0, `无脚本错误 ${width}: ${errors}`);
    check(requests.every(url => url.startsWith('http://adswork-server.test/')), `无外部资源请求 ${width}`);
    await page.close();
  }
} finally { await browser.close(); }
await writeFile(path.join(output, 'report.json'), JSON.stringify({ checks, failures, scope: 'Chrome 中的服务器 HTML、宽窄窗口、分支弹窗与消息参数，全部模拟数据；真实 Mac 桥接另由 remote-web-check 验证' }, null, 2));
if (failures.length) { console.error(failures.join('\n')); process.exitCode = 1; }
else console.log(`服务器 HTML 浏览器检查通过：${checks} 项断言。`);
