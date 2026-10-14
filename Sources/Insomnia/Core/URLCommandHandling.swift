import Foundation

/// `insomnia://` commands from scripts. Two rules, both from adversarial
/// review (r2 R2-N1, r3 R3-N1·N2·L1 — the "judged on a stale read" family,
/// which a pre-check outside the queue kept reopening):
///
/// 1. **Order is a queue, not a poll.** Commands run one at a time, each
///    to completion, in arrival order (`enqueue`). On a cold launch the
///    queue is closed until the launch reconcile has had its turn
///    (`holdCommandsForLaunch` / `openCommands`), so a script's first
///    command never sees the empty state a fresh process starts with.
/// 2. **`perform` reads no session state to decide.** Every decision is
///    made by the manager under its own lock: a start that finds a session
///    is ignored inside `performStart`; an end goes to `endIfAnything`,
///    which ends whatever the *disk* holds (session.json or a dirty
///    journal), so a session a refused reconcile has not loaded yet is
///    still ended — never "no session".
extension SessionManager {
    /// Close the command queue until `openCommands()`. The live app calls
    /// this at init, before any URL can arrive, and opens it once its
    /// launch reconcile returns, whatever the outcome.
    func holdCommandsForLaunch() {
        guard commandGate == nil else { return }
        let gate = CommandGate()
        commandGate = gate
        commandTail = Task { @MainActor in await gate.wait() }
    }

    func openCommands() {
        commandGate?.open()
    }

    /// Queue a command behind every earlier one (and behind the launch
    /// gate). Returns the task that runs it, for tests and callers that
    /// want to wait.
    @discardableResult
    func enqueue(_ command: URLCommand) -> Task<Void, Never> {
        let previous = commandTail
        let task = Task { @MainActor in
            await previous?.value
            await self.perform(command)
        }
        commandTail = task
        return task
    }

    func perform(_ command: URLCommand) async {
        switch command {
        case let .start(seconds):
            let duration = seconds ?? config.defaultPreset
            Log.info("url scheme: start for \(Int(duration)) s")
            // An ordinary session already running makes performStart ignore
            // this (logged there). A standby is a session the user has not
            // asked for yet: the explicit start becomes it.
            await start(duration: duration)
            if standby {
                Log.info("url scheme: start over a standby: promoting it to \(Int(duration)) s")
                await promoteStandby(to: duration)
            }
        case let .extend(seconds):
            Log.info("url scheme: extend by \(Int(seconds)) s")
            await extend(by: seconds)
        case .end:
            Log.info("url scheme: end")
            await endIfAnything()
        case .pause:
            Log.info("url scheme: pause")
            await pause()
        case .resume:
            Log.info("url scheme: resume")
            await resume()
        case .status:
            if let session {
                Log.info("url scheme: status: session active until \(session.endsAt.formatted(.iso8601))\(isPaused ? " (paused)" : "")\(standby ? " (standby)" : "")")
            } else {
                Log.info("url scheme: status: no session")
            }
        }
    }

    /// End whatever is held: a session in memory, a session file on disk
    /// (one a refused or pending reconcile has not loaded), or a journal
    /// with something to undo. With none of those it is a quiet no-op, so
    /// a stray `end` posts no "Session restored" notification.
    func endIfAnything() async {
        let onDisk = (try? store.loadSession()) != nil
        guard session != nil || onDisk || state.isDirty || startsInFlight > 0 else {
            Log.info("url scheme: end: nothing to end")
            return
        }
        _ = await end(reason: .user)
    }
}

/// A one-shot gate: `wait()` suspends until `open()`; after that it returns
/// at once.
@MainActor
final class CommandGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let all = waiters
        waiters = []
        for w in all { w.resume() }
    }
}
