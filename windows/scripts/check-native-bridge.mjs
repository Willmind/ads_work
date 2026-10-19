import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) });
let count = 0;
function check(value, message) { if (!value) throw new Error(message); count++; }
try {
  const page = await browser.newPage({ viewport: { width: 1100, height: 950 } });
  await page.addInitScript(() => {
    const listeners = [];
    const snapshot = { settings: { projectPath: 'C:\\install\\mix_client', libraryPath: 'C:\\AdsPower\\lib' }, records: [], backups: [], busy: false, logs: '', operation: null };
    window.bridgeRequests = [];
    window.chrome.webview = {
      addEventListener: (_, callback) => listeners.push(callback),
      postMessage: request => {
        window.bridgeRequests.push(request);
        if (request.args.settings) snapshot.settings = request.args.settings;
        if (request.action === 'chooseProject') snapshot.settings.projectPath = 'D:\\selected project';
        queueMicrotask(() => {
          for (const callback of listeners) callback({ data: { id: request.id, ok: true, data: { snapshot: structuredClone(snapshot) } } });
        });
      }
    };
  });
  await page.goto(`${process.env.UI_PREVIEW_URL || 'http://127.0.0.1:18450'}/index.html`);
  await page.waitForSelector('html[data-ready=true]');
  check(await page.locator('#previewBanner').isHidden(), '真实传输通道不应启用演示');
  check(await page.locator('#projectPath').inputValue() === 'C:\\install\\mix_client', '读取本地配置响应');
  await page.locator('#projectPath').fill('E:\\work project');
  await page.locator('[data-action=saveSettings]').click();
  await page.waitForTimeout(30);
  let requests = await page.evaluate(() => window.bridgeRequests.filter(request => request.action !== 'buildFiles'));
  check(requests.at(-1).action === 'saveSettings' && requests.at(-1).args.settings.projectPath === 'E:\\work project', '路径通过结构化参数传输');
  check(/^[0-9a-f-]{36}$/.test(requests[0].id), '请求 ID 为 UUID');
  await page.locator('[data-action=chooseProject]').click();
  await page.waitForTimeout(30);
  check(await page.locator('#projectPath').inputValue() === 'D:\\selected project', '选择目录响应回填');
  await page.locator('#tab-download').click();
  await page.locator('#downloadUrl').fill('https://version.adspower.net/version_main.min.js');
  await page.locator('#newNote').fill('结构化参数测试');
  await page.locator('#addPrimary').click();
  await page.waitForTimeout(30);
  requests = await page.evaluate(() => window.bridgeRequests.filter(request => request.action !== 'buildFiles'));
  check(requests.at(-1).action === 'download' && requests.at(-1).args.note === '结构化参数测试', '下载接口参数契约');
  check(requests.at(-1).args.url.endsWith('.js'), '下载 URL 参数');
  console.log(`本地消息桥接浏览器契约检查通过：${count} 项断言。未访问本机文件。`);
} finally { await browser.close(); }
