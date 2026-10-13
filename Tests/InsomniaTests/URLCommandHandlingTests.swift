import XCTest
@testable import Insomnia

/// The `insomnia://` handler's decisions (`SessionManager.perform`): an
/// explicit command from a script is never dropped on a stale read of the
/// session (adversarial review ADV-H1).
@MainActor
final class URLCommandHandlingTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    /// Unplug starts a 30 min standby; `insomnia-ctl start 8h` right after
    /// must become that session, for 8 h, not be ignored.
    func testStartOverAStandbyPromotesItToTheLengthAskedFor() async {
        let m = h.makeManager()
        m.config.autoStartOnLidClose = true
        m.config.standbyBeforeLidClose = true
        await m.startStandby(duration: 1800)
        XCTAssertTrue(m.standby)

        await m.perform(.start(8 * 3600))

        XCTAssertFalse(m.standby, "no longer a standby that ends quietly")
        XCTAssertEqual(m.session.map { $0.endsAt.timeIntervalSince(h.clock.now) }, 8 * 3600)
        _ = await m.end(reason: .user)
    }

    /// A start over an ordinary session is still ignored (use extend).
    func testStartOverAnOrdinarySessionIsIgnored() async {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let before = m.session
        await m.perform(.start(8 * 3600))
        XCTAssertEqual(m.session, before)
        _ = await m.end(reason: .user)
    }

    /// An end sent while a start is still in flight ends the session that
    /// start makes, instead of being dropped as "no session".
    func testEndDuringAStartInFlightEndsIt() async {
        let m = h.makeManager()
        let starting = Task { await m.perform(.start(3600)) }
        // Let the start take its place in the queue before the end arrives.
        for _ in 0..<100 where !(m.startsInFlight > 0 || m.isActive) { await Task.yield() }
        XCTAssertTrue(m.startsInFlight > 0 || m.isActive, "the start never reached the manager")
        await m.perform(.end)
        await starting.value
        XCTAssertFalse(m.isActive, "the end applied to the session the start made")
    }

    /// A resume right after a pause still in flight is not dropped.
    func testResumeRightAfterPauseIsKept() async {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let pausing = Task { await m.perform(.pause) }
        await m.perform(.resume)
        await pausing.value
        XCTAssertFalse(m.isPaused, "the resume ran after the pause, not dropped before it")
        _ = await m.end(reason: .user)
    }

    /// An explicit extend makes a standby a session the user wants kept.
    func testExtendClearsStandby() async {
        let m = h.makeManager()
        m.config.autoStartOnLidClose = true
        m.config.standbyBeforeLidClose = true
        await m.startStandby(duration: 1800)
        await m.perform(.extend(3600))
        XCTAssertFalse(m.standby)
        _ = await m.end(reason: .user)
    }

    func testEndWithNothingToEndIsANoOp() async {
        let m = h.makeManager()
        let before = h.notifier.posts.count
        await m.perform(.end)
        XCTAssertEqual(h.notifier.posts.count, before, "no spurious 'Session restored' notification")
    }
}
