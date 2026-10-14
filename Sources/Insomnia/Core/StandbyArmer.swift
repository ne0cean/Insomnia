import CoreWLAN
import Foundation

/// Holds sleep *before* the lid closes, so the close itself has nothing to
/// do but count down. Auto-start on lid close alone cannot work without a
/// dock: powerd commits the sleep 1-3 s after the hinge closes (16 s with
/// external displays detaching), and the start path, slowed 10-30x by the
/// sleep transition, reached `pmset disablesleep 1` 45 s after the close on
/// 2026-10-13. So with `Config.standbyBeforeLidClose` on, and no session
/// running, a *standby session* of `Config.effectiveStandbyDuration`
/// starts on the two signs that the Mac is about to be closed and carried:
///
/// - the charger (or dock) is unplugged while the lid is open;
/// - the configured hotspot comes into Wi-Fi range while on battery with
///   the lid open, which is the phone being readied for the trip.
///
/// A standby session is an ordinary session (journal, backstop, lid-close
/// actions, failover all apply) that `IdleLidWatcher` extends to
/// `Config.effectiveAutoStartDuration` on the lid close. If the lid stays
/// open it ends on its own deadline without a notification, and sleep is
/// back to normal. Between sessions this watcher owns a `PowerMonitor` of
/// its own (`AppServices` runs one only during a session) and, while on
/// battery, a directed scan for the hotspot SSID every `scanInterval`.
@MainActor
final class StandbyArmer {
    /// Whether the hotspot named is in range now. The app's scanner asks
    /// CoreWLAN; tests answer from a flag.
    typealias HotspotScan = @Sendable (_ ssid: String) async -> Bool

    static let scanInterval: Duration = .seconds(20)

    private weak var manager: SessionManager?
    private let power: PowerMonitor
    private let lidClosed: @Sendable () -> Bool?
    private let scan: HotspotScan
    private let scanInterval: Duration
    private var wasCharging: Bool?
    /// The hotspot was in range at the last scan that ran. Standby arms on
    /// the edge (not seen, then seen), as the charger path arms on the
    /// unplug: a hotspot left on at the desk must not re-arm standby every
    /// scan after the previous one ran out.
    private var hotspotSeen = false
    private var scanLoop: Task<Void, Never>?
    private(set) var lastArmedFor: String?

    init(
        manager: SessionManager,
        power: PowerMonitor = PowerMonitor(),
        lidClosed: @escaping @Sendable () -> Bool? = LidObserver.readClamshellState,
        scan: @escaping HotspotScan = StandbyArmer.hotspotVisible,
        scanInterval: Duration = StandbyArmer.scanInterval
    ) {
        self.manager = manager
        self.power = power
        self.lidClosed = lidClosed
        self.scan = scan
        self.scanInterval = scanInterval
    }

    /// Pure: whether standby applies at all right now: the setting and
    /// auto-start on, no session, and the lid not known to be closed.
    nonisolated static func applies(config: Config, active: Bool, lidClosed: Bool?) -> Bool {
        config.standbyBeforeLidClose && config.autoStartOnLidClose && !active && lidClosed != true
    }

    /// Pure: whether a charger reading arms standby: the charger was
    /// connected at the previous reading and is not now.
    nonisolated static func unplugArms(config: Config, active: Bool, lidClosed: Bool?, wasCharging: Bool?, charging: Bool) -> Bool {
        applies(config: config, active: active, lidClosed: lidClosed) && wasCharging == true && !charging
    }

    /// Pure: whether the hotspot scan runs: standby applies, the Mac is on
    /// battery and a hotspot SSID is configured.
    nonisolated static func scans(config: Config, active: Bool, lidClosed: Bool?, charging: Bool) -> Bool {
        applies(config: config, active: active, lidClosed: lidClosed) && !charging
            && !HotspotSSID.normalized(config.hotspotSSID).isEmpty
    }

    /// Pure: whether the battery allows a standby to start. At or below the
    /// end floor the floor rules would end it at once, with a notification
    /// each time; nil (no reading) does not block.
    nonisolated static func batteryAllows(config: Config, percent: Int?) -> Bool {
        guard config.endFloor > 0, let percent else { return true }
        return percent > config.endFloor
    }

    func start() {
        power.onChange = { [weak self] in self?.powerChanged() }
        power.start()
        wasCharging = power.isCharging
        scanLoop?.cancel()
        scanLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.scanInterval ?? .seconds(20))
                guard !Task.isCancelled, let self else { return }
                await self.scanOnce()
            }
        }
    }

    func stop() {
        scanLoop?.cancel()
        scanLoop = nil
        power.stop()
        power.onChange = nil
    }

    /// Internal so a test can deliver a charger change.
    func powerChanged() {
        let charging = power.isCharging
        defer { wasCharging = charging }
        guard let manager else { return }
        guard Self.unplugArms(config: manager.config, active: manager.isActive, lidClosed: lidClosed(), wasCharging: wasCharging, charging: charging) else { return }
        arm("the charger was unplugged")
    }

    /// Internal so a test can run one scan.
    func scanOnce() async {
        guard let manager else { return }
        let config = manager.config
        guard Self.scans(config: config, active: manager.isActive, lidClosed: lidClosed(), charging: power.isCharging) else { return }
        let ssid = HotspotSSID.normalized(config.hotspotSSID)
        let visible = await scan(ssid)
        let appeared = visible && !hotspotSeen
        hotspotSeen = visible
        guard appeared else { return }
        // Re-read after the await: a session may have started meanwhile.
        guard let manager = self.manager, Self.applies(config: manager.config, active: manager.isActive, lidClosed: lidClosed()) else { return }
        arm("hotspot \(ssid) came into range")
    }

    private func arm(_ reason: String) {
        guard let manager else { return }
        guard Self.batteryAllows(config: manager.config, percent: power.percent) else {
            Log.info("standby: \(reason), but the battery is at or below the end floor; not holding sleep")
            return
        }
        let duration = manager.config.effectiveStandbyDuration
        lastArmedFor = reason
        Log.info("standby: \(reason); holding sleep for \(Int(duration)) s ahead of the lid close")
        Task { @MainActor in
            await manager.startStandby(duration: duration)
            if !manager.isActive { Log.error("standby: the session did not start") }
        }
    }

    /// A directed CoreWLAN scan for `ssid`: non-empty means in range. The
    /// SSID filter keeps it to one network, and the result counts even
    /// when macOS redacts the names for want of Location Services.
    static func hotspotVisible(_ ssid: String) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let interface = CWWiFiClient.shared().interface() else { return false }
            guard let found = try? interface.scanForNetworks(withSSID: ssid.data(using: .utf8)) else { return false }
            return !found.isEmpty
        }.value
    }
}
