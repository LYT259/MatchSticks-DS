import SwiftUI
import DSCore

struct DSSelectOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }

    init(value: Value, label: String) {
        self.value = value
        self.label = label
    }
}

struct DSSelectControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [DSSelectOption<Value>]
    var searchText: ((Value) -> String)? = nil
    @State private var isOpen = false
    @State private var active: Value?
    @State private var query = ""
    @FocusState private var triggerFocused: Bool
    @FocusState private var focusedOption: Value?
    @FocusState private var searchFocused: Bool

    private var filteredOptions: [DSSelectOption<Value>] {
        Self.filter(options: options, query: query, searchText: searchText)
    }

    var body: some View {
        Button {
            open()
        } label: {
            HStack(spacing: 12) {
                Text(selectedLabel)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DSTheme.textSecondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DSSelectTriggerStyle())
        .focused($triggerFocused)
        .accessibilityLabel(title)
        .accessibilityValue(selectedLabel)
        .onKeyPress(.downArrow) { open(); return .handled }
        .onKeyPress(.upArrow) { open(last: true); return .handled }
        .background(DSInstantPopover(isPresented: $isOpen, contentSize: popoverSize) {
            optionList
        })
    }

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? String(describing: selection)
    }

    private var listHeight: CGFloat {
        CGFloat(min(192, max(44, filteredOptions.count * 44 + 10)))
    }

    private var popoverSize: CGSize {
        let width: CGFloat = searchText == nil ? 240 : 320
        let contentHeight = searchText != nil && filteredOptions.isEmpty ? 64 : listHeight
        return CGSize(width: width, height: contentHeight + (searchText == nil ? 0 : 53))
    }

    private var optionList: some View {
        VStack(spacing: 0) {
            if searchText != nil {
                DSSearchField(title: tr("搜索手柄"), text: $query, onCommand: handleSearchCommand)
                    .focused($searchFocused)
                    .padding(10)
                Divider()
            }
            if filteredOptions.isEmpty {
                Text(tr("没有匹配的手柄"))
                    .font(.system(size: 12))
                    .foregroundStyle(DSTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(filteredOptions) { option in
                                Button {
                                    choose(option.value)
                                } label: {
                                    HStack(spacing: 12) {
                                        Text(option.label)
                                            .font(.system(size: 12))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(DSTheme.accentText)
                                            .opacity(option.value == selection ? 1 : 0)
                                            .frame(width: 16)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                                    .background(active == option.value ? DSTheme.hover :
                                                    (option.value == selection ? DSTheme.segmentTrack : .clear),
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(DSSelectOptionStyle())
                                .focused($focusedOption, equals: option.value)
                                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
                            }
                        }
                        .padding(5)
                    }
                    .onChange(of: active) {
                        if let active { proxy.scrollTo(active, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: popoverSize.width, height: popoverSize.height)
        .background(DSTheme.surface)
        .foregroundStyle(DSTheme.textPrimary)
        .onAppear {
            if searchText != nil { searchFocused = true } else { focusCurrent() }
        }
        .onDisappear {
            query = ""
            active = nil
            focusedOption = nil
            searchFocused = false
        }
        .onChange(of: query) {
            active = filteredOptions.contains(where: { $0.value == selection }) ? selection : filteredOptions.first?.value
        }
        .onKeyPress { handleKey($0) }
    }

    static func filter(options: [DSSelectOption<Value>], query: String,
                       searchText: ((Value) -> String)? = nil) -> [DSSelectOption<Value>] {
        guard let searchText else { return options }
        let needle = normalized(query)
        guard !needle.isEmpty else { return options }
        return options.filter { normalized(searchText($0.value)).contains(needle) }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { !$0.isWhitespace }
    }

    private func open(last: Bool = false) {
        guard !options.isEmpty else { return }
        query = ""
        active = filteredOptions.contains(where: { $0.value == selection }) ? selection :
            (last ? filteredOptions.last?.value : filteredOptions.first?.value)
        isOpen = true
        DispatchQueue.main.async {
            if self.searchText != nil { self.searchFocused = true } else { self.focusedOption = self.active }
        }
    }

    private func focusCurrent() {
        active = filteredOptions.contains(where: { $0.value == selection }) ? selection : filteredOptions.first?.value
        focusedOption = active
    }

    private func move(_ offset: Int) {
        guard !filteredOptions.isEmpty else { return }
        let index = filteredOptions.firstIndex(where: { $0.value == (active ?? selection) }) ?? 0
        let next = min(max(index + offset, 0), filteredOptions.count - 1)
        focus(filteredOptions[next].value)
    }

    private func focus(_ value: Value?) {
        active = value
        if searchText == nil { focusedOption = value }
    }

    private func choose(_ value: Value) {
        selection = value
        close()
    }

    private func close() {
        isOpen = false
        query = ""
        active = nil
        focusedOption = nil
        searchFocused = false
        triggerFocused = true
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .downArrow: return handleSearchCommand(.down) ? .handled : .ignored
        case .upArrow: return handleSearchCommand(.up) ? .handled : .ignored
        case .home: return handleSearchCommand(.home) ? .handled : .ignored
        case .end: return handleSearchCommand(.end) ? .handled : .ignored
        case .return: return handleSearchCommand(.confirm) ? .handled : .ignored
        case .escape: return handleSearchCommand(.escape) ? .handled : .ignored
        default: return .ignored
        }
    }

    private func handleSearchCommand(_ command: DSSearchCommand) -> Bool {
        switch command {
        case .down: move(1)
        case .up: move(-1)
        case .home: focus(filteredOptions.first?.value)
        case .end: focus(filteredOptions.last?.value)
        case .confirm:
            guard let active, filteredOptions.contains(where: { $0.value == active }) else { return false }
            choose(active)
        case .escape: close()
        }
        return true
    }
}

private struct DSInstantPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let contentSize: CGSize
    @ViewBuilder let content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, content: content)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ anchor: NSView, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.hostingController.rootView = content
        context.coordinator.popover.contentSize = contentSize
        context.coordinator.sync(isPresented, anchor: anchor)
    }

    static func dismantleNSView(_ anchor: NSView, coordinator: Coordinator) {
        coordinator.popover.delegate = nil
        coordinator.popover.close()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var isPresented: Binding<Bool>
        let hostingController: NSHostingController<Content>
        let popover = NSPopover()

        init(isPresented: Binding<Bool>, content: Content) {
            self.isPresented = isPresented
            hostingController = NSHostingController(rootView: content)
            super.init()
            popover.animates = false
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = hostingController
        }

        func sync(_ presented: Bool, anchor: NSView) {
            if presented {
                guard !popover.isShown, anchor.window != nil else { return }
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            } else if popover.isShown {
                popover.close()
            }
        }

        func popoverDidClose(_ notification: Notification) {
            guard isPresented.wrappedValue else { return }
            DispatchQueue.main.async {
                self.isPresented.wrappedValue = false
            }
        }
    }
}

private struct DSSelectTriggerStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DSTheme.textPrimary)
            .background(configuration.isPressed || hovering ? DSTheme.hover : DSTheme.button,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DSTheme.line))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
    }
}

private struct DSSelectOptionStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering || configuration.isPressed ? DSTheme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

struct DSSegmentedControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [DSSelectOption<Value>]
    var selectedColor: ((Value) -> Color)? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(isSelected && selectedColor != nil ? Color.white : DSTheme.textPrimary)
                        .background(isSelected ? (selectedColor?(option.value) ?? DSTheme.segmentSelected) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: isSelected ? .black.opacity(0.12) : .clear,
                                radius: 1, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DSSegmentButtonStyle(isSelected: isSelected))
                .accessibilityLabel("\(title)，\(option.label)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(DSTheme.segmentTrack, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DSTheme.line))
        .frame(minHeight: 32)
    }
}

private struct DSSegmentButtonStyle: ButtonStyle {
    let isSelected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(!isSelected && (hovering || configuration.isPressed) ? DSTheme.hover.opacity(0.65) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}

struct DSTextFieldStyle: TextFieldStyle {
    @FocusState private var focused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 13))
            .foregroundStyle(DSTheme.textPrimary)
            .textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(minHeight: 32)
            .background(DSTheme.button, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? DSTheme.focusRing : DSTheme.line))
            .focused($focused)
    }
}

struct DSSearchField: View {
    let title: String
    @Binding var text: String
    var onCommand: ((DSSearchCommand) -> Bool)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(DSTheme.textSecondary)
            if let onCommand {
                DSNativeSearchField(title: title, text: $text, focused: $focused, onCommand: onCommand)
            } else {
                TextField(title, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityLabel(title)
                    .focused($focused)
            }
            if !text.isEmpty {
                Button { text = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(DSTheme.textSecondary)
                .help(tr("清除搜索"))
                .accessibilityLabel(tr("清除搜索"))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .frame(minHeight: 32)
        .background(DSTheme.button, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? DSTheme.focusRing : DSTheme.line))
    }
}

enum DSSearchCommand {
    case up, down, home, end, confirm, escape
}

struct DSNativeSearchField: NSViewRepresentable {
    let title: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onCommand: (DSSearchCommand) -> Bool

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onTextChange: (String) -> Void
        var onFocusChange: (Bool) -> Void
        var onCommand: (DSSearchCommand) -> Bool

        init(onTextChange: @escaping (String) -> Void,
             onFocusChange: @escaping (Bool) -> Void,
             onCommand: @escaping (DSSearchCommand) -> Bool) {
            self.onTextChange = onTextChange
            self.onFocusChange = onFocusChange
            self.onCommand = onCommand
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onTextChange(field.stringValue)
        }

        func controlTextDidBeginEditing(_ notification: Notification) { onFocusChange(true) }
        func controlTextDidEndEditing(_ notification: Notification) { onFocusChange(false) }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if selector == Selector(("noop:")), let event = NSApp.currentEvent,
               event.type == .keyDown,
               event.keyCode == 119 || event.keyCode == 124 && event.modifierFlags.contains(.function) {
                return onCommand(.end)
            }
            let commands = [
                "moveUp:": DSSearchCommand.up,
                "moveDown:": .down,
                "moveToBeginningOfDocument:": .home,
                "moveToBeginningOfLine:": .home,
                "moveToBeginningOfParagraph:": .home,
                "scrollToBeginningOfDocument:": .home,
                "moveToEndOfDocument:": .end,
                "moveToEndOfLine:": .end,
                "moveToEndOfParagraph:": .end,
                "scrollToEndOfDocument:": .end,
                "insertNewline:": .confirm,
                "cancelOperation:": .escape,
            ]
            guard let command = commands[selector.description] else { return false }
            return onCommand(command)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: { text = $0 }, onFocusChange: { focused.wrappedValue = $0 }, onCommand: onCommand)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = title
        field.font = .systemFont(ofSize: 12)
        field.textColor = NSColor(DSTheme.textPrimary)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel(title)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onCommand = onCommand
        if field.stringValue != text { field.stringValue = text }
        guard focused.wrappedValue, field.currentEditor() == nil else { return }
        DispatchQueue.main.async {
            guard self.focused.wrappedValue, field.window != nil, field.currentEditor() == nil else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.delegate = nil
    }
}
