import SwiftUI
import DSCore

// MARK: - Messages 页（robot stdout / 错误消息 / DS 事件）

struct MessagesView: View {
    let model: DSModel
    @State private var paused = false
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            Picker("来源", selection: $tab) {
                Text("Console").tag(0)
                Text("错误消息").tag(1)
                Text("DS 事件").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(10)

            Divider()

            switch tab {
            case 0: console
            case 1: errors
            default: events
            }
        }
    }

    @State private var tab = 0

    // MARK: Console（robot stdout）

    private var console: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("暂停滚动", isOn: $paused)
                Spacer()
                Text("\(model.stdoutLines.count) 行")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("清空") { model.stdoutLines.removeAll() }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.stdoutLines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onChange(of: model.stdoutLines.count) { _, new in
                    guard autoScroll, !paused, new > 0 else { return }
                    proxy.scrollTo(new - 1, anchor: .bottom)
                }
            }
            .background(.black.opacity(0.85))
            .foregroundStyle(Color(red: 0.2, green: 0.9, blue: 0.35))
        }
    }

    // MARK: 错误（TCP 0x0B）

    private var errors: some View {
        List {
            if model.errorMessages.isEmpty {
                Text("无错误消息").foregroundStyle(.secondary)
            }
            ForEach(Array(model.errorMessages.enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: e.flags & 0x01 != 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(e.flags & 0x01 != 0 ? Color.red : Color.orange)
                        Text(e.details)
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("code \(e.errorCode)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if !e.location.isEmpty {
                        Text("@ \(e.location)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if !e.callStack.isEmpty {
                        Text(e.callStack).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: DS 事件

    private var events: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("清空") { model.dsEvents.removeAll() }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.dsEvents.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onChange(of: model.dsEvents.count) { _, new in
                    guard autoScroll, new > 0 else { return }
                    proxy.scrollTo(new - 1, anchor: .bottom)
                }
            }
        }
    }
}
