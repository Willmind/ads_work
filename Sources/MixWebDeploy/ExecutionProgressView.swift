import SwiftUI

struct ExecutionProgressView: View {
    let stages: [RunStage]
    let currentStage: RunStage?
    let state: RunState
    let resultSummary: String?

    private var currentIndex: Int {
        stages.firstIndex(of: currentStage ?? .connect) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(stages.enumerated()), id: \.element.rawValue) { index, stage in
                    VStack(spacing: 6) {
                        if index == currentIndex, case .running = state {
                            ProgressView().controlSize(.small).frame(height: 20)
                        } else {
                            Image(systemName: symbol(at: index))
                                .font(.system(size: 17))
                                .frame(height: 20)
                        }
                        Text(stage.title)
                            .font(.caption)
                    }
                    .foregroundStyle(color(at: index))
                    .frame(maxWidth: .infinity)
                }
            }

            if case let .failure(message) = state {
                Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            } else if case .cancelled = state {
                Text(!stages.contains(.connect) ? "本地操作已停止，已保存的 JS 和备份会保留。" : "连接已断开，已执行的远程步骤不会撤销。请检查服务器状态。")
                    .foregroundStyle(.secondary).font(.callout)
            } else if let resultSummary {
                Text(resultSummary).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func color(at index: Int) -> Color {
        if case .success = state { return .green }
        if index < currentIndex { return .green }
        if index > currentIndex { return .secondary }
        if case .failure = state { return .red }
        if case .cancelled = state { return .orange }
        return .accentColor
    }

    private func symbol(at index: Int) -> String {
        if case .success = state { return "checkmark.circle.fill" }
        if index < currentIndex { return "checkmark.circle.fill" }
        if index == currentIndex {
            if case .failure = state { return "xmark.circle.fill" }
            if case .cancelled = state { return "stop.circle" }
        }
        return "circle"
    }
}
