import Foundation

enum GamepadDeviceCatalog {
    static func merged(hid: [HIDDeviceSnapshot], xinput: [HIDDeviceSnapshot]) -> [HIDDeviceSnapshot] {
        let xinputLocations = Set(xinput.compactMap(\.usbLocationID))
        let filteredHID = hid.filter { device in
            guard let location = device.usbLocationID else { return true }
            return !xinputLocations.contains(location)
        }
        return filteredHID + xinput
    }
}

@MainActor
final class GamepadInputManager {
    static let shared = GamepadInputManager()

    var onDevicesChanged: (() -> Void)?
    var onError: ((String) -> Void)? {
        didSet { F310XInputManager.shared.onError = onError }
    }

    func start() {
        HIDInputManager.shared.onDevicesChanged = { [weak self] in
            self?.onDevicesChanged?()
        }
        F310XInputManager.shared.onDevicesChanged = { [weak self] in
            self?.onDevicesChanged?()
        }
        F310XInputManager.shared.onError = onError
        HIDInputManager.shared.start()
        F310XInputManager.shared.start()
    }

    func pollAll() -> [HIDDeviceSnapshot] {
        GamepadDeviceCatalog.merged(
            hid: HIDInputManager.shared.pollAll(),
            xinput: F310XInputManager.shared.pollAll())
    }
}
