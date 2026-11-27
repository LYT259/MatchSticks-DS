import AppKit

@MainActor
func appLifecycleTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let delegate = AppLifecycleDelegate()
    check(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
          "closing the last window terminates the app instead of leaving a background process")

    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appSource = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/MatchSticksDriverStaion/MatchSticksDriverStaionApp.swift"), encoding: .utf8)) ?? ""
    let buildScript = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "scripts/build-app.sh"), encoding: .utf8)) ?? ""
    check(appSource.contains("NSApplication.shared.delegate = appDelegate"),
          "the main app installs the native last-window lifecycle delegate")
    check(!buildScript.contains("LSBackgroundOnly") && !buildScript.contains("LSUIElement"),
          "the packaged app is not declared as a background-only or agent application")
}
