import SwiftUI

struct BranchSearchPopover: View {
    @Binding var selectedBranch: String
    let branches: [String]
    @Binding var isPresented: Bool

    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool

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

            if filteredBranches.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("没有匹配的分支")
                        .font(.headline)
                    Text("可以换一个关键词，或直接在主界面输入分支名。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                                    Image(systemName: branch == selectedBranch ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(branch == selectedBranch ? Color.accentColor : .secondary)
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
                                branch == selectedBranch ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 390, height: 360)
        .onAppear {
            searchText = ""
            DispatchQueue.main.async {
                searchIsFocused = true
            }
        }
    }

    private func select(_ branch: String) {
        selectedBranch = branch
        isPresented = false
    }
}
