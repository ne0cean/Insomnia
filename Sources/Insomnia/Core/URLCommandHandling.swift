import Foundation

/// What an `insomnia://` command does. Here, not in the app delegate, so
/// it can be tested, and so every decision is made by the manager in its
/// own order instead of by a pre-check that reads the session before a
/// queued start, pause or end has changed it (an explicit command from a
/// script must never be dropped on a stale read).
extension SessionManager {
    func perform(_ command: URLCommand) async {
        // Every decision below reads the session; on a fresh launch that is
        // only true once the session on disk has been reconciled.
        await waitForLaunchReconcile()
        switch command {
        case let .start(seconds):
            let duration = seconds ?? config.defaultPreset
            if isActive {
                // A standby is a session the user has not asked for yet: an
                // explicit start becomes it, for the length asked for.
                if standby {
                    Log.info("url scheme: start for \(Int(duration)) s over a standby: promoting it")
                    await promoteStandby(to: duration)
                } else {
                    Log.info("url scheme: start ignored: a session is already active; use extend")
                }
                return
            }
            Log.info("url scheme: start for \(Int(duration)) s")
            await start(duration: duration)
            // A standby start in flight made the session this start found
            // (and ignored): the explicit start becomes that standby.
            if standby {
                Log.info("url scheme: start met a standby that started meanwhile: promoting it")
                await promoteStandby(to: duration)
            }
        case let .extend(seconds):
            Log.info("url scheme: extend by \(Int(seconds)) s")
            await extend(by: seconds)
        case .end:
            guard isActive || startsInFlight > 0 else {
                Log.info("url scheme: end ignored: no session and no start in flight")
                return
            }
            Log.info("url scheme: end")
            _ = await end(reason: .user)
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
}
