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

    /// The unplug's standby start is still in flight when `start 8h`
    /// arrives: the explicit start must become that standby, not be
    /// ignored as "session already active" (review r3).
    func testStartDuringAStandbyStartInFlightPromotesIt() async {
        let m = h.makeManager()
        m.config.autoStartOnLidClose = true
        m.config.standbyBeforeLidClose = true
        let standby = Task { await m.startStandby(duration: 1800) }
        let explicit = Task { await m.perform(.start(8 * 3600)) }
        await standby.value
        await explicit.value
        XCTAssertTrue(m.isActive)
        XCTAssertFalse(m.standby, "the explicit start took the standby over")
        XCTAssertEqual(m.session.map { $0.endsAt.timeIntervalSince(h.clock.now) }, 8 * 3600)
        _ = await m.end(reason: .user)
    }

    /// The standby flag is set in the same step as the session: there is
    /// no moment where the session exists and reads as an ordinary one.
    func testStandbyFlagIsSetWithTheSession() async {
        let m = h.makeManager()
        await m.start(duration: 1800, asStandby: true)
        XCTAssertTrue(m.isActive)
        XCTAssertTrue(m.standby)
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

    /// Commands run in arrival order, each to completion: `start 8h` then
    /// `end` never lets the end be judged first (review r3 R3-N2).
    func testQueuedStartThenEndEndsTheSession() async {
        let m = h.makeManager()
        m.enqueue(.start(8 * 3600))
        await m.enqueue(.end).value
        XCTAssertFalse(m.isActive, "the end ran after the start, not before it")
    }

    /// A resume right after a pause runs after it, not before.
    func testQueuedPauseThenResumeLeavesItRunning() async {
        let m = h.makeManager()
        await m.start(duration: 3600)
        m.enqueue(.pause)
        await m.enqueue(.resume).value
        XCTAssertFalse(m.isPaused)
        _ = await m.end(reason: .user)
    }

    /// The live configuration: the queue is closed until the launch
    /// reconcile has run, and the order holds across the gate.
    func testCommandsWaitBehindTheLaunchGateInOrder() async {
        let m = h.makeManager()
        m.holdCommandsForLaunch()
        m.enqueue(.start(8 * 3600))
        let last = m.enqueue(.end)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(m.isActive, "nothing ran while the gate was closed")
        XCTAssertEqual(m.startsInFlight, 0)
        m.openCommands()
        await last.value
        XCTAssertFalse(m.isActive, "start then end, in order, after the gate opened")
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

    /// After a crash, `insomnia-ctl end` launches the app. Even when the
    /// launch reconcile has not loaded the session (it was refused, say,
    /// with the lock still held), the end ends what the disk holds instead
    /// of being dropped as "no session" (review R2-N1, r3 R3-N1).
    func testEndWithTheSessionOnlyOnDiskEndsIt() async {
        let before = h.makeManager()
        await before.start(duration: 3600)
        XCTAssertNotNil(try? before.store.loadSession())
        // The app dies; a new one comes up on the same disk, no reconcile.
        let relaunched = h.makeManager()
        XCTAssertFalse(relaunched.isActive, "nothing loaded")
        await relaunched.perform(.end)
        XCTAssertNil(try? relaunched.store.loadSession(), "the session on disk was ended, not left for a later reconcile to revive")
        XCTAssertFalse(relaunched.isActive)
    }

    /// The launch gate opens after the reconcile in the live app; behind it
    /// an end sees the reconciled session.
    func testEndBehindTheGateEndsTheReconciledSession() async {
        let before = h.makeManager()
        await before.start(duration: 3600)
        let relaunched = h.makeManager()
        relaunched.holdCommandsForLaunch()
        let ending = relaunched.enqueue(.end)
        await relaunched.reconcile()
        relaunched.openCommands()
        await ending.value
        XCTAssertFalse(relaunched.isActive)
        XCTAssertNil(try? relaunched.store.loadSession())
    }

    func testEndWithNothingToEndIsANoOp() async {
        let m = h.makeManager()
        let before = h.notifier.posts.count
        await m.perform(.end)
        XCTAssertEqual(h.notifier.posts.count, before, "no spurious 'Session restored' notification")
    }
}
