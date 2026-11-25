import AppKit
import SwiftUI
import DSCore
import UniformTypeIdentifiers

@MainActor
func joystickCardInteractionTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    joystickCardInteractionCoordinatorTests(check)
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = (try? String(contentsOf: repositoryRoot.appendingPathComponent(
        "Sources/MatchSticksDriverStaion/Views/USBDevicesView.swift"), encoding: .utf8)) ?? ""
    check(!source.isEmpty, "joystick card interaction tests load USBDevicesView source")

    let dragProvider: NSItemProvider = JoystickSlotDrag.provider(uniqueID: "ps4-card:s")
    check(dragProvider is NSPasteboardWriting,
          "the existing slot provider can back an AppKit NSDraggingItem")
    if let writer = dragProvider as? NSPasteboardWriting {
        let privateType = NSPasteboard.PasteboardType(JoystickSlotDrag.typeIdentifier)
        let types = writer.writableTypes(for: NSPasteboard(name: .drag))
        check(types.contains(privateType) && types.contains(NSPasteboard.PasteboardType(UTType.data.identifier)),
              "the AppKit drag writer preserves private UTI and public.data types")
        check(writer.pasteboardPropertyList(forType: privateType) as? Data == Data("ps4-card:s".utf8),
              "the AppKit drag writer carries the same uniqueID payload")
    }

    check(source.contains("model.joystickSlots.first { $0.index == index }"),
          "summary grid resolves cards by physical slot index")
    check(source.contains("JoystickCard(model: model, index: slot.index, slot: slot)"),
          "detail cards display and target their physical slot index")
    check(!source.contains("ForEach(Array(model.joystickSlots.enumerated())"),
          "detail identity no longer depends on compact-array position")
    check(source.contains("model.joystickSlots.first { $0.uniqueID == uniqueID }?.index"),
          "drop resolves uniqueID to the physical source slot index")
    check(source.contains("drop(providers, at: index)") &&
          !source.contains("min(index, model.joystickSlots.count)"),
          "drop passes the original card index to the sparse-slot model")

    check(source.contains("拖到空闲卡即占据该槽位"),
          "empty-card copy says a drop occupies that slot")
    check(source.contains("if !model.joystickSlots.isEmpty {"),
          "slot-drag guidance is also visible with one controller")

    let handleStart = source.range(of: "private struct SlotDragHandle")
    let handleTail = handleStart.map { String(source[$0.lowerBound...]) } ?? ""
    let handle = handleTail.components(separatedBy: "struct JoystickCard").first ?? ""
    check(!handle.isEmpty, "drag handle remains as a visual affordance")
    check(handle.contains(".allowsHitTesting(false)") && !handle.contains(".onDrag"),
          "drag handle has no additional pointer target or drag source")
    check(handle.contains(".foregroundStyle(DSTheme.textSecondary)") &&
          !handle.contains("hovering") && !handle.contains("DSTheme.accent"),
          "drag handle keeps secondary text and never turns accent blue on hover")
    check(handle.contains(".background(.clear") && !handle.contains("DSTheme.card"),
          "drag handle background stays transparent on hover")

    check(source.contains("NSViewRepresentable") && source.contains("beginDraggingSession") &&
          source.contains("JoystickSlotDrag.provider(uniqueID: slot.uniqueID)"),
          "summary cards own a full-card AppKit drag session using the existing payload provider")
    check(source.contains("reader.scrollTo(slot.id, anchor: .top)"),
          "a non-drag release retains the summary-card scroll action")
    check(source.contains(".accessibilityLabel(tr(\"槽位 %d，%@\", index, title))"),
          "summary cards retain their accessibility button label")

    NSApplication.shared.finishLaunching()
    let previousPolicy = NSApplication.shared.activationPolicy()
    NSApplication.shared.setActivationPolicy(.accessory)
    defer { NSApplication.shared.setActivationPolicy(previousPolicy) }

    final class OnePS4Feed {
        var devices: [HIDDeviceSnapshot] {
            [HIDDeviceSnapshot(uniqueID: "ps4-card:s", name: "Wireless Controller",
                              vendorID: 0x054C, productID: 0x05C4,
                              axes: [0], axisUsages: [0x30], buttons: 0, buttonCount: 14, povs: [-1],
                              isXbox: false, mode: .directInput,
                              polarity: GamepadStickPolarity(xRightIsNegative: false, yUpIsNegative: false),
                              usbLocationID: nil)]
        }
    }
    let model = DSModel()
    let feed = OnePS4Feed()
    model.hidPoller = { feed.devices }
    model.pollAndPublishSnapshot()
    check(model.joystickSlots.count == 1 && model.joystickSlots[0].uniqueID == "ps4-card:s",
          "single PS4 is available for the hosted interaction test")

    let host = NSHostingView(rootView: USBDevicesView(model: model))
    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1_000, height: 360),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    defer { window.close() }

    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
    let views = descendants(host)
    guard let interaction = views.first(where: { $0.identifier?.rawValue == "joystick-card-interaction-0" }),
          let scrollView = views.compactMap({ $0 as? NSScrollView }).first else {
        check(false, "occupied summary card exposes a full-size interaction view inside the scroll view")
        return
    }
    check(!views.contains { $0.identifier?.rawValue == "joystick-card-interaction-1" },
          "empty summary cards are drop targets only")

    let center = interaction.convert(NSPoint(x: interaction.bounds.midX, y: interaction.bounds.midY), to: nil)
    let hostPoint = host.convert(center, from: nil)
    let hitPoint = host.superview.map { host.convert(hostPoint, to: $0) } ?? hostPoint
    let hit = host.hitTest(hitPoint)
    check(hit === interaction || hit.map { descendants(interaction).contains($0) } == true,
          "the card-center hit resolves to the full-card interaction layer")
    check(interaction.bounds.width > 100 && interaction.bounds.height > 50,
          "the interaction layer spans the summary card rather than its drag handle")

    let originBefore = scrollView.contentView.bounds.origin.y
    let timestamp = ProcessInfo.processInfo.systemUptime
    if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: center, modifierFlags: [],
                                     timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                                     eventNumber: 0, clickCount: 1, pressure: 1),
       let up = NSEvent.mouseEvent(with: .leftMouseUp, location: center, modifierFlags: [],
                                   timestamp: timestamp + 0.02, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 1, clickCount: 1, pressure: 0) {
        interaction.mouseDown(with: down)
        interaction.mouseUp(with: up)
        settle()
    } else {
        check(false, "summary-card click events are created")
    }
    check(scrollView.contentView.bounds.origin.y > originBefore,
          "a light card click scrolls to its detail card")
    check(model.joystickSlots.map(\.uniqueID) == ["ps4-card:s"] && model.joystickSlots[0].index == 0,
          "a light card click never moves the controller")
}

@MainActor
private func joystickCardInteractionCoordinatorTests(_ check: (@autoclosure () -> Bool, String) -> Void) {
    var clicks = 0
    let coordinator = JoystickCardInteractionCoordinator(onClick: { clicks += 1 })

    coordinator.mouseDown(at: .zero)
    coordinator.mouseUp(at: .zero)
    check(clicks == 1, "a stationary press and release performs one click")

    coordinator.mouseDown(at: .zero)
    var smallDrags = 0
    let smallStarted = coordinator.mouseDragged(at: NSPoint(x: 2, y: 2),
                                                startingDrag: { smallDrags += 1; return true })
    coordinator.mouseUp(at: NSPoint(x: 2, y: 2))
    check(!smallStarted && smallDrags == 0 && clicks == 2,
          "movement below the drag threshold keeps click behavior")

    coordinator.mouseDown(at: .zero)
    var dragStarts = 0
    let dragStarted = coordinator.mouseDragged(at: NSPoint(x: 8, y: 6), startingDrag: {
        dragStarts += 1
        return true
    })
    _ = coordinator.mouseDragged(at: NSPoint(x: 12, y: 8), startingDrag: {
        dragStarts += 1
        return true
    })
    coordinator.mouseUp(at: NSPoint(x: 12, y: 8))
    check(dragStarted && dragStarts == 1 && clicks == 2,
          "crossing the threshold starts exactly one drag and consumes the release")

    coordinator.mouseDown(at: .zero)
    _ = coordinator.mouseDragged(at: NSPoint(x: 8, y: 6), startingDrag: { true })
    coordinator.dragEnded()
    coordinator.mouseUp(at: NSPoint(x: 8, y: 6))
    check(clicks == 2, "a cancelled or ended drag never falls through to click")
    coordinator.mouseDown(at: .zero)
    coordinator.mouseUp(at: .zero)
    check(clicks == 3, "the next new press works normally after a cancelled drag")

    coordinator.mouseDown(at: .zero)
    _ = coordinator.mouseDragged(at: NSPoint(x: 8, y: 6), startingDrag: { false })
    coordinator.mouseUp(at: NSPoint(x: 8, y: 6))
    check(clicks == 3, "a failed drag-session start also consumes the release")

    let untrackedStarts = coordinator.mouseDragged(at: .zero, startingDrag: { true })
    coordinator.mouseUp(at: .zero)
    check(!untrackedStarts && clicks == 3, "events without a preceding mouse-down cannot click or drag")
}
