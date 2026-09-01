import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showSettings = true
    @State private var showDeployConfirmation = false
    @State private var showBranchPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionSettings
                    deploymentControls
                    logPanel
                }
                .padding(22)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("确认切换服务器分支？", isPresented: $showDeployConfirmation) {
            Button("取消", role: .cancel) { }
            Button("切换并拉取") {
                model.run(.deploy)
            }
        } message: {
            Text("将在服务器目录 \(model.settings.projectPath) 切换到 \(model.settings.branch)，随后执行 git pull --ff-only。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 26))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mix Web 部署工具")
                    .font(.title2.weight(.semibold))
                Text("通过 Jumpserver 安全切换并更新服务器分支")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            statusBadge
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var statusBadge: some View {
        HStack(spacing: 7) {
            if model.isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
            }
            Text(model.state.message)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.quaternary, in: Capsule())
    }

    private var statusColor: Color {
        switch model.state {
        case .idle:
            return .secondary
        case .running:
            return .blue
        case .success:
            return .green
        case .failure:
            return .red
        }
    }

    private var connectionSettings: some View {
        GroupBox {
            DisclosureGroup("", isExpanded: $showSettings) {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        fieldLabel("SSH 主机")
                        TextField("jumpserver.example.com", text: $model.settings.host)
                        Text("端口")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        TextField("22", text: $model.settings.port)
                            .frame(width: 90)
                    }

                    settingsRow("SSH 用户") {
                        TextField("用户名", text: $model.settings.username)
                    }

                    settingsRow("PEM 私钥") {
                        HStack(spacing: 8) {
                            TextField("选择 PEM 私钥", text: $model.settings.privateKeyPath)
                            Button("选择…") {
                                model.choosePrivateKey()
                            }
                        }
                    }

                    settingsRow("项目目录") {
                        TextField("/path/to/project", text: $model.settings.projectPath)
                    }

                    settingsRow("菜单选项") {
                        HStack(spacing: 8) {
                            TextField("1", text: $model.settings.firstMenuChoice)
                                .frame(width: 70)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            TextField("1", text: $model.settings.secondMenuChoice)
                                .frame(width: 70)
                            Text("对应现有 Jumpserver 的两次选择")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.top, 10)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isRunning)
            }
        } label: {
            HStack {
                Label("连接设置", systemImage: "network")
                    .font(.headline)
                Spacer()
                Text("私钥仅保留文件路径，不会复制进应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var deploymentControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("输入分支，例如 develop", text: $model.settings.branch)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isRunning)

                    Button {
                        showBranchPicker = true
                    } label: {
                        Label("选择分支", systemImage: "magnifyingglass")
                    }
                    .disabled(model.isRunning || model.branches.isEmpty)
                    .popover(isPresented: $showBranchPicker, arrowEdge: .bottom) {
                        BranchSearchPopover(
                            selectedBranch: $model.settings.branch,
                            branches: model.branches,
                            isPresented: $showBranchPicker
                        )
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        model.run(.test)
                    } label: {
                        Label("检查连接", systemImage: "bolt.horizontal.circle")
                    }

                    Button {
                        model.run(.branches)
                    } label: {
                        Label("刷新分支", systemImage: "arrow.clockwise")
                    }

                    Spacer()

                    if model.isRunning {
                        Button("停止", role: .destructive) {
                            model.stop()
                        }
                    }

                    Button {
                        showDeployConfirmation = true
                    } label: {
                        Label("切换并拉取", systemImage: "arrow.down.to.line.compact")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning || model.settings.branch.isEmpty)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("部署操作", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
        }
    }

    private var logPanel: some View {
        GroupBox {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.logText.isEmpty ? "执行日志会显示在这里。" : model.logText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(model.logText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)

                    Color.clear
                        .frame(height: 1)
                        .id("log-bottom")
                }
                .frame(minHeight: 210)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .onChange(of: model.logText) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
            }
        } label: {
            HStack {
                Label("执行日志", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Button("清空") {
                    model.clearLog()
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning || model.logText.isEmpty)
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(width: 72, alignment: .trailing)
    }

    private func settingsRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            fieldLabel(title)
            content()
        }
    }
}
