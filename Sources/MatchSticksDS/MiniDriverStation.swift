import SwiftUI
import DSCore

// MARK: - Mini Driver Station 窗口切换与刷新（2026-11-23）
//
// 纯状态决策 + 可注入执行器 + AppKit 应用层三段式：
// - DriverStationWindowFlow.decide 是纯函数（决策表可单测）；
// - DriverStationWindowFlow 持有模式，perform 闭包由视图绑定到真实窗口动作；
// - DriverStationWindowPresenter 只操作已存在的 NSWindow（orderOut 隐藏 / makeKey 恢复），
//   打开新窗口交给 SwiftUI openWindow（可注入）。
// 安全边界：切换窗口只影响呈现，不动 DSModel 控制环；Mini 关闭永远带回主窗，
// 不存在「两个窗口都没了」的状态。

// MARK: 窗口切换决策

@MainActor
@Observable
final class DriverStationWindowFlow {
    enum Mode: Equatable {
        case main
        case mini
    }

    enum Event {
        /// 主窗口工具区的「迷你驾驶台」入口被点击。
        case miniEntryTapped
        /// Mini 内的「返回完整驾驶台」控件被点击。
        case returnToMainTapped
        /// Mini 窗口被用户关闭（红绿灯 / Cmd-W）。
        case miniWindowClosed
        /// Mini 窗口上屏（onAppear）。主窗模式下（状态恢复误开）归一回主窗；
        /// Mini 模式下完成切换——主窗此时才收起，兜底路径绝不等 Mini 上屏就藏主窗。
        case miniWindowAppeared
    }

    enum Effect: Equatable {
        case none
        /// 只显示 Mini：打开/前置 Mini，隐藏主窗（不关闭，保留全部状态）。
        case showMiniOnly
        /// 只显示主窗：恢复主窗，收起 Mini。
        case showMainOnly
    }

    private(set) var mode: Mode = .main

    /// 窗口效果执行器：生产绑定 DriverStationWindowPresenter，测试注入记录闭包。
    var perform: (Effect) -> Void = { _ in }

    /// 决策表（纯函数）：事件 × 当前模式 → 新模式 + 窗口效果。
    /// 过时/重复事件一律 `.none`，窗口动作不叠加。
    static func decide(_ event: Event, mode: Mode) -> (mode: Mode, effect: Effect) {
        switch (event, mode) {
        case (.miniEntryTapped, .main):
            return (.mini, .showMiniOnly)
        case (.returnToMainTapped, .mini), (.miniWindowClosed, .mini):
            return (.main, .showMainOnly)
        case (.miniWindowAppeared, .main):
            return (.main, .showMainOnly)
        case (.miniWindowAppeared, .mini):
            return (.mini, .showMiniOnly)
        case (.miniEntryTapped, .mini),
             (.miniWindowClosed, .main),
             (.returnToMainTapped, .main):
            return (mode, .none)
        }
    }

    func send(_ event: Event) {
        let decision = Self.decide(event, mode: mode)
        mode = decision.mode
        // 无效果事件不惊动执行器（重复/过时点击不叠加窗口动作）。
        if decision.effect != .none {
            perform(decision.effect)
        }
    }
}

// MARK: AppKit 应用层

@MainActor
enum DriverStationWindowPresenter {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("MatchSticksDS.main-window")
    static let miniWindowIdentifier = NSUserInterfaceItemIdentifier("MatchSticksDS.mini-window")

    /// 把窗口效果落到真实 NSWindow 上。openMini/openMain 只在目标窗口尚不存在时
    /// 兜底调用（SwiftUI openWindow 可注入；隐藏过的窗口始终存在，走 makeKey/orderOut）。
    static func apply(_ effect: DriverStationWindowFlow.Effect,
                      openMini: () -> Void,
                      openMain: () -> Void = {}) {
        switch effect {
        case .none:
            break
        case .showMiniOnly:
            if let mini = window(miniWindowIdentifier) {
                mini.makeKeyAndOrderFront(nil)
                window(mainWindowIdentifier)?.orderOut(nil)
            } else {
                // macOS 14+ 不保证已关闭的场景窗口残留在 NSApp.windows：找不到就要求
                // 真实 openWindow 重建。此刻绝不隐藏主窗——绝不能先隐藏主窗后无窗；
                // Mini 真正上屏后由 .miniWindowAppeared 完成切换（收起主窗）。
                openMini()
            }
        case .showMainOnly:
            if let main = window(mainWindowIdentifier) {
                main.makeKeyAndOrderFront(nil)
            } else {
                openMain()
            }
            window(miniWindowIdentifier)?.orderOut(nil)
        }
    }

    private static func window(_ identifier: NSUserInterfaceItemIdentifier) -> NSWindow? {
        NSApp.windows.first { $0.identifier == identifier }
    }
}

// MARK: 窗口标识与关闭监听（挂场景内容，0 尺寸、不参与布局）

/// 给宿主 NSWindow 打上稳定标识符（供 Presenter 查找）。
struct WindowIdentity: NSViewRepresentable {
    let identifier: NSUserInterfaceItemIdentifier

    func makeNSView(context: Context) -> IdentityView {
        let view = IdentityView(frame: .zero)
        view.windowIdentifier = identifier
        return view
    }

    func updateNSView(_ view: IdentityView, context: Context) {
        view.windowIdentifier = identifier
    }

    final class IdentityView: NSView {
        var windowIdentifier: NSUserInterfaceItemIdentifier? {
            didSet { applyIfNeeded() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyIfNeeded()
        }

        private func applyIfNeeded() {
            guard let windowIdentifier, let window else { return }
            window.identifier = windowIdentifier
        }
    }
}

/// 监听宿主窗口关闭（红绿灯 / Cmd-W），把事件送进窗口流——主窗必须回来。
struct MiniWindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> CloseObservingView {
        let view = CloseObservingView(frame: .zero)
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: CloseObservingView, context: Context) {
        view.onClose = onClose
    }

    final class CloseObservingView: NSView {
        var onClose: (() -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.onClose?()
            }
        }
    }
}

// MARK: 机器人刷新反馈

/// 刷新按钮的反馈状态：点击执行真实刷新动作（action 返回是否接受），
/// 动作被接受才旋转；旋转在通信状态变化时提前结束，最迟 maxSpinInterval 结束，
/// 可随时再次触发（generation 递增驱动视图动画重启）。
/// 时钟可注入（测试无定时器依赖）；生产由视图的 .task(id:) 推进超时。
@MainActor
@Observable
final class RobotRefreshFlow {
    /// 旋转最长持续时长：搜索窗口一轮足够看清，又不至于卡死反馈。
    static let maxSpinInterval: TimeInterval = 2.0

    private(set) var isRefreshing = false
    private(set) var generation = 0
    private var startedAt: Date?
    private let clock: () -> Date
    private var action: () -> Bool

    init(clock: @escaping () -> Date = Date.init, action: @escaping () -> Bool = { true }) {
        self.clock = clock
        self.action = action
    }

    /// 绑定真实刷新动作（MiniView onAppear 时指向 model.refreshRobotConnection()）。
    func bindAction(_ action: @escaping () -> Bool) {
        self.action = action
    }

    /// 用户点击：动作被拒绝（如已连接）时不旋转——视觉反馈不允许脱离真实动作。
    func request() {
        let accepted = action()
        generation += 1
        if accepted {
            startedAt = clock()
            isRefreshing = true
        } else {
            startedAt = nil
            isRefreshing = false
        }
    }

    /// 超时收尾：由视图的 .task(id: generation) 在睡眠 maxSpinInterval 后调用；
    /// 注入时钟的测试直接推进 now 后调用。
    func settle() {
        guard isRefreshing, let beginAt = startedAt else { return }
        if clock().timeIntervalSince(beginAt) >= Self.maxSpinInterval {
            isRefreshing = false
            startedAt = nil
        }
    }

    /// 机器人通信状态变化（搜索 → 连接等）：搜索有了结果，旋转提前结束。
    func noteCommStateChange() {
        guard isRefreshing else { return }
        isRefreshing = false
        startedAt = nil
    }
}
