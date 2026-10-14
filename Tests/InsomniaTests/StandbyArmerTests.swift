import XCTest
@testable import Insomnia

/// Standby ahead of the lid close. The armer's power monitor is never
/// started (nothing registers with IOKit): the test moves a fake reading
/// and calls `powerChanged` / `scanOnce` as the events would.
@MainActor
final class StandbyArmerTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    private final class Reading: @unchecked Sendable {
        private let lock = NSLock()
        private var _charging = true
        var charging: Bool {
            get { lock.withLock { _charging } }
            set { lock.withLock { _charging = newValue } }
        }
    }

    private final class HotspotRange: @unchecked Sendable {
        private let lock = NSLock()
        private var _visible = false
        private(set) var asked: [String] = []
        var visible: Bool {
            get { lock.withLock { _visible } }
            set { lock.withLock { _visible = newValue } }
        }
        func scan(_ ssid: String) -> Bool { lock.withLock { asked.append(ssid); return _visible } }
    }

    private func configOn() -> Config {
        var c = Config()
        c.autoStartOnLidClose = true
        c.standbyBeforeLidClose = true
        c.hotspotSSID = "The blade"
        return c
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), what)
    }

    // MARK: Pure decisions

    func testAppliesNeedsBothSettingsNoSessionAndAnOpenLid() {
        let on = configOn()
        XCTAssertTrue(StandbyArmer.applies(config: on, active: false, lidClosed: false))
        XCTAssertTrue(StandbyArmer.applies(config: on, active: false, lidClosed: nil), "a desktop with no lid reading is not excluded")
        XCTAssertFalse(StandbyArmer.applies(config: on, active: true, lidClosed: false), "a running session is left alone")
        XCTAssertFalse(StandbyArmer.applies(config: on, active: false, lidClosed: true), "already closed: too late, and nothing to pre-empt")
        var noAuto = on
        noAuto.autoStartOnLidClose = false
        XCTAssertFalse(StandbyArmer.applies(config: noAuto, active: false, lidClosed: false), "standby serves auto-start")
        XCTAssertFalse(StandbyArmer.applies(config: Config(), active: false, lidClosed: false), "off by default")
    }

    func testUnplugArmsOnlyOnTheTransitionOffTheCharger() {
        let on = configOn()
        XCTAssertTrue(StandbyArmer.unplugArms(config: on, active: false, lidClosed: false, wasCharging: true, charging: false))
        XCTAssertFalse(StandbyArmer.unplugArms(config: on, active: false, lidClosed: false, wasCharging: false, charging: false), "already on battery")
        XCTAssertFalse(StandbyArmer.unplugArms(config: on, active: false, lidClosed: false, wasCharging: nil, charging: false), "first reading")
        XCTAssertFalse(StandbyArmer.unplugArms(config: on, active: false, lidClosed: false, wasCharging: true, charging: true))
    }

    func testScansOnlyOnBatteryWithAHotspotConfigured() {
        let on = configOn()
        XCTAssertTrue(StandbyArmer.scans(config: on, active: false, lidClosed: false, charging: false))
        XCTAssertFalse(StandbyArmer.scans(config: on, active: false, lidClosed: false, charging: true), "on the charger the unplug arms it")
        var noHotspot = on
        noHotspot.hotspotSSID = "  "
        XCTAssertFalse(StandbyArmer.scans(config: noHotspot, active: false, lidClosed: false, charging: false))
        XCTAssertFalse(StandbyArmer.scans(config: on, active: true, lidClosed: false, charging: false))
    }

    // MARK: With a manager

    func testUnplugStartsAStandbySessionOfTheStandbyDuration() async {
        let m = h.makeManager()
        m.config = configOn()
        m.config.standbyDuration = 20 * 60
        let reading = Reading()
        let power = PowerMonitor(reader: { (.percent(80), reading.charging) })
        power.refreshBattery()
        let range = HotspotRange()
        let armer = StandbyArmer(manager: m, power: power, lidClosed: { false }, scan: { range.scan($0) })
        armer.powerChanged()
        XCTAssertFalse(m.isActive, "the first reading only records the charger state")

        reading.charging = false
        power.refreshBattery()
        armer.powerChanged()
        await waitUntil("no standby session started") { m.isActive }
        XCTAssertTrue(m.standby)
        XCTAssertEqual(m.session.map { $0.endsAt.timeIntervalSince($0.startedAt) }, 20 * 60)
        XCTAssertEqual(armer.lastArmedFor, "the charger was unplugged")

        // Plugging back in and unplugging again while the standby runs
        // starts nothing more.
        reading.charging = true
        power.refreshBattery()
        armer.powerChanged()
        reading.charging = false
        power.refreshBattery()
        armer.powerChanged()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(m.session?.extensions, [])
        _ = await m.end(reason: .user)
    }

    func testUnplugWithTheLidClosedOrStandbyOffStartsNothing() async throws {
        let m = h.makeManager()
        m.config = configOn()
        let reading = Reading()
        let power = PowerMonitor(reader: { (.percent(80), reading.charging) })
        power.refreshBattery()
        let closed = StandbyArmer(manager: m, power: power, lidClosed: { true }, scan: { _ in false })
        closed.powerChanged()
        reading.charging = false
        power.refreshBattery()
        closed.powerChanged()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(m.isActive, "a lid already closed is past standby")

        m.config.standbyBeforeLidClose = false
        reading.charging = true
        power.refreshBattery()
        let off = StandbyArmer(manager: m, power: power, lidClosed: { false }, scan: { _ in false })
        off.powerChanged()
        reading.charging = false
        power.refreshBattery()
        off.powerChanged()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(m.isActive, "off by setting")
    }

    func testHotspotInRangeOnBatteryStartsAStandbySession() async throws {
        let m = h.makeManager()
        m.config = configOn()
        let reading = Reading()
        reading.charging = false
        let power = PowerMonitor(reader: { (.percent(80), reading.charging) })
        power.refreshBattery()
        let range = HotspotRange()
        let armer = StandbyArmer(manager: m, power: power, lidClosed: { false }, scan: { range.scan($0) })

        await armer.scanOnce()
        XCTAssertEqual(range.asked, ["The blade"], "the scan is directed at the configured SSID")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(m.isActive, "out of range")

        range.visible = true
        await armer.scanOnce()
        await waitUntil("no standby session started") { m.isActive }
        XCTAssertTrue(m.standby)
        XCTAssertEqual(armer.lastArmedFor, "hotspot The blade came into range")

        // With a session running the scan is skipped altogether.
        await armer.scanOnce()
        XCTAssertEqual(range.asked.count, 2)
        _ = await m.end(reason: .user)

        // A hotspot left on does not re-arm standby after that session: it
        // has to go out of range and come back (the edge, as for the charger).
        await armer.scanOnce()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(m.isActive, "re-armed on a hotspot that never went away")
        range.visible = false
        await armer.scanOnce()
        range.visible = true
        await armer.scanOnce()
        await waitUntil("the hotspot coming back did not arm") { m.isActive }
        _ = await m.end(reason: .user)

        // On the charger the scan does not run either.
        reading.charging = true
        power.refreshBattery()
        let before = range.asked.count
        await armer.scanOnce()
        XCTAssertEqual(range.asked.count, before)
        XCTAssertFalse(m.isActive)
    }

    /// At or below the end floor the floor rules would end a standby at
    /// once, with a notification each time: it is not started.
    func testBatteryAtTheEndFloorDoesNotArm() async throws {
        XCTAssertTrue(StandbyArmer.batteryAllows(config: configOn(), percent: 11))
        XCTAssertFalse(StandbyArmer.batteryAllows(config: configOn(), percent: 10), "endFloor is 10 by default")
        XCTAssertTrue(StandbyArmer.batteryAllows(config: configOn(), percent: nil), "no reading does not block")
        var noFloor = configOn()
        noFloor.endFloor = 0
        XCTAssertTrue(StandbyArmer.batteryAllows(config: noFloor, percent: 1))

        let m = h.makeManager()
        m.config = configOn()
        let reading = Reading()
        let power = PowerMonitor(reader: { (.percent(8), reading.charging) })
        power.refreshBattery()
        let armer = StandbyArmer(manager: m, power: power, lidClosed: { false }, scan: { _ in false })
        armer.powerChanged()
        reading.charging = false
        power.refreshBattery()
        armer.powerChanged()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(m.isActive)
    }

    /// Unplug, then close the lid within seconds: the close can land while
    /// the standby start is still in flight. The start honours it itself.
    func testStandbyStartedUnderAClosedLidIsPromotedAtOnce() async {
        let m = h.makeManager()
        m.config = configOn()
        m.config.autoStartDuration = 8 * 3600
        h.clamshell.closed = true
        await m.startStandby(duration: 1800)
        XCTAssertTrue(m.isActive)
        XCTAssertFalse(m.standby, "promoted")
        XCTAssertEqual(m.session.map { $0.endsAt.timeIntervalSince(h.clock.now) }, 8 * 3600)
        _ = await m.end(reason: .user)
    }

    /// A standby that runs out with the lid open ends without the "Time is
    /// up" notification; an ordinary end still announces.
    func testStandbyExpiryIsQuiet() async {
        let m = h.makeManager()
        m.config = configOn()
        await m.startStandby(duration: 30 * 60)
        XCTAssertTrue(m.standby)
        let before = h.notifier.posts.count
        _ = await m.end(reason: .standbyExpired)
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.notifier.posts.count, before, "a quiet end")

        await m.start(duration: 3600)
        _ = await m.end(reason: .timer)
        XCTAssertEqual(h.notifier.posts.count, before + 1)
    }
}
