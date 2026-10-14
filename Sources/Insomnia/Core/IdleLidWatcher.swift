import Foundation

/// Watches the lid for the whole life of the app, not only during a
/// session (AppServices' own observer runs only while one is active).
/// Between sessions it does two things on a lid event: runs the lid hook
/// with `idle`, and, on a close with `Config.autoStartOnLidClose` on,
/// starts a session of `Config.effectiveAutoStartDuration`.
///
/// Events while a session is active are left to `LidActions`, which runs
/// the hook with `active` after its own actions, so each event runs the
/// hook once. The one exception is a close during a standby session
/// (`StandbyArmer`): sleep is already held, so the close only extends that
/// session to the auto-start duration (`SessionManager.promoteStandby`).
///
/// A session this watcher starts begins with the lid already closed:
/// AppServices' observer starts then and sees no change, so the lid-close
/// actions (mute, darken, freeze) do not run for that close. They run on
/// the next close inside the session. A start after the close is a
/// fallback that works only on a dock (sleep is committed within seconds
/// otherwise); standby is the path that works without one.
@MainActor
final class IdleLidWatcher {
    private weak var manager: SessionManager?
    private let lid: LidObserver

    init(manager: SessionManager, lid: LidObserver = LidObserver()) {
        self.manager = manager
        self.lid = lid
    }

    /// Pure: whether a lid event should start a session.
    nonisolated static func shouldAutoStart(closed: Bool, active: Bool, config: Config) -> Bool {
        closed && !active && config.autoStartOnLidClose
    }

    func start() {
        lid.onChange = { [weak self] closed in self?.lidChanged(closed) }
        lid.start()
    }

    func stop() {
        lid.stop()
        lid.onChange = nil
    }

    /// Internal so a test can deliver an event.
    func lidChanged(_ closed: Bool) {
        guard let manager else { return }
        if manager.isActive {
            guard closed, manager.standby else { return }
            Task { @MainActor in await manager.promoteStandby() }
            return
        }
        let config = manager.config
        let script = config.lidHookScript
        if !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task.detached { await LidHook.run(script: script, closed: closed, sessionActive: false) }
        }
        guard Self.shouldAutoStart(closed: closed, active: manager.isActive, config: config) else { return }
        let duration = config.effectiveAutoStartDuration
        Log.info("lid closed with no session: starting one for \(Int(duration)) s (auto-start on lid close)")
        Task { @MainActor in
            await manager.start(duration: duration)
            if !manager.isActive {
                Log.error("auto-start on lid close: the session did not start")
            } else if manager.standby {
                // The start was ignored because a standby start was already in
                // flight when the lid closed: that session is the one to extend.
                await manager.promoteStandby()
            }
        }
    }
}
