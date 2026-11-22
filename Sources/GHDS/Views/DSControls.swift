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
    @State private var isOpen = false
    @State private var active: Value?
    @FocusState private var triggerFocused: Bool
    @FocusState private var focusedOption: Value?

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

    private var popoverSize: CGSize {
        let height = min(192, max(44, options.count * 44 + 10))
        return CGSize(width: 240, height: CGFloat(height))
    }

    private var optionList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(options) { option in
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
                        .background(option.value == selection ? DSTheme.segmentTrack : .clear,
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
        .frame(width: popoverSize.width, height: popoverSize.height)
        .background(DSTheme.surface)
        .foregroundStyle(DSTheme.textPrimary)
        .onAppear { focusCurrent() }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.home) { focus(options.first?.value); return .handled }
        .onKeyPress(.end) { focus(options.last?.value); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func open(last: Bool = false) {
        guard !options.isEmpty else { return }
        active = options.contains(where: { $0.value == selection }) ? selection : (last ? options.last?.value : options.first?.value)
        isOpen = true
        DispatchQueue.main.async { focusedOption = active }
    }

    private func focusCurrent() {
        active = selection
        focusedOption = options.contains(where: { $0.value == selection }) ? selection : options.first?.value
    }

    private func move(_ offset: Int) {
        guard !options.isEmpty else { return }
        let index = options.firstIndex(where: { $0.value == (active ?? selection) }) ?? 0
        let next = min(max(index + offset, 0), options.count - 1)
        focus(options[next].value)
    }

    private func focus(_ value: Value?) {
        active = value
        focusedOption = value
    }

    private func choose(_ value: Value) {
        selection = value
        close()
    }

    private func close() {
        isOpen = false
        focusedOption = nil
        triggerFocused = true
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
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(DSTheme.textSecondary)
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel(title)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
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
