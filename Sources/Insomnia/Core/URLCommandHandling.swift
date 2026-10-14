import Foundation

/// `insomnia://` commands from scripts — the "judged on a stale read"
/// family adversarial review kept finding (r2 R2-N1, r3 R3-N1·N2·L1,
/// r4 R4-M1). What this guarantees, and no more:
///
/// 1. **Order.** Commands run one at a time, each to completion, in
///    arrival order (`enqueue`). On a cold launch the queue stays closed
///    until the launch reconcile has returned (`holdCommandsForLaunch` /
///    `openCommands`), whatever its outcome.
/// 2. **No command acts on a session it has not loaded.** If session.json
///    is on disk but no session is in memory (the launch reconcile was
///    refused, say, with an orphaned pmset holding the lock), the command
///    reconciles first (`loadSessionFromDiskIfNeeded`). If the session
///    still cannot be loaded, start/extend/pause/resume are refused with
///    an error the menu shows — never dropped silently — and end still
///    ends what the disk holds (`endIfAnything`).
/// 3. **Start and extend decisions are made under the manager's lock**
///    (`performStart` ignores a start over a running session; the standby
///    promotion that follows reads the flag after that start returned).
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
        if command != .status, command != .end {
            guard await loadSessionFromDiskIfNeeded(for: command) else { return }
        }
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

    /// A session on disk that is not in memory (a launch reconcile that was
    /// refused) is loaded before a command acts: reconcile now. Returns false,
    /// with a visible error, when it still is not loaded, so the command is
    /// refused rather than applied to the empty state and silently lost
    /// (adversarial r4 R4-M1: extend/pause after a refused cold-launch
    /// reconcile vanished, and the reconcile retry brought the session back
    /// with its old deadline).
    func loadSessionFromDiskIfNeeded(for command: URLCommand) async -> Bool {
        guard session == nil, store.sessionEntryExists() else { return true }
        Log.info("url scheme: a session is on disk but not loaded; reconciling before \(command)")
        await reconcile()
        guard session == nil, store.sessionEntryExists() else { return true }
        fail("url scheme: \(command) not applied: the session on disk could not be loaded yet (the recovery lock may be held by an earlier power command). Try again shortly.")
        return false
    }

    /// End whatever is held: a session in memory, a session file on disk
    /// (one a refused or pending reconcile has not loaded), or a journal
    /// with something to undo. With none of those it is a quiet no-op, so
    /// a stray `end` posts no "Session restored" notification.
    func endIfAnything() async {
        // An entry that exists but cannot be read still counts: the end
        // moves it aside instead of leaving it for a later reader.
        let onDisk = store.sessionEntryExists()
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
