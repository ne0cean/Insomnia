import XCTest
@testable import Insomnia

/// Auto-start on lid close. The watcher's observer is never started, so
/// nothing registers with IOKit; `lidChanged` stands in for a delivery.
@MainActor
final class IdleLidWatcherTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    func testShouldAutoStartOnlyOnACloseWithNoSessionAndTheSettingOn() {
        var on = Config()
        on.autoStartOnLidClose = true
        XCTAssertTrue(IdleLidWatcher.shouldAutoStart(closed: true, active: false, config: on))
        XCTAssertFalse(IdleLidWatcher.shouldAutoStart(closed: false, active: false, config: on), "an open never starts one")
        XCTAssertFalse(IdleLidWatcher.shouldAutoStart(closed: true, active: true, config: on), "a running session is left alone")
        XCTAssertFalse(IdleLidWatcher.shouldAutoStart(closed: true, active: false, config: Config()), "off by default")
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), what)
    }

    func testCloseStartsASessionOfTheAutoStartDuration() async {
        let m = h.makeManager()
        m.config.autoStartOnLidClose = true
        m.config.autoStartDuration = 8 * 3600
        let watcher = IdleLidWatcher(manager: m, lid: LidObserver(read: { true }, debounce: 0.05))
        watcher.lidChanged(true)
        await waitUntil("the session started") { m.isActive }
        XCTAssertEqual(m.session.map { $0.endsAt.timeIntervalSince($0.startedAt) }, 8 * 3600)
        _ = await m.end(reason: .user)
    }

    /// A close during a standby session extends it to the auto-start
    /// duration instead of starting (or ignoring) anything.
    func testCloseDuringStandbyPromotesTheSession() async {
        let m = h.makeManager()
        m.config.autoStartOnLidClose = true
        m.config.autoStartDuration = 8 * 3600
        m.config.standbyBeforeLidClose = true
        await m.startStandby(duration: 30 * 60)
        XCTAssertTrue(m.isActive)
        XCTAssertTrue(m.standby)
        let watcher = IdleLidWatcher(manager: m, lid: LidObserver(read: { true }, debounce: 0.05))

        watcher.lidChanged(true)
        await waitUntil("the standby session was not promoted") { !m.standby }
        await waitUntil("the session was not extended") {
            m.session.map { $0.endsAt.timeIntervalSince(h.clock.now) } == 8 * 3600
        }
        XCTAssertEqual(m.session?.extensions.count, 1)

        // A later close inside the same session is left to the lid actions.
        watcher.lidChanged(true)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(m.session?.extensions.count, 1)
        _ = await m.end(reason: .user)
        XCTAssertFalse(m.standby)
    }

    /// An ordinary session is not touched by the watcher.
    func testCloseDuringAnOrdinarySessionIsLeftToTheLidActions() async throws {
        let m = h.makeManager()
        m.config.autoStartOnLidClose = true
        await m.start(duration: 3600)
        XCTAssertFalse(m.standby)
        let watcher = IdleLidWatcher(manager: m, lid: LidObserver(read: { true }, debounce: 0.05))
        watcher.lidChanged(true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(m.session?.extensions, [])
        _ = await m.end(reason: .user)
    }

    func testCloseWithTheSettingOffStartsNothing() async throws {
        let m = h.makeManager()
        let watcher = IdleLidWatcher(manager: m, lid: LidObserver(read: { true }, debounce: 0.05))
        watcher.lidChanged(true)
        // Give a start, had one been requested, the time to run.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(m.isActive)
    }
}
