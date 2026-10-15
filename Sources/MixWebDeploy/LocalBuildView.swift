import SwiftUI

struct LocalBuildView: View {
    @ObservedObject var model: LocalBuildModel
    let isRemoteRunning: Bool
    @State private var showLog = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                directoryRow("本地项目", path: $model.settings.projectPath, isProject: true)
                directoryRow("目标 lib", path: $model.settings.libraryPath, isProject: false)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("npm run buildLb → main.min.js")
                            .font(.callout.monospaced())
                        Text("使用本地当前分支和未提交修改；替换前自动备份原文件。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isRunning {
                        Button("停止打包", role: .destructive) { model.stop() }
                            .disabled(model.isStopping)
                    }
                    Button { model.start() } label: {
                        Label("打包并替换", systemImage: "shippingbox.and.arrow.backward")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning || isRemoteRunning)
                }
                if model.currentStage != nil {
                    ExecutionProgressView(stages: LocalBuildService.stages, currentStage: model.currentStage,
                                          state: model.state, resultSummary: model.resultSummary)
                }
                if let result = model.result {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("已替换：\(result.destination.path)")
                        if let backup = result.backup { Text("原文件备份：\(backup.path)") }
                        Text("重新启动 AdsPower 后使用新 JS。")
                    }
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !model.logText.isEmpty {
                    DisclosureGroup(isExpanded: $showLog) {
                        ScrollView {
                            Text(model.logText)
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        .frame(height: 180)
                        Button("复制打包日志") { model.copyLog() }
                            .font(.caption)
                    } label: { Text("打包日志").font(.caption) }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Label("本地客户端打包", systemImage: "desktopcomputer").font(.headline)
                Spacer()
                if model.isRunning { ProgressView().controlSize(.small) }
                Text(model.state.message)
                    .font(.caption).foregroundStyle(statusColor).lineLimit(1)
            }
        }
        .alert(model.result == nil ? "本地打包失败" : "替换成功", isPresented: $model.showResult) {
            Button("知道了", role: .cancel) { }
        } message: {
            if let result = model.result {
                Text("分支：\(result.branch)\n产物：\(result.artifact.lastPathComponent)\n已替换：\(result.destination.path)\n备份：\(result.backup?.path ?? "原文件不存在，无需备份")\n\n重新启动 AdsPower 后生效。")
            } else {
                Text(model.state.message)
            }
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .success: return .green
        case .failure: return .red
        case .running: return .accentColor
        case .cancelled: return .orange
        case .idle: return .secondary
        }
    }

    private func directoryRow(_ title: String, path: Binding<String>, isProject: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            TextField(title, text: path).textFieldStyle(.roundedBorder)
            Button("选择…") { model.chooseDirectory(isProject: isProject) }
        }
        .disabled(model.isRunning || isRemoteRunning)
    }
}
