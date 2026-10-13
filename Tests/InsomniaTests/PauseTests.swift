import XCTest
@testable import Insomnia

/// Pausing a session: the countdown stands still, sleep stays held, and
/// the deadline on disk is rolled forward so the backstop never sees an
/// open-ended hold.
@MainActor
final class PauseTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    func testPauseFreezesTheCountdownAndRollsTheDeadline() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        XCTAssertFalse(m.isPaused)
        h.clock.advance(600)

        await m.pause()
        XCTAssertTrue(m.isPaused)
        XCTAssertEqual(m.pausedRemaining, 3000)
        // The deadline on disk moved to now + 50 min at the pause.
        XCTAssertEqual(try XCTUnwrap(m.store.loadSession()).endsAt, h.clock.now.addingTimeInterval(3000))
        m.refreshCountdown()
        let frozen = m.countdownText
        XCTAssertTrue(frozen.hasPrefix(SessionManager.pausedCountdownPrefix), frozen)

        // Time passes: the text does not move, and a roll puts the deadline
        // at now + 50 min again.
        h.clock.advance(300)
        m.refreshCountdown()
        XCTAssertEqual(m.countdownText, frozen)
        m.rollPausedDeadline()
        XCTAssertEqual(try XCTUnwrap(m.store.loadSession()).endsAt, h.clock.now.addingTimeInterval(3000))
        XCTAssertEqual(m.session?.extensions, [], "a roll is not an extension")

        await m.resume()
        XCTAssertFalse(m.isPaused)
        XCTAssertNil(m.pausedRemaining)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3000))
        m.refreshCountdown()
        XCTAssertFalse(m.countdownText.hasPrefix(SessionManager.pausedCountdownPrefix))
        XCTAssertEqual(m.countdownText, frozen.dropFirst(SessionManager.pausedCountdownPrefix.count).description)

        _ = await m.end(reason: .user)
        XCTAssertFalse(m.isPaused)
    }

    func testPauseAndResumeWithoutASessionDoNothing() async {
        let m = h.makeManager()
        await m.pause()
        XCTAssertFalse(m.isPaused)
        await m.resume()
        XCTAssertFalse(m.isActive)
    }

    /// A paused standby session is one the user wants kept: the lid close
    /// no longer reshapes it.
    func testPausingAStandbySessionDropsTheStandbyFlag() async {
        let m = h.makeManager()
        m.config.autoStartOnLidClose = true
        m.config.standbyBeforeLidClose = true
        await m.startStandby(duration: 1800)
        XCTAssertTrue(m.standby)
        await m.pause()
        XCTAssertFalse(m.standby)
        await m.promoteStandby()
        XCTAssertEqual(m.session?.extensions, [], "a paused session is not promoted")
        _ = await m.end(reason: .user)
    }

    func testEndClearsThePause() async {
        let m = h.makeManager()
        await m.start(duration: 3600)
        await m.pause()
        XCTAssertTrue(m.isPaused)
        _ = await m.end(reason: .user)
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(m.isPaused)
        XCTAssertNil(try? m.store.loadSession())
    }

    func testMenuOffersPauseOrResumeOnlyWithASession() {
        let idle = StatusMenu.items(sessionActive: false, sleepHeld: false, paused: nil, machine: nil, actions: nil, throttledBrowsers: [], error: nil)
        XCTAssertEqual(idle.map(\.kind), [.settings, .quit])

        let running = StatusMenu.items(sessionActive: true, sleepHeld: true, paused: false, machine: nil, actions: nil, throttledBrowsers: [], error: nil)
        XCTAssertEqual(running.map(\.kind), [.info, .separator, .togglePause, .settings, .quit])
        XCTAssertEqual(running[2].title, StatusMenu.pauseTitle)

        let paused = StatusMenu.items(sessionActive: true, sleepHeld: true, paused: true, machine: nil, actions: nil, throttledBrowsers: [], error: nil)
        XCTAssertEqual(paused[2].kind, .togglePause)
        XCTAssertEqual(paused[2].title, StatusMenu.resumeTitle)
    }
}
