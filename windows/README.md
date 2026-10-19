# AdsWork JS 本地管理 · Windows 0.8.0

Windows 版采用本地 HTML/CSS + WebView2 界面，沿用现有 C# 本地功能。与 Mac 共用 `Shared/WebUI` 的苹果风格页面和 Lucide SVG 图标，统一卡片内距、表单对齐、控件高度与分区间距；不包含服务器分支管理，不向后台上传或修改数据。

## 启动

使用 Windows 10/11 x64，先关闭旧版，完整解压 ZIP，再运行 `AdsWorkJsManager.exe`。窗口标题显示 `0.8.0`。

- 程序自带 .NET 运行环境，无需另外安装 .NET。
- 界面需要 Microsoft Edge WebView2 Runtime；已安装时直接启动。
- 未安装时程序会显示中文提示，可点击“安装 WebView2 运行环境…”打开随包的微软官方安装程序。安装引导程序需要联网，完成后重新打开工具。
- 请保留同目录 `WebView2Loader.dll` 和 `MicrosoftEdgeWebview2Setup.exe`，不要只拷走主 EXE。
- 程序未使用商业签名证书；首次运行请核对来源及 `SHA256SUMS.txt`。

用户界面资源已嵌入 EXE，不从 CDN 或网站加载页面、字体或脚本，不需要配置服务器。WebView2 采用单独的本地资料目录；不会读取浏览器 Cookie。JS 下载仍由本地下载组件完成。

蓝色盒子 Logo 保留；功能图标仅打包实际使用的 Lucide SVG，随程序离线加载。完整上游许可证位于 `Licenses\Lucide.LICENSE.txt`。

## 默认路径与原有数据

项目目录：

```text
C:\install\mix_client
```

目标目录使用当前账号 `%APPDATA%`。StandardSoftware 账号对应：

```text
C:\Users\StandardSoftware\AppData\Roaming\adspower_global\cwd_global\lib
```

可以手动编辑或选择目录；“保存”会记住两个目录，每次操作前也会保存当前输入。0.4.x 的配置和历史继续读取，无需迁移。

本地数据位于 `%LOCALAPPDATA%\AdsWorkJsManager`：`settings.json` 保存路径，`index.json` 保存记录与备份位置，`files\<UUID>\main.min.js` 保存独立 JS。备份文件仍在实际 lib 中；`WebView2` 子目录保存界面组件的本地资料。

## 添加 JS

- **本地打包**：准备好项目依赖，确保终端能运行 Git、Node/npm 和项目要求的 Node 版本。工具使用当前分支及未提交修改执行 `npm run buildLb`，不切换或拉取分支。“打包保存”只归档，“打包并安装”归档后再更新主文件。
- **链接下载**：粘贴完整 `https://version.adspower.net/...` JS 链接，保留 `.js` 后的 32 位 MD5；支持自动识别或手动填写 MD5。只发送 GET，不发送后台登录信息；限制 HTTPS 和同域跳转，下载后不自动安装。
- **导入文件**：选择完整的本地主 JS，校验后保存。

备注会跟随新记录保存。每次保存都有独立 ID，同名、同版本不会覆盖本地历史。支持搜索版本、备注、文件名、来源和分支；空格可以组合关键词。选中记录后可编辑版本和备注，查看文件摘要。按钮、来源切换、详情、备份与日志均有过渡动画；备份下拉菜单支持键盘选择，并遵循系统减少动态效果设置。

JS 须为非空普通 UTF-8 文件，不超过 100 MB；只检查语法，不执行脚本。MD5 不一致、网页、语法错误或 SHA-256 不一致会停止对应操作。没有预期 MD5 时，语法和本地摘要检查不代表已验证发布方 MD5。

## build 文件夹

列表递归显示当前所选项目 `build` 中的 JS 文件名、大小、修改时间。前台约每秒自动刷新，页面隐藏时每 5 秒刷新，外部打包产生的文件也会更新；支持手动刷新。更换项目路径后自动切换读取目标，不会触发构建或保存路径。

每条 JS 右侧提供“复制”，将独立文件副本写入 Windows 文件剪贴板，可直接粘贴到资源管理器的目标文件夹，保留原文件名。随后清空 build 不影响该副本；复制成功后短暂显示“已复制”。只支持不超过 100 MB 的普通 JS，复制期间禁止同时打包或清空。

副本缓存位于本机数据目录 `copied-js`；成功复制后保留最近十份和当前剪贴板引用的副本，清理过期缓存。它们不加入 JS 历史。手动点击 build 或历史“刷新”时图标旋转，读取完成后停止；后台自动读取不旋转。“清空 build”与“停止”统一红色边框、浅红悬停与深红按下白字。

“清空 build”会先显示实际目录并要求确认，默认选中“否”。确认后删除所有文件（包括非 JS 文件）及子目录，保留 `build` 目录本身。删除不可撤销；本地 JS 历史、AdsPower 安装文件和备份保留。打包时禁用清空，两者共用构建锁；拒绝链接/重解析点、构建恢复目录及位于 build 内的历史库或安装目录。失败或停止后列表会更新，已删除的文件不会恢复。

## 安装与恢复

先完全退出 AdsPower，核对目标 lib，再点击“安装选中版本”。程序检查文件语法与 SHA-256，自动备份旧 `main.min.js`，校验同目录临时文件后原子替换。成功后重新启动 AdsPower 验证。文件占用或无权限时提示重试，不强制解除占用。

展开“备份与恢复”可恢复当前目标目录的备份；恢复前也会备份当前文件。备份缺失、被改动或属于其他目标目录时拒绝恢复。

打包前暂存 `build` 中的旧主 JS，必须生成唯一新主 JS 才继续；失败或停止时恢复旧主产物，避免误用旧包。打包最多 15 分钟，下载最多 120 秒，运行期间可以停止。关闭窗口时会先停止子进程并完成清理。

构建锁位于项目 `.ads-work-build.lock`。异常退出后如有残留，请先确认没有构建进程，再删除锁文件。索引损坏时保留数据并报错，不静默清空历史。操作日志可展开和复制，地址与路径会脱敏。

## 从源码构建与测试

开发机需 .NET SDK 10.0.402 或兼容补丁版；最终用户不需要 SDK。

Windows PowerShell：

```powershell
cd windows
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

脚本执行核心测试、发布程序，在真实 Windows WebView2 上验证加载、本地消息桥接、宽窄窗口和 100%/125%/150% 浏览器缩放，成功才生成 ZIP。测试使用临时数据，不执行真实安装。截图和报告保存在 `%TEMP%\AdsWork-WebUI-report-*`。不同系统 DPI 仍需在对应显示设置下另行验证。

微软安装引导程序的 SHA-256 固定在 `RuntimeInstaller.cs`。如微软更新该文件，构建脚本会停止；核对官方来源并更新该校验值后再发布。

Mac/Linux 可交叉编译：

```sh
cd windows
dotnet run --project JsLocalManager.Checks -c Release
dotnet publish JsLocalManager/JsLocalManager.csproj -c Release -r win-x64 --self-contained true -o ../dist/windows-x64
```

浏览器预览与前端测试不执行本地操作，需自行准备 Node.js、Playwright 和 Chromium/Chrome：

```sh
python3 -m http.server 18450 --bind 127.0.0.1 --directory ../Shared/WebUI
# 另一个终端，在 windows 目录：
node scripts/check-web.mjs
node scripts/check-motion.mjs
node scripts/check-native-bridge.mjs
node scripts/check-build-directory.mjs
node scripts/check-copy-refresh.mjs
```

预览地址 `http://127.0.0.1:18450/index.html?preview=1&seed=1`，顶部显示预览标识。`seed=0` 查看空历史。测试可通过 `PLAYWRIGHT_MODULE`、`CHROME_PATH`、`UI_PREVIEW_URL`、`UI_CHECK_OUTPUT` 指定环境，不依赖开发者的个人路径。

## 本次验证范围

- 149 项核心断言在 Mac 上通过：真实临时 Git/npm 打包、同名产物、失败/取消回滚、安装与备份恢复、校验、下载限制、页面来源、操作白名单和参数校验，覆盖 build 列表、清空边界与共用锁，以及独立文件副本、清空后粘贴、复制边界、取消与缓存清理。
- 62 项 Chrome 界面断言通过，实际检查 1120/760/480 像素宽度的渲染、来源切换、功能图标实际绘制、搜索、编辑、纯文字显示、忙碌状态、停止与空历史；已人工查看截图。
- 12 项 build 列表浏览器断言通过：自动刷新、切换项目、忙碌互斥、清空响应、错误显示、文件名纯文字与窄窗口。
- 21 项复制与刷新交互断言通过：手动旋转、自动读取不旋转、等待实际请求、红色按钮各状态、复制成功/失败与窄窗口。
- 24 项动画与下拉断言通过，覆盖展开与关闭、快速切换、键盘选中、焦点恢复、窄窗口菜单和减少动态效果。
- 另有 7 项模拟本地消息通道的浏览器契约检查，验证 UUID 请求、配置读取、目录回填和下载参数；这不是 Windows 原生桥接执行结果。
- Windows x64 交叉编译通过；从最终 EXE 解包并核对内嵌页面、样式、动画、Logo 和图标，确保与当前源码及 Mac 应用内的同名资源字节一致；程序、DLL、微软安装程序和压缩包另核对 SHA-256。
- 当前 Mac 无法运行 Windows WebView2，本轮尚无真实 Windows 消息桥接、运行环境安装和 AdsPower 实机验证结果。随包提供 `--web-check` 模式，可在 Windows 上检查并保存截图；浏览器预览测试不能代替这一步。

```powershell
$process = Start-Process .\AdsWorkJsManager.exe -ArgumentList '--web-check' -Wait -PassThru
$process.ExitCode
```

独立检查报告在 `%TEMP%\AdsWork-WebUI-*`。本包包含 .NET、Windows Desktop、Acornima、WebView2 SDK 和 Lucide 许可证。
