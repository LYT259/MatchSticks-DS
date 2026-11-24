import SwiftUI
import DSCore

// MARK: - 摄像头显示槽位（MOCK 通道；真实 SystemCore 流协议待实测）
//
// 数据源：MatchSticksDriverStaionSim 的自定义 MOCK 通道（默认 http://127.0.0.1:6769/frame.jpg，单帧 JPEG）。
// 交互按 First DS 的限流习惯收敛为「点按刷新 + ≥1s 限流」，无自动轮询。
// 真实流协议核查（协议档案待实测清单）后替换数据源，UI 槽位保留。

struct CameraMockPanel: View {
    @State private var host = "127.0.0.1:6769"
    @State private var image: NSImage?
    @State private var statusText = ""
    // 首帧渲染时按当前语言初始化（避免语言切换后残留旧语言状态串）
    @State private var statusInitialized = false
    @State private var lastFetchedAt: Date?
    private let limiter = RateLimiter(minInterval: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DSBadge(text: "MOCK", color: DSTheme.warning, symbol: "video")
                Text(tr("摄像头画面（模拟器图像源）")).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(DSTheme.textSecondary).monospacedDigit()
                Button {
                    refresh()
                } label: {
                    Label(tr("刷新"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(DSActionStyle())
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(DSTheme.canvas)
                if let image {
                    ImageView(image: image)
                        .padding(8)
                } else {
                    DSEmptyState(symbol: "video.slash", title: tr("点「刷新」从 MOCK 通道取一帧"), minHeight: 170)
                }
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DSTheme.line))
            Text(tr("真实 SystemCore 摄像头流协议尚未核查（无实机）——本通道仅为模拟器自定义 MOCK，接入真机时按抓包事实替换（协议档案「待实测」清单）。"))
                .font(.caption).foregroundStyle(DSTheme.textSecondary)
        }
        .onAppear {
            // 状态串按当前语言初始化（语言切换整树重建后同样按新语言显示）
            if !statusInitialized { statusInitialized = true; statusText = tr("未刷新") }
        }
    }

    private func refresh() {
        guard limiter.allow() else {
            statusText = tr("限流中（%.0fs 后可再刷）", limiter.retryAfterSeconds())
            return
        }
        let target = host.hasPrefix("http") ? host : "http://\(host)"
        let url = URL(string: target.hasSuffix("/frame.jpg") ? target : target + "/frame.jpg")
        guard let url else { statusText = tr("地址无效"); return }
        statusText = tr("获取中…")
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    statusText = tr("失败：%@", error.localizedDescription)
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data, data.count > 4, data.prefix(2) == Data([0xFF, 0xD8]),
                      let fetched = NSImage(data: data) else {
                    statusText = tr("失败：非 JPEG 响应")
                    return
                }
                image = fetched
                lastFetchedAt = Date()
                statusText = tr("已更新（%d KB）", data.count / 1024)
            }
        }.resume()
    }
}

struct CameraView: View {
    let model: DSModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                DSPanel(title: tr("摄像头"), subtitle: tr("模拟器 MOCK 图像源（真实 SystemCore 流协议待实测）")) {
                    CameraMockPanel()
                }
            }
            .padding(24)
        }
    }
}

private struct ImageView: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) { v.image = image }
}
