import SwiftUI
import AppKit
import DSCore

// MARK: - GitHub Star（主窗口原生统一工具栏 .confirmationAction 区，与「迷你驾驶台」、更新角标同组）
//
// 轻量外链：仅用系统默认浏览器打开仓库页。不查询 star 状态、不读登录态、无遥测；
// 可见文案「Star」为 GitHub 通用术语，可访问名称与帮助文案走 tr() 随界面语言切换。

struct GitHubStarButton: View {
    static let repositoryURL = URL(string: "https://github.com/LYT259/MatchSticks-DS")!
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    // 与 MiniView 一致：观察语言管理器，切换语言时可访问名称与帮助文案随之刷新。
    @ObservedObject private var language = LanguageManager.shared

    var body: some View {
        Button {
            openURL(Self.repositoryURL)
        } label: {
            Label("Star", systemImage: "star")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(DSActionStyle(color: DSTheme.textSecondary))
        .accessibilityLabel(tr("在 GitHub 上给 MatchSticks DS 点 Star"))
        .help(tr("在默认浏览器中打开 MatchSticks DS 的 GitHub 仓库页面"))
    }
}
