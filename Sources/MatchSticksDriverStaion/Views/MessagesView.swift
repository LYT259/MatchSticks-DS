import SwiftUI
import DSCore

struct MessagesView: View {
    let model: DSModel
    @State private var source: Source = .console
    @State private var search = ""
    @State private var followsNewMessages = true

    // rawValue 仅作内部标识；显示名走 displayName（双语）
    private enum Source: String, CaseIterable, Identifiable {
        case console = "机器人输出"
        case errors = "错误与警告"
        case events = "应用事件"
        var id: String { rawValue }
        var displayName: String { tr(rawValue) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                DSSegmentedControl(title: tr("消息来源"), selection: $source,
                                   options: Source.allCases.map { DSSelectOption(value: $0, label: $0.displayName) })
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    DSSearchField(title: tr("搜索当前消息"), text: $search)
                        .frame(maxWidth: 340)
                    Spacer(minLength: 0)
                    if source != .errors {
                        Button {
                            followsNewMessages.toggle()
                        } label: {
                            Label(followsNewMessages ? tr("正在跟随") : tr("继续跟随"), systemImage: followsNewMessages ? "pause" : "arrow.down.to.line")
                        }
                        .buttonStyle(DSActionStyle(color: followsNewMessages ? DSTheme.accentText : DSTheme.textPrimary))
                        .help(followsNewMessages ? tr("暂停自动滚动；仍继续接收消息") : tr("滚动到最新消息"))
                        Button(tr("清空"), systemImage: "trash") { clearCurrentLog() }
                            .buttonStyle(DSActionStyle())
                            .disabled(currentLines.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()

            if source == .errors {
                errors
            } else {
                logLines
            }

            Divider()
            HStack {
                Text(resultSummary)
                Spacer()
                if source != .errors && !followsNewMessages {
                    Text(tr("已暂停自动滚动，仍在接收消息"))
                } else if !model.commConnected {
                    Text(tr("机器人未连接"))
                }
            }
            .font(.caption).foregroundStyle(DSTheme.textSecondary)
            .padding(.horizontal, 24).padding(.vertical, 10)
        }
    }

    private var currentLines: [LogLine] { source == .console ? model.stdoutLines : model.dsEvents }
    private var filteredLines: [LogLine] { currentLines.filter { matches($0.text) } }
    private var filteredErrors: [NICodec.ErrorMessage] {
        model.errorMessages.filter {
            matches([$0.details, $0.location, $0.callStack, String($0.errorCode)].joined(separator: " "))
        }
    }

    private var resultSummary: String {
        let total = source == .errors ? model.errorMessages.count : currentLines.count
        let count = source == .errors ? filteredErrors.count : filteredLines.count
        return search.isEmpty ? tr("%d 条消息", total) : tr("找到 %d 条 · 共 %d 条", count, total)
    }

    private var logLines: some View {
        let lines = filteredLines
        return ScrollViewReader { proxy in
            ScrollView {
                if lines.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.system(size: 13, design: .monospaced))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(24)
                }
            }
            .background(DSTheme.surface)
            .onChange(of: lines.last?.id) { _, lastID in
                guard followsNewMessages, let lastID else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
            .onChange(of: followsNewMessages) { _, follow in
                guard follow, let lastID = lines.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
            .onAppear {
                guard followsNewMessages, let lastID = lines.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
        .id(source)
    }

    private var errors: some View {
        ScrollView {
            if filteredErrors.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(filteredErrors, id: \.rowID) { entry in
                        errorRow(entry)
                    }
                }
                .padding(24)
            }
        }
    }

    private func errorRow(_ entry: NICodec.ErrorMessage) -> some View {
        let isError = entry.flags & 0x01 != 0
        return DSPanel(title: "") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 18)).foregroundStyle(isError ? DSTheme.danger : DSTheme.warning)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(isError ? tr("错误") : tr("警告")).font(.callout.weight(.semibold))
                        Spacer()
                        Text(tr("代码 %d", Int(entry.errorCode))).font(.caption.monospacedDigit()).foregroundStyle(DSTheme.textSecondary)
                    }
                    Text(entry.details).font(.callout).textSelection(.enabled)
                    if !entry.location.isEmpty {
                        Text(entry.location).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DSTheme.textSecondary).textSelection(.enabled)
                    }
                    if !entry.callStack.isEmpty {
                        DisclosureGroup(tr("调用详情")) {
                            Text(entry.callStack)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(DSTheme.textSecondary).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        DSEmptyState(
            symbol: search.isEmpty ? (source == .errors ? "checkmark.circle" : "text.alignleft") : "magnifyingglass",
            title: search.isEmpty ? (source == .errors ? tr("暂无错误或警告") : tr("暂无消息")) : tr("没有匹配的消息"),
            detail: search.isEmpty ? (source == .console ? tr("机器人程序的输出会显示在这里。") : tr("新消息会自动显示在这里。")) : tr("尝试更短的关键词，或清除搜索。"),
            minHeight: 230
        )
    }

    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }
    private func clearCurrentLog() {
        if source == .console { model.stdoutLines.removeAll() }
        else if source == .events { model.dsEvents.removeAll() }
    }
}
