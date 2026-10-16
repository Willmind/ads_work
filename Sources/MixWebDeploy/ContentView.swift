import SwiftUI

@MainActor
struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var localBuild = LocalBuildModel()
    @State private var showLocalJS = true
    @State private var showSettings: Bool
    @State private var showDeployConfirmation = false
    @State private var showBranchPicker = false

    init(model: AppModel) {
        self.model = model
        _showSettings = State(initialValue: model.connectionNeedsAttention)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showLocalJS {
                LocalWebView(model: localBuild, remote: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        connectionSettings.disabled(localBuild.isRunning)
                        deploymentControls.disabled(localBuild.isRunning)
                        if let action = model.displayedAction {
                            ExecutionProgressView(stages: action.stages, currentStage: model.currentStage,
                                                  state: model.state, resultSummary: model.resultSummary)
                        }
                        logPanel
                    }
                    .padding(24)
                    .frame(maxWidth: 1160, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
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
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.connectionNeedsAttention) { needsAttention in
            if needsAttention { showSettings = true }
        }
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
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 26))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(showLocalJS ? "JS 本地管理" : "Mix Web 部署工具")
                    .font(.title2.weight(.semibold))
                Text("本地 JS 打包、下载、管理与安装")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            if !showLocalJS { statusBadge }
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
            Text(statusMessage)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.quaternary, in: Capsule())
    }

    private var statusMessage: String {
        if case .failure = model.state { return "操作失败" }
        return model.state.message
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
        case .cancelled:
            return .orange
        }
    }

    private var connectionSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    showSettings.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showSettings ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Text(model.connectionNeedsAttention ? "请完善连接配置" : "连接已配置，保存在本机")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Label(showSettings ? "收起设置" : "展开修改", systemImage: "slider.horizontal.3")
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showSettings ? "收起连接设置" : "展开连接设置")
                .accessibilityValue(showSettings ? "已展开" : "已收起")

                if showSettings {
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
                    .help("打开分支搜索；列表为空时可在弹窗内加载分支")
                    .popover(isPresented: $showBranchPicker, arrowEdge: .bottom) {
                        BranchSearchPopover(
                            model: model,
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
                    .disabled(model.isRunning)

                    Button {
                        model.run(.branches)
                    } label: {
                        Label("刷新分支", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRunning)
                    .help("读取服务器已有的远程分支记录，不执行 git fetch；仍需连接 Jumpserver")

                    Button {
                        model.run(.syncBranches)
                    } label: {
                        Label("同步远程", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.isRunning)
                    .help("先同步 Git 远端，再更新分支列表，包含新建分支")

                    Spacer()

                    if model.isRunning {
                        Button("停止", role: .destructive) {
                            model.stop()
                        }
                        .disabled(model.isStopping)
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

                Text(model.branchListMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .frame(height: 260)
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
                Text("连接信息已隐藏")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("复制脱敏日志") {
                    model.copyLog()
                }
                .disabled(model.logText.isEmpty)
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
