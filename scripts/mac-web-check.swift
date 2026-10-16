import AppKit
import Foundation
import WebKit

private final class WebMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class DebugMessages: NSObject, WKScriptMessageHandler {
    var errors: [String] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        errors.append(String(describing: message.body))
    }
}

@main
struct MacWebCheck {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw LocalBuildError.message("用法：mac-web-check <Shared/WebUI> <报告目录>") }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[2]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ads-mac-web-check-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lib = root.appendingPathComponent("target lib"); try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let target = lib.appendingPathComponent("main.min.js")
        try "module.exports='original';".write(to: target, atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("v2.8.9.4_main.min.js")
        try "module.exports='web bridge';".write(to: source, atomically: true, encoding: .utf8)
        let store = JSArchiveStore(root: root.appendingPathComponent("archive"))
        _ = try store.archive(source, sourceKind: .build, note: "Mac HTML 界面验证", branch: "test/web-ui")
        let model = LocalBuildModel(defaults: WebMemoryDefaults(), archiveRoot: store.root)
        model.settings = LocalBuildSettings(projectPath: root.appendingPathComponent("mix_client").path, libraryPath: lib.path)
        let bridge = MacWebBridge(model: model)
        let view = bridge.makeWebView(assets: URL(fileURLWithPath: CommandLine.arguments[1]))
        let debug = DebugMessages(); view.configuration.userContentController.add(debug, name: "testDebug")
        view.configuration.userContentController.addUserScript(WKUserScript(source: "window.addEventListener('error',e=>window.webkit.messageHandlers.testDebug.postMessage(e.message||e.target.src),true);window.addEventListener('unhandledrejection',e=>window.webkit.messageHandlers.testDebug.postMessage(String(e.reason)))", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 880), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "JS 本地管理 · 独立临时数据验证"; window.contentView = view; window.orderFront(nil)
        var finished = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if !finished {
                let text = "Mac WebKit 检查超时：\(debug.errors)"
                try? text.write(to: output.appendingPathComponent("timeout.txt"), atomically: true, encoding: .utf8)
                fputs(text, stderr); Darwin.exit(1)
            }
        }
        Task { @MainActor in
            var checks = 0; var failures: [String] = []
            func check(_ condition: Bool, _ message: String) throws {
                guard condition else { throw LocalBuildError.message(message) }; checks += 1
            }
            @MainActor func js(_ script: String) async throws -> Any? { try await view.evaluateJavaScript(script) }
            @MainActor func wait(_ condition: @MainActor () async throws -> Bool) async throws {
                for _ in 0..<150 { if try await condition() { return }; try await Task.sleep(nanoseconds: 100_000_000) }
                throw LocalBuildError.message("等待页面或本地操作超时：\(debug.errors)")
            }
            do {
                try await wait { (try? await js("document.documentElement.dataset.ready === 'true'")) as? Bool == true }
                try check((try await js("document.querySelector('#previewBanner').hidden")) as? Bool == true, "必须连接真实 Mac 消息通道")
                try check((try await js("document.querySelectorAll('#records tr').length")) as? Int == 1, "读取原生归档记录")
                try check((try await js("document.querySelector('#libraryPath').value")) as? String == lib.path, "读取 Mac 路径")
                for mode in ["build", "download", "file"] {
                    _ = try await js("document.querySelector('#tab-\(mode)').click()")
                    try check((try await js("!document.querySelector('#panel-\(mode)').hidden")) as? Bool == true, "来源切换 \(mode)")
                }
                _ = try await js("document.querySelector('#tab-build').click();document.querySelector('#editNote').value='Mac 网页消息桥接验证';document.querySelector('[data-action=updateMetadata]').click()")
                try await wait { model.records.first?.note == "Mac 网页消息桥接验证" && !model.isRunning }
                try check(try store.load().artifacts.first?.note == "Mac 网页消息桥接验证", "网页编辑通过原生代码持久化")
                _ = try await js("document.querySelector('[data-action=install]').click()")
                try await wait { (try? String(contentsOf: target, encoding: .utf8)) == "module.exports='web bridge';" && !model.isRunning }
                try await wait { (try await js("document.querySelector('#backupCount').textContent")) as? String == "1" }
                try check(try store.load().backups.count == 1, "真实网页安装会备份临时目标")
                _ = try await js("document.querySelector('#backupDisclosure').open=true;document.querySelector('[data-action=restore]').click()")
                try await wait { (try? String(contentsOf: target, encoding: .utf8)) == "module.exports='original';" && !model.isRunning }
                try check(try store.load().backups.count == 2, "网页恢复前再次备份")
                _ = try await js("document.querySelector('#backupDisclosure').open=false;document.querySelector('#logDisclosure').open=false")
                for width in [1100, 680] {
                    window.setContentSize(NSSize(width: width, height: width == 1100 ? 1400 : 880)); try await Task.sleep(nanoseconds: 150_000_000)
                    try check((try await js("document.documentElement.scrollWidth <= innerWidth + 1")) as? Bool == true, "页面不横向溢出 \(width)")
                    try check((try await js("(()=>{const icons=[...document.querySelectorAll('svg.icon')].filter(s=>s.getClientRects().length);return icons.length>0&&icons.every(s=>s.querySelector('use').getBBox().width>0&&s.querySelector('use').getBBox().height>0)})()")) as? Bool == true, "Lucide 图标通过 Mac 本地资源通道实际渲染 \(width)")
                    let alignment = try await js("(()=>{const s=document.querySelector('.file-details>summary'),a=s.querySelector('svg').getBoundingClientRect(),t=s.querySelector('span').getBoundingClientRect(),i=document.querySelector('#editVersion').getBoundingClientRect();return Math.abs(a.y+a.height/2-t.y-t.height/2)<1 && Math.abs(a.x-i.x)<1})()") as? Bool
                    try check(alignment == true, "箭头与文字居中且与输入框左边对齐 \(width)")
                    let config = WKSnapshotConfiguration(); config.afterScreenUpdates = false
                    let image = try await view.takeSnapshot(configuration: config)
                    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw LocalBuildError.message("无法保存 WebKit 截图") }
                    try png.write(to: output.appendingPathComponent("mac-web-\(width).png"))
                }
                window.setContentSize(NSSize(width: 1100, height: 880))
                _ = try await js("scrollTo(0,document.body.scrollHeight)")
                try await Task.sleep(nanoseconds: 150_000_000)
                let detailImage = try await view.takeSnapshot(configuration: WKSnapshotConfiguration())
                if let tiff = detailImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: output.appendingPathComponent("mac-web-details.png"))
                }
                _ = try await js("document.querySelector('#backupDisclosure').open=true;document.querySelector('#backupPicker').click()")
                try check((try await js("document.querySelector('#backupPicker').getAttribute('aria-expanded')")) as? String == "true", "原生 Mac 备份下拉菜单展开")
                _ = try await js("document.querySelector('#backupMenu [role=option]:last-child').click()")
                try await wait { (try await js("document.querySelector('#backupMenu').hidden")) as? Bool == true }
                try check((try await js("document.querySelector('#backups').value")) as? String == model.availableBackups.last?.id.uuidString.lowercased(), "Mac 下拉选择匹配真实备份")
                _ = try await js("document.querySelector('#backupDisclosure>summary').click()")
                try await wait { (try await js("!document.querySelector('#backupDisclosure').open")) as? Bool == true }
                _ = try await js("document.querySelector('.file-details>summary').click()")
                try check((try await js("document.querySelector('.file-details').open")) as? Bool == true, "文件详情展开正常")
                try check((try await js("matchMedia('(prefers-reduced-motion: reduce)').matches || document.querySelector('.file-details').getAnimations().some(a=>a.playState==='running')")) as? Bool == true, "Mac WebKit 原生展开动画")
                try await Task.sleep(nanoseconds: 250_000_000)
                _ = try await js("document.querySelector('.file-details>summary').click()")
                try await wait { (try await js("!document.querySelector('.file-details').open")) as? Bool == true }
                try check(true, "Mac WebKit 关闭动画完成后收起")
                var rejected = false
                do { _ = try bridge.handle("exec", args: ["command": "unsafe"]) } catch { rejected = true }
                try check(rejected, "拒绝任意命令接口")
                _ = try await js("location.href='https://example.com/'")
                try await Task.sleep(nanoseconds: 200_000_000)
                try check(view.url == MacWebAssets.page, "阻止外部页面导航")
                try check(debug.errors.isEmpty, "无页面脚本或资源错误：\(debug.errors)")
            } catch { failures.append(error.localizedDescription) }
            finished = true
            let report: [String: Any] = ["checks": checks, "failures": failures, "scope": "真实 Mac WKWebView、页面消息桥接、临时目录安装与恢复；不接触用户 AdsPower 文件"]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) { try? data.write(to: output.appendingPathComponent("report.json")) }
            bridge.detach(); window.orderOut(nil)
            try? FileManager.default.removeItem(at: root)
            print("Mac WebKit 检查：\(checks) 项断言，失败 \(failures)")
            Darwin.exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }
}
