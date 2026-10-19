import AppKit
import Foundation
import WebKit

private final class RemoteMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}
private final class RemoteDebugMessages: NSObject, WKScriptMessageHandler {
    var errors: [String] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        errors.append(String(describing: message.body))
    }
}
@main
struct RemoteWebCheck {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw LocalBuildError.message("用法：remote-web-check <WebUI> <报告目录>") }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[2]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: "/private/tmp/ads-server-check-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = root.appendingPathComponent("dummy.pem"); try Data("test fixture, not a private key".utf8).write(to: key)
        let defaults = RemoteMemoryDefaults()
        let settings = AppSettings(host: "jump.example.invalid", port: "22", username: "tester@example.invalid", privateKeyPath: key.path,
            projectPath: "/path/to/project", firstMenuChoice: "1", secondMenuChoice: "1", branch: "main")
        defaults.set(try JSONEncoder().encode(settings), forKey: "MixWebDeploy.settings.v1")
        let mock = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("mock-server.exp")
        let needle = "spawn -noecho {*}$sshCommand"
        guard ExpectProgram.source.contains(needle) else { throw LocalBuildError.message("无法替换测试传输，停止检查") }
        let source = ExpectProgram.source.replacingOccurrences(of: needle, with: "after 700\nspawn -noecho /usr/bin/expect {\(mock.path)} normal")
        let model = AppModel(defaults: defaults, expectSource: source)
        var confirmations = 0; var localBusy = false
        let bridge = RemoteWebBridge(model: model, localBusy: { localBusy }, requestDeploy: { confirmations += 1 })
        let view = bridge.makeWebView(assets: URL(fileURLWithPath: CommandLine.arguments[1]))
        let debug = RemoteDebugMessages(); view.configuration.userContentController.add(debug, name: "testDebug")
        view.configuration.userContentController.addUserScript(WKUserScript(source: "window.addEventListener('error',e=>window.webkit.messageHandlers.testDebug.postMessage(e.message||e.target.src),true);window.addEventListener('unhandledrejection',e=>window.webkit.messageHandlers.testDebug.postMessage(String(e.reason)))", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let window = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 1100, height: 980), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "服务器 HTML · 离线模拟验证"; window.contentView = view; window.orderFront(nil)
        var finished = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 75) {
            if !finished { fputs("服务器网页验证超时", stderr); Darwin.exit(1) }
        }
        Task { @MainActor in
            var checks = 0; var failures: [String] = []
            func check(_ value: Bool, _ message: String) throws { guard value else { throw LocalBuildError.message(message) }; checks += 1 }
            @MainActor func js(_ source: String) async throws -> Any? { try await view.evaluateJavaScript(source) }
            @MainActor func wait(_ condition: @MainActor () async throws -> Bool) async throws {
                for _ in 0..<200 { if try await condition() { return }; try await Task.sleep(nanoseconds: 75_000_000) }
                throw LocalBuildError.message("等待超时，脚本错误：\(debug.errors)")
            }
            do {
                try await wait { (try? await js("document.documentElement.dataset.ready==='true'")) as? Bool == true }
                try check(view.url == MacWebAssets.serverPage, "真实 Mac 服务器页面来源")
                try check((try await js("document.querySelector('#host').value")) as? String == settings.host, "沿用已有本机配置")
                try check((try await js("!document.querySelector('#connectionDisclosure').open")) as? Bool == true, "已配置时折叠连接信息")
                _ = try await js("document.querySelector('#connectionDisclosure>summary').click()")
                try check((try await js("document.querySelector('#connectionDisclosure').open")) as? Bool == true, "连接设置展开")
                try await Task.sleep(nanoseconds: 250_000_000)
                try check((try await js("document.querySelector('.connection-edit').textContent")) as? String == "收起设置", "连接展开标签与动画状态一致")
                _ = try await js("document.querySelector('#port').value='2222';document.querySelector('#port').dispatchEvent(new Event('input'))")
                try await wait { model.settings.port == "2222" }
                try check(AppModel(defaults: defaults).settings.port == "2222", "网页输入即时沿用原偏好键持久化")
                _ = try await js("document.querySelector('#deploy').click()")
                try await wait { confirmations == 1 }
                try check(!model.isRunning, "网页部署请求先交给原生确认，不直接执行")
                try await wait { (try await js("!document.querySelector('[data-action=test]').disabled")) as? Bool == true }
                _ = try await js("document.querySelector('[data-action=test]').click()")
                try await wait { model.isRunning }
                try await wait { !model.isRunning }
                try check(model.state == .success("检查连接完成"), "网页检查连接通过离线模拟传输")
                try await wait { (try await js("document.querySelector('#remoteStatus').textContent")) as? String == "执行完成" }
                try check((try await js("document.querySelectorAll('#stages .stage-step').length")) as? Int == 2, "阶段进度回传到网页")
                try check(!model.logText.contains(settings.host) && !model.logText.contains(settings.username) && !model.logText.contains("mock-private-banner"), "日志保持脱敏且隐藏横幅")
                _ = try await js("document.querySelector('#branch').value='';document.querySelector('#branch').dispatchEvent(new Event('change'));document.querySelector('[data-action=branches]').click()")
                try await wait { model.isRunning }
                try check((try await js("document.querySelector('[data-refresh]').dataset.refreshing==='true'")) as? Bool == true, "原生刷新分支期间保持按钮反馈")
                try await wait { !model.isRunning && model.branches.count == 3 }
                try await wait { (try await js("!document.querySelector('[data-refresh]').dataset.refreshing")) as? Bool == true }
                try check((try await js("!document.querySelector('[data-refresh]').disabled")) as? Bool == true, "原生刷新实际完成后恢复按钮")
                try await wait { (try await js("document.querySelector('#branchListMessage').textContent.includes('3 个分支')")) as? Bool == true }
                try check((try await js("document.querySelector('#branch').value")) as? String == model.settings.branch, "加载后自动选中的分支同步回填")
                _ = try await js("document.querySelector('#openBranches').click();document.querySelector('#branchSearch').value='login';document.querySelector('#branchSearch').dispatchEvent(new Event('input'))")
                try check((try await js("document.querySelectorAll('#branchResults button').length")) as? Int == 1, "真实分支搜索")
                _ = try await js("document.querySelector('#branchResults button').click()")
                try await wait { model.settings.branch == "feature/login" }
                try await wait { (try await js("!document.querySelector('#branchDialog').open")) as? Bool == true }
                try check((try await js("document.querySelector('#branch').value")) as? String == "feature/login", "选中分支回填并保存")
                _ = try await js("document.querySelector('#openBranches').click();document.querySelector('#branchSearch').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))")
                try await wait { (try await js("!document.querySelector('#branchDialog').open")) as? Bool == true }
                try check((try await js("document.activeElement.id")) as? String == "openBranches", "Mac 弹窗 Esc 关闭并恢复焦点")
                _ = try await js("document.querySelector('[data-action=syncBranches]').click()")
                try await wait { model.isRunning }
                try await wait { !model.isRunning }
                try check(model.state == .success("同步远程完成"), "同步分支继续调用原核心，仅模拟传输")
                try await wait { (try await js("!document.querySelector('[data-action=test]').disabled")) as? Bool == true }
                _ = try await js("document.querySelector('[data-action=test]').click()")
                try await wait { model.isRunning }
                _ = try await js("document.querySelector('#cancel').click()")
                try await wait { !model.isRunning }
                try check(model.state == .cancelled, "网页停止会结束模拟子进程")
                try await wait { (try await js("!document.querySelector('[data-action=test]').disabled")) as? Bool == true }
                _ = try await js("document.querySelector('#host').value='invalid host';document.querySelector('[data-action=test]').click()")
                try await wait { if case .failure = model.state { return true }; return false }
                try check(!model.isRunning, "无效配置在本机停止，未建立连接")
                var rejected = false
                do { _ = try bridge.handle("exec", args: ["command": "unsafe"]) } catch { rejected = true }
                try check(rejected, "拒绝任意命令接口")
                localBusy = true; rejected = false
                do { _ = try bridge.handle("branches", args: [:]) } catch { rejected = true }
                try check(rejected, "本地打包期间禁止服务器并发操作")
                localBusy = false
                model.settings = settings; model.clearLog()
                _ = try await js("document.querySelector('#host').value='jump.example.invalid';document.querySelector('#branch').value='main';document.querySelector('#connectionDisclosure').open=true")
                for width in [1100, 680] {
                    window.setContentSize(NSSize(width: width, height: 980)); try await Task.sleep(nanoseconds: 250_000_000)
                    try check((try await js("document.documentElement.scrollWidth<=innerWidth+1")) as? Bool == true, "服务器页面无横向溢出 \(width)")
                    try check((try await js("(()=>{const icons=[...document.querySelectorAll('svg.icon')].filter(s=>s.getClientRects().length);return icons.length>0&&icons.every(s=>s.querySelector('use').getBBox().width>0&&s.querySelector('use').getBBox().height>0)})()")) as? Bool == true, "服务器 Lucide 图标通过 Mac 本地资源通道实际渲染 \(width)")
                    let image = try await view.takeSnapshot(configuration: WKSnapshotConfiguration())
                    if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent("server-web-\(width).png")) }
                }
                _ = try await js("location.href='https://example.com/'")
                try await Task.sleep(nanoseconds: 200_000_000)
                try check(view.url == MacWebAssets.serverPage, "阻止外部页面导航")
                try check(debug.errors.isEmpty, "无页面脚本或资源错误：\(debug.errors)")
            } catch { failures.append(error.localizedDescription) }
            finished = true; bridge.detach(); window.orderOut(nil)
            let report: [String: Any] = ["checks": checks, "failures": failures, "scope": "真实 WKWebView 与原 AppModel；内存配置、虚构地址、临时假 PEM、离线 Expect 模拟器；无真实 SSH、远程 Git 或后台请求"]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) { try? data.write(to: output.appendingPathComponent("report.json")) }
            try? FileManager.default.removeItem(at: root)
            print("服务器 WebKit 检查：\(checks) 项断言，失败 \(failures)")
            Darwin.exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
}
