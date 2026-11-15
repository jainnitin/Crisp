import Foundation
import CoreGraphics
import os.log

/// The monitor's own contrast over DDC/CI (VCP 0x12), next to Image Adjustment's
/// software contrast, which only reshapes the gamma table. Probe, then a coalesced
/// writer paced like VolumeService, since both share the I2C bus with brightness.
@MainActor
final class ContrastService {
    static let shared = ContrastService()
    private init() {}

    private static let log = Logger(subsystem: "com.crisp.app", category: "contrast")

    /// DDC max contrast per display (usually 100), from the probe read.
    private var ddcMax: [CGDirectDisplayID: UInt16] = [:]

    /// UUIDs of displays that have ever answered a 0x12 read: a hardware fact, so a
    /// flaky launch-time probe can't hide the slider again (same reason as volume).
    private let capableKey = "crisp.contrastCapableDisplays"
    private lazy var rememberedCapable: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: capableKey) ?? [])

    /// Latest pending percent per display; only one DDC write in flight each.
    private var pending: [CGDirectDisplayID: Double] = [:]
    private var pumpActive: Set<CGDirectDisplayID> = []

    /// Drops per-display state for a disconnected display so a reused displayID
    /// cannot inherit it. rememberedCapable is UUID-keyed and stays.
    func invalidate(for displayID: CGDirectDisplayID) {
        ddcMax.removeValue(forKey: displayID)
        pending.removeValue(forKey: displayID)
    }

    /// Reads VCP 0x12 once: success shows the slider and adopts the monitor's level.
    /// Safe to re-run; a monitor answering late heals on the next pass.
    func refreshContrast(for display: DisplayInfo) {
        guard !display.isBuiltin, !display.hasNativeBrightness else { return }
        if rememberedCapable.contains(display.displayUUID) { display.contrastSupported = true }
        let id = display.displayID
        let uuid = display.displayUUID
        DDCService.shared.readAsync(displayID: id, command: DDCService.contrastVCP) { result in
            Task { @MainActor in
                guard let result else { return }
                // A monitor that reports max 0 has no scale for 0x12: treat it as 100.
                let contrastMax = result.max > 0 ? result.max : 100
                self.ddcMax[id] = contrastMax
                display.contrastSupported = true
                if self.rememberedCapable.insert(uuid).inserted {
                    UserDefaults.standard.set(Array(self.rememberedCapable), forKey: self.capableKey)
                    Self.log.notice("\(display.name, privacy: .public): contrast probe ok \(result.current, privacy: .public)/\(contrastMax, privacy: .public), slider shown")
                }
                // Adopt the hardware level only while our writer is idle, so a stale
                // cached read never fights an in-flight drag.
                if self.pending[id] == nil, !self.pumpActive.contains(id) {
                    display.contrast = min(100, Double(result.current) / Double(contrastMax) * 100.0)
                }
            }
        }
    }

    /// Sets the monitor's contrast (0–100). Latest value wins; writes are paced to
    /// the MCCS ~50 ms spacing so a drag doesn't flood the bus.
    func setContrast(_ percent: Double, for display: DisplayInfo) {
        let clamped = max(0.0, min(100.0, percent))
        display.contrast = clamped
        pending[display.displayID] = clamped
        pump(for: display.displayID)
    }

    private func pump(for id: CGDirectDisplayID) {
        guard !pumpActive.contains(id), let percent = pending.removeValue(forKey: id) else { return }
        pumpActive.insert(id)
        let raw = UInt16((percent / 100.0 * Double(ddcMax[id] ?? 100)).rounded())
        DDCService.shared.writeAsync(displayID: id, command: DDCService.contrastVCP, value: raw) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)  // MCCS write spacing
                self.pumpActive.remove(id)
                self.pump(for: id)
            }
        }
    }
}
