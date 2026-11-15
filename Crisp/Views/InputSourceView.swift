import SwiftUI
import AppKit

// The Input row on a display card (#196): which input the monitor shows, and a
// checkmark list to switch it. Switching away disconnects the display, so the way
// back is its Reconnect row (InputSwitchService).

private func inputLabel(_ value: UInt16) -> String {
    DDCInputSource.name(for: value) ?? String(localized: "Input \(String(format: "0x%02X", value))")
}

/// Short names for the main panel's input pills, which get about a third of the
/// panel's width each; the card's list keeps the full names.
private func shortInputLabel(_ value: UInt16) -> String {
    switch value {
    case 0x0F: "DP"
    case 0x10: "DP 2"
    case 0x11: "HDMI"
    case 0x12: "HDMI 2"
    case 0x19: "TB"
    case 0x1B: "USB-C"
    default: String(format: "0x%02X", value)
    }
}

struct InputHeadBlock: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject var state: PanelSectionState
    @ObservedObject private var service = InputSwitchService.shared

    var body: some View {
        Group {
            if service.isAvailable(for: display) {
                ExpandableRow(
                    icon: "cable.connector",
                    iconActive: false,
                    label: "Input",
                    subtitle: service.macInput[display.displayUUID].map(inputLabel),
                    isExpanded: state.openBinding(\.inputOpenIDs, display.displayID)
                )
            }
        }
        .task { await service.refreshInput(display) }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidOpen)) { _ in
            Task { await service.refreshInput(display) }
        }
    }
}

struct InputBodyBlock: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject var state: PanelSectionState
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var service = InputSwitchService.shared
    @State private var pending: UInt16?
    @State private var message: String?
    @State private var showShortcuts = false

    private var uuid: String { display.displayUUID }
    private var isOpen: Bool { state.inputOpenIDs.contains(display.displayID) }

    var body: some View {
        if service.isAvailable(for: display) { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if service.reading.contains(uuid) {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    Text("Reading the inputs from the monitor…")
                }
                .caption()
            }

            ForEach(service.options(for: display), id: \.self) { value in
                CheckmarkRow(
                    label: inputLabel(value),
                    isSelected: service.macInput[uuid] == value,
                    isPending: pending == value
                ) { choose(value) }
            }

            if service.macInput[uuid] == nil {
                Text("Crisp could not read which input this Mac is on. Choose it once.").caption()
            } else if PhysicalDisplayToggleService.shared.wouldLeaveNoActiveDisplay(display.displayID) {
                Text("This is the only display, so it stays connected while it shows the other input.").caption()
            } else {
                Text("Another input disconnects this display. Reconnect it here to switch back.").caption()
            }
            if service.markedByUser.contains(uuid) {
                Button("Choose Again") { service.forgetMark(for: display) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.leading, 24)
                    .padding(.bottom, 4)
            }

            if let message {
                Text(message).caption().foregroundColor(.red)
            }

            shortcuts
        }
        .onChange(of: isOpen) { _, open in
            if open { Task { await service.readListIfNeeded(display) } }
        }
    }

    /// One recorder per input: a KVM key per computer. Folded away by default so the
    /// list stays a list. Run Crisp on each computer and give each its own key for the
    /// other input; on this Mac, the key for its own input also reconnects the monitor.
    @ViewBuilder private var shortcuts: some View {
        let any = service.shortcuts.contains { $0.uuid == uuid }
        let title: LocalizedStringKey = showShortcuts ? "Hide Keyboard Shortcuts"
            : (any ? "Edit Keyboard Shortcuts" : "Add Keyboard Shortcuts")
        Button(title) {
            showShortcuts.toggle()
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.leading, 24)
        .padding(.vertical, 3)
        if showShortcuts {
            ForEach(service.options(for: display), id: \.self) { value in
                ShortcutRecorderRow(
                    label: inputLabel(value),
                    shortcut: Binding(
                        get: { service.shortcut(for: display, input: value) },
                        set: { service.setShortcut($0, for: display, input: value) }
                    ),
                    leadingInset: 12
                )
            }
            Text("Switches this monitor to that input from anywhere. Set one on each computer.").caption()
        }
    }

    private func choose(_ value: UInt16) {
        guard pending == nil else { return }
        guard service.macInput[uuid] != nil else {
            service.mark(value, for: display)
            return
        }
        pending = value
        Task { @MainActor in
            let result = await service.switchInput(display, to: value)
            pending = nil
            displayManager.refreshDisplays()
            if case .failure(let error) = result { show(error.description) }
        }
    }

    private func show(_ text: String) {
        message = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if message == text { message = nil }
        }
    }
}

private extension View {
    func caption() -> some View {
        font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 24)
            .padding(.trailing, 12)
            .padding(.vertical, 3)
    }
}

/// One-tap input buttons under a display's sliders: the KVM switch without opening
/// the card. Shows the inputs the monitor lists (read once, then kept), plus the one
/// this Mac is on, minus any hidden from the row's context menu. Tapping another
/// input switches the monitor and its USB hub to it.
struct QuickInputRow: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var service = InputSwitchService.shared
    @State private var pending: UInt16?
    @State private var failed: UInt16?

    private var uuid: String { display.displayUUID }

    /// The monitor's own list once read; until then only this Mac's input, so the
    /// generic list (which can miss a monitor's own codes) never shows.
    private var allOptions: [UInt16] {
        var values = service.listed[uuid] ?? []
        if let mine = service.macInput[uuid], !values.contains(mine) { values.insert(mine, at: 0) }
        return values
    }

    /// What the row shows: the current input always, others unless hidden.
    private var options: [UInt16] {
        let mine = service.macInput[uuid]
        return allOptions.filter { $0 == mine || !service.isHidden($0, for: display) }
    }

    var body: some View {
        if service.isAvailable(for: display) {
            HStack(spacing: 8) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                if service.reading.contains(uuid) && options.count < 2 {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    Text("Reading the inputs from the monitor…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                ForEach(options, id: \.self) { value in
                    inputButton(value)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contextMenu { hideMenu }
            .task { await service.settle(display) }
        }
    }

    /// Right-click the row: show or hide each input the monitor lists. The current
    /// input can't be hidden, so the row is never empty.
    @ViewBuilder private var hideMenu: some View {
        ForEach(allOptions, id: \.self) { value in
            Toggle(inputLabel(value), isOn: Binding(
                get: { !service.isHidden(value, for: display) },
                set: { service.setHidden(!$0, value: value, for: display) }
            ))
            .disabled(service.macInput[uuid] == value)
        }
    }

    private func inputButton(_ value: UInt16) -> some View {
        let isCurrent = service.macInput[uuid] == value
        let fill: Color = isCurrent ? .accentColor
            : (failed == value ? Color.red.opacity(0.3) : Color.primary.opacity(0.08))
        return Button {
            choose(value)
        } label: {
            HStack(spacing: 4) {
                if pending == value {
                    ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                }
                Text(verbatim: shortInputLabel(value))
                    .font(.callout)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill))
            .foregroundColor(isCurrent ? .white : .primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Not .disabled for the current input: that greys the pill out, and it
        // should read as selected. A tap on it does nothing instead.
        .allowsHitTesting(!isCurrent && pending == nil)
        .accessibilityLabel(inputLabel(value))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func choose(_ value: UInt16) {
        guard pending == nil, service.macInput[uuid] != value else { return }
        guard service.macInput[uuid] != nil else {
            service.mark(value, for: display)
            return
        }
        pending = value
        failed = nil
        Task { @MainActor in
            let result = await service.switchInput(display, to: value)
            pending = nil
            displayManager.refreshDisplays()
            if case .failure = result {
                failed = value
                NSSound.beep()
            }
        }
    }
}
