# 0.6.0 共用 HTML 界面验证

Mac 的 JS 本地管理通过 WKWebView 加载 `Shared/WebUI`；Windows 通过 WebView2 嵌入同一份文件。服务器分支管理仍使用原生 SwiftUI。路径配置、历史与备份保留原格式和位置。

- `mac-web-preview.png`、`mac-web-details.png`、`mac-narrow-preview.png`：真实 Mac WKWebView 截图，使用临时 JS 库和临时目标目录，安装与恢复均已实际执行；图中的路径与记录属于测试数据。
- `windows-web-preview.png`、`windows-narrow-preview.png`、`windows-empty-preview.png`：Chrome 中的 HTML 渲染结果，顶部有演示提示，未访问本机文件。
- `mac-web-check-report.json`：21 项真实 Mac 网页桥接断言，包含备注持久化、安装与备份、恢复、下拉选择、箭头对齐、动画、宽窄窗口与导航限制。
- `browser-check-report.json`：53 项界面与响应式断言。
- `motion-check-report.json`：24 项动画与菜单断言，包含展开、收起、快速切换、键盘、焦点恢复、窄窗口与减少动态效果。
- Windows 本地消息浏览器契约：7 项通过，使用模拟接口。
- Mac 现有核心检查与临时 Git/npm 打包检查通过，Windows 核心 103 项断言通过。所有测试不接触真实 AdsPower lib 或后台数据。

Mac release 编译、应用资源一致性、签名和 ZIP 解压验证通过；Windows x64 交叉编译、随包 DLL、微软安装引导程序与 ZIP 校验通过。本机无法运行 Windows WebView2，Windows 原生加载、系统 DPI 和 AdsPower 实机流程仍需在 Windows 验证。Windows `--web-check` 模式继续保留，`windows/build.ps1` 会在 Windows 上执行该检查后打包。

复核命令：`zsh scripts/check.sh`、`zsh scripts/check-web.sh`；浏览器检查说明见 `windows/README.md`。
