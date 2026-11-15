import SwiftUI

/// Monitor Contrast on a display card: the monitor's own contrast (VCP 0x12),
/// shown only once the probe confirmed the monitor answers it. Unlike Image
/// Adjustment's contrast, this changes the panel itself, the same setting as the
/// monitor's OSD, so it costs no gamma range. Writes go through ContrastService's
/// coalesced writer.
struct MonitorContrastBlock: View {
    @ObservedObject var display: DisplayInfo

    var body: some View {
        if display.contrastSupported {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    MenuItemIcon(systemName: "circle.lefthalf.filled", color: .blue, active: false)
                        .accessibilityHidden(true)
                    Text("Monitor Contrast")
                        .font(.body)
                    Spacer()
                    Text(verbatim: "\(Int(display.contrast.rounded()))")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundColor(.secondaryReadable)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                ContrastSliderView(display: display)
            }
        }
    }
}

struct ContrastSliderView: View {
    @ObservedObject var display: DisplayInfo
    /// Extra leading inset: 26 under the card's labeled row, 0 under the header sliders.
    var leadingInset: CGFloat = 26
    @State private var localContrast: Double = 0
    @State private var isDragging: Bool = false

    /// Change per tap of the step buttons, matching the brightness keys' step.
    private let contrastStep: Double = 100.0 / 16.0

    var body: some View {
        HStack(spacing: 8) {
            BrightnessStepButton(systemName: "circle.lefthalf.filled") { step(-contrastStep) }

            Slider(value: $localContrast, in: 0...100) { editing in
                isDragging = editing
                if !editing {
                    ContrastService.shared.setContrast(localContrast, for: display)
                }
            }
            .controlSize(SystemLook.isMacOS27OrLater ? .regular : .small)
            .accessibilityLabel("Monitor contrast")
            .accessibilityValue("\(Int(localContrast))%")
            .onChange(of: localContrast) { _, newValue in
                guard isDragging else { return }
                ContrastService.shared.setContrast(newValue, for: display)
            }

            BrightnessStepButton(systemName: "circle.righthalf.filled") { step(contrastStep) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .padding(.leading, leadingInset)
        .task(id: display.displayID) { localContrast = display.contrast }
        .onChange(of: display.contrast) { _, newValue in
            // External change (a probe adopting the OSD level, a step button).
            if !isDragging && abs(newValue - localContrast) >= 0.1 {
                localContrast = newValue
            }
        }
    }

    private func step(_ delta: Double) {
        ContrastService.shared.setContrast(display.contrast + delta, for: display)
    }
}
