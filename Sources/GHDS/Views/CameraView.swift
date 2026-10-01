import SwiftUI
import DSCore

// MARK: - 摄像头显示槽位（MOCK 通道；真实 SystemCore 流协议待实测）
//
// 数据源：GHDSSim 的自定义 MOCK 通道（默认 http://127.0.0.1:6769/frame.jpg，单帧 JPEG）。
// 交互按 First DS 的限流习惯收敛为「点按刷新 + ≥1s 限流」，无自动轮询。
// 真实流协议核查（协议档案待实测清单）后替换数据源，UI 槽位保留。

struct CameraMockPanel: View {
    @State private var host = "127.0.0.1:6769"
    @State private var image: NSImage?
    @State private var statusText = "未刷新"
    @State private var lastFetchedAt: Date?
    private let limiter = RateLimiter(minInterval: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("MOCK").font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
                Text("摄像头画面（模拟器图像源）").font(.callout.weight(.medium))
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button {
                    refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(DSActionStyle())
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(DSTheme.surface)
                if let image {
                    ImageView(image: image)
                        .padding(8)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "video.slash").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text("点「刷新」从 MOCK 通道取一帧").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                }
            }
            .frame(height: 190)
            Text("真实 SystemCore 摄像头流协议尚未核查（无实机）——本通道仅为模拟器自定义 MOCK，接入真机时按抓包事实替换（协议档案「待实测」清单）。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        guard limiter.allow() else {
            statusText = String(format: "限流中（%.0fs 后可再刷）", limiter.retryAfterSeconds())
            return
        }
        let target = host.hasPrefix("http") ? host : "http://\(host)"
        let url = URL(string: target.hasSuffix("/frame.jpg") ? target : target + "/frame.jpg")
        guard let url else { statusText = "地址无效"; return }
        statusText = "获取中…"
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    statusText = "失败：\(error.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data, data.count > 4, data.prefix(2) == Data([0xFF, 0xD8]),
                      let fetched = NSImage(data: data) else {
                    statusText = "失败：非 JPEG 响应"
                    return
                }
                image = fetched
                lastFetchedAt = Date()
                statusText = "已更新（\(data.count / 1024) KB）"
            }
        }.resume()
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
