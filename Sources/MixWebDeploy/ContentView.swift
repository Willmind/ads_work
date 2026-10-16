import SwiftUI

@MainActor
struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var localBuild = LocalBuildModel()
    @State private var showLocalJS = true
    @State private var showDeployConfirmation = false

    var body: some View {
        Group {
            if showLocalJS {
                LocalWebView(model: localBuild, remote: model)
            } else {
                RemoteWebView(model: model, local: localBuild) { showDeployConfirmation = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Picker("工作区", selection: $showLocalJS) {
                    Text("JS 本地管理").tag(true)
                    Text("服务器分支管理").tag(false)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 290)
                .disabled(localBuild.isRunning || model.isRunning)
                .accessibilityLabel("选择工作区")
            }
        }
        .alert("确认切换服务器分支？", isPresented: $showDeployConfirmation) {
            Button("取消", role: .cancel) { }
            Button("切换并拉取") { model.run(.deploy) }
        } message: {
            Text("将在服务器目录 \(model.settings.projectPath) 切换到 \(model.settings.branch)，随后执行 git pull --ff-only。")
        }
    }
}
