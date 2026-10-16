# 0.5.0 界面预览与验证范围

- `windows-web-preview.png`：Chrome 实际渲染的 Windows HTML 界面，演示数据；顶部有预览标识，不是 Windows WebView2 实机截屏。
- `windows-empty-preview.png`：首次无历史记录时的页面。
- `windows-narrow-preview.png`：480 像素窄窗口布局；表格可在自身区域水平滚动，页面不横向溢出。
- `mac-native-preview.png`：真实 SwiftUI 本地 JS 区域的离屏渲染，使用独立临时历史；用于检查原生卡片、表格高度、输入框和按钮，不包含主窗口工作区切换栏。
- `browser-check-report.json`：53 项 Chrome 界面断言，通过三个宽度验证来源切换、搜索、编辑、空状态、忙碌与停止，以及备注以纯文字显示。

另有 7 项模拟网页消息通道的契约检查，以及 103 项 .NET 核心检查，均已通过。Windows 程序交叉编译成功；Mac release 构建和 ZIP 解压签名往返校验通过。

当前环境不能运行 Windows WebView2，真实 Windows 的组件加载、C# 消息桥接与 AdsPower 安装尚未实机验证。Windows 构建脚本会运行随程序提供的 `--web-check`，保存实际 WebView2 截图和结果；该步骤与 Chrome 预览测试相互补充。
