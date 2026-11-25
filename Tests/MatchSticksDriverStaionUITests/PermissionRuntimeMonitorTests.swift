import AppKit
import DSCore

@MainActor
func permissionRuntimeMonitorTests(_ check: @MainActor (@autoclosure () -> Bool, String) -> Void) {
    let monitor = PermissionRuntimeMonitor()
    check(monitor.networkEvidence == .checking && monitor.firewallEvidence == .notStarted,
          "fresh launch starts with checking rather than inherited success")

    monitor.applyDiscovery(.ready)
    monitor.applyDiscovery(.services(["roboRIO-FRC"]))
    monitor.applyDiscovery(.waiting("network unavailable"))
    check(monitor.networkEvidence == .checking && monitor.networkEvidence.tone == .warning,
          "readiness, service names and waiting do not create permission evidence")

    monitor.applyDiscovery(.failed("ordinary failure"))
    check(monitor.networkEvidence == .unverified && monitor.networkEvidence.tone == .warning,
          "ordinary discovery failure is unverified rather than denied")

    monitor.applyDiscovery(.nonLoopbackService("roboRIO-FRC"))
    check(monitor.networkEvidence == .verifiedDiscovery && monitor.networkEvidence.tone == .success,
          "qualifying non-loopback NI discovery becomes green")
    monitor.applyDiscovery(.services([]))
    monitor.applyDiscovery(.failed("later ordinary failure"))
    check(monitor.networkEvidence == .verifiedDiscovery && monitor.networkEvidence.tone == .success,
          "empty results and ordinary failure do not erase existing discovery evidence")

    monitor.applyDiscovery(.policyDenied)
    check(monitor.networkEvidence == .denied && monitor.networkEvidence.tone == .danger,
          "explicit policy denial overrides older discovery success")
    monitor.record(commState: .connected(host: "10.25.90.2"))
    check(monitor.networkEvidence == .denied,
          "a robot connection does not erase an explicit local-network denial")
    monitor.applyDiscovery(.nonLoopbackService("roboRIO-FRC"))
    check(monitor.networkEvidence == .verifiedDiscovery && monitor.networkEvidence.tone == .success,
          "new non-loopback evidence supersedes an older denial")

    monitor.beginNewLaunch()
    check(monitor.networkEvidence == .checking && monitor.firewallEvidence == .notStarted,
          "a new launch clears every previous result")

    monitor.record(commState: .connected(host: "10.25.90.2"))
    check(monitor.networkEvidence == .verifiedRobot && monitor.networkEvidence.tone == .success,
          "a real non-loopback robot connection becomes green")
    monitor.record(commState: .searching)
    check(monitor.networkEvidence == .unverified && monitor.networkEvidence.tone == .warning,
          "losing the robot connection removes robot-green evidence")

    monitor.beginNewLaunch()
    monitor.record(commState: .connected(host: "127.0.0.1"))
    check(monitor.networkEvidence == .loopbackSimulator && monitor.networkEvidence.tone == .warning,
          "a loopback simulator alone cannot verify local network permission")
    monitor.record(commState: .searching)
    check(monitor.networkEvidence == .unverified && monitor.networkEvidence.tone == .warning,
          "searching without other evidence returns to unverified")

    let localSimulator = PermissionRuntimeMonitor(localIPv4Addresses: { ["192.168.3.37"] })
    localSimulator.record(commState: .connected(host: "192.168.3.37"))
    check(localSimulator.networkEvidence == .loopbackSimulator && localSimulator.networkEvidence.tone == .warning,
          "a simulator using this Mac's LAN address is not real robot evidence")

    var currentInterfaces: Set<String> = ["192.168.3.37"]
    let movingSimulator = PermissionRuntimeMonitor(localIPv4Addresses: { currentInterfaces })
    movingSimulator.record(commState: .connected(host: "10.25.90.5"))
    check(movingSimulator.networkEvidence == .verifiedRobot,
          "an address this Mac does not own is still a real robot")
    currentInterfaces.insert("10.25.90.5")
    movingSimulator.beginNewLaunch()
    movingSimulator.record(commState: .connected(host: "10.25.90.5"))
    check(movingSimulator.networkEvidence == .loopbackSimulator && movingSimulator.networkEvidence.tone == .warning,
          "an address this Mac acquires after launch is still this Mac, not a robot")

    monitor.beginNewLaunch()
    monitor.record(commState: .connected(host: "localhost"))
    check(monitor.networkEvidence == .loopbackSimulator && monitor.networkEvidence.tone == .warning,
          "the localhost hostname is also loopback evidence")

    monitor.beginNewLaunch()
    monitor.applyDiscovery(.nonLoopbackService("roboRIO-FRC"))
    monitor.record(commState: .connected(host: "127.0.0.1"))
    check(monitor.networkEvidence == .verifiedDiscovery,
          "loopback simulator evidence does not erase discovery success")

    let url = URL(string: "http://192.0.2.10:6789/verify")!
    monitor.applyFirewallState(.waiting(url))
    check(monitor.firewallEvidence == .waiting(url) && monitor.firewallEvidence.tone == .warning,
          "a listening socket is not firewall success and reads as not verified yet, like the network badge")
    monitor.applyFirewallState(.verified(peer: "192.0.2.20"))
    check(monitor.firewallEvidence == .verified && monitor.firewallEvidence.tone == .success,
          "a valid non-loopback incoming request becomes green")
    monitor.applyFirewallState(.waiting(url))
    check(monitor.firewallEvidence == .verified,
          "a later waiting state does not erase firewall evidence")

    monitor.beginNewLaunch()
    check(monitor.firewallEvidence == .notStarted && monitor.firewallURL == nil,
          "firewall evidence and URL reset on a new launch")
    monitor.applyFirewallState(.timedOut)
    check(monitor.firewallEvidence == .timedOut && monitor.firewallEvidence.tone == .warning,
          "timeout is unverified rather than denied")
    monitor.applyFirewallState(.unavailable)
    check(monitor.firewallEvidence == .unavailable && monitor.firewallEvidence.tone == .warning,
          "no usable address is not a denial")
    monitor.applyFirewallState(.failed)
    check(monitor.firewallEvidence == .failed && monitor.firewallEvidence.tone == .warning,
          "probe failure is not a firewall denial")

    monitor.beginNewLaunch(autoSim: true)
    check(monitor.networkEvidence == .skipped && monitor.firewallEvidence == .skipped &&
          monitor.networkEvidence.tone == .neutral && monitor.firewallEvidence.tone == .neutral,
          "AUTO_SIM explicitly skips both checks; skipped reads as not applicable, never green, for both")

    monitor.beginNewLaunch()
    check(monitor.networkEvidence == .checking && monitor.firewallEvidence == .notStarted,
          "the next normal launch returns to fresh checks")
}
