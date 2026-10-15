import SwiftUI

@MainActor
struct BranchSearchPopover: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    @State private var searchText = ""
    @State private var requestedLoad = false
    @FocusState private var searchIsFocused: Bool

    private var branches: [String] { model.branches }

    private var filteredBranches: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return branches }

        return branches
            .filter { $0.localizedCaseInsensitiveContains(query) }
            .sorted { lhs, rhs in
                let lhsStartsWithQuery = lhs.lowercased().hasPrefix(query.lowercased())
                let rhsStartsWithQuery = rhs.lowercased().hasPrefix(query.lowercased())
                if lhsStartsWithQuery != rhsStartsWithQuery {
                    return lhsStartsWithQuery
                }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索远程分支", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                    .onSubmit {
                        if let first = filteredBranches.first {
                            select(first)
                        }
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            }
            .padding(9)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            HStack {
                Text(searchText.isEmpty ? "全部远程分支" : "搜索结果")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(filteredBranches.count) / \(branches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Divider()

            if model.isRunning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(model.state.message)
                        .font(.callout)
                    Text("操作完成后即可选择分支。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if requestedLoad, case let .failure(message) = model.state {
                VStack(spacing: 9) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text("分支加载失败")
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("检查连接设置后，可以点击下方按钮重试。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredBranches.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(branches.isEmpty ? "暂无分支列表" : "没有匹配的分支")
                        .font(.headline)
                    Text(branches.isEmpty
                         ? "点击“加载分支”读取服务器记录；新建分支请点“同步远程”。"
                         : "可以换一个关键词；新建分支请点“同步远程”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredBranches, id: \.self) { branch in
                            Button {
                                select(branch)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: branch == model.settings.branch ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(branch == model.settings.branch ? Color.accentColor : .secondary)
                                    Text(branch)
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer(minLength: 12)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .background(
                                branch == model.settings.branch ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 10) {
                Button("加载分支") { load(.branches) }
                    .help("读取服务器已有的远程分支记录，不执行 fetch")
                Button("同步远程") { load(.syncBranches) }
                    .help("同步 Git 远端后重新读取分支列表，包含新建分支")
                Spacer()
                Text("\(branches.count) 个分支")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.isRunning)
        }
        .padding(12)
        .frame(width: 420, height: 400)
        .onAppear {
            searchText = ""
            DispatchQueue.main.async {
                searchIsFocused = true
            }
        }
    }

    private func select(_ branch: String) {
        guard !model.isRunning else { return }
        model.settings.branch = branch
        isPresented = false
    }

    private func load(_ action: RemoteAction) {
        requestedLoad = true
        model.run(action)
    }
}
