import Foundation

/// Runs the user's lid hook (`Config.lidHookScript`) on every lid close and
/// open, with or without a session. The script gets the lid state and the
/// session state twice, as arguments (`closed|open`, `active|idle`) and as
/// `INSOMNIA_LID` and `INSOMNIA_SESSION` in its environment, so a one-line
/// script can read either. It never holds up a lid action: callers start it
/// in a task of its own, a failure is only logged, and it is killed after
/// `timeout` seconds.
enum LidHook {
    static let timeout: TimeInterval = 20

    /// The process to launch for one event. The environment goes through
    /// /usr/bin/env because `Shell.run` passes the app's environment as it
    /// is; env adds the two variables and then execs the script, so the
    /// timeout kills the script itself.
    struct Invocation: Equatable, Sendable {
        let script: String
        let executable: String
        let arguments: [String]
    }

    /// Pure: what to run for this event, or nil when the hook is off or the
    /// path is unusable. The path must be absolute (a leading `~/` is
    /// expanded) and must not contain `=`, which env would read as one more
    /// variable instead of the program to run.
    static func invocation(script: String, closed: Bool, sessionActive: Bool) -> Invocation? {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = (trimmed as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), !path.contains("=") else { return nil }
        let lid = closed ? "closed" : "open"
        let session = sessionActive ? "active" : "idle"
        return Invocation(
            script: path,
            executable: "/usr/bin/env",
            arguments: ["INSOMNIA_LID=\(lid)", "INSOMNIA_SESSION=\(session)", path, lid, session]
        )
    }

    /// Runs the hook for one lid event and logs the outcome. Returns
    /// without running anything when the hook is off, the path is unusable
    /// or the file is not executable.
    static func run(script: String, closed: Bool, sessionActive: Bool) async {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let call = invocation(script: trimmed, closed: closed, sessionActive: sessionActive) else {
            Log.error("lid hook skipped: \(trimmed) is not an absolute path without \"=\"")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: call.script) else {
            Log.error("lid hook skipped: \(call.script) is not an executable file")
            return
        }
        let event = "\(closed ? "closed" : "open") \(sessionActive ? "active" : "idle")"
        do {
            let result = try await Shell.run(call.executable, call.arguments, timeout: timeout)
            if result.succeeded {
                Log.info("lid hook (\(event)) finished")
            } else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
                Log.error("lid hook (\(event)) exited \(result.status)\(detail.isEmpty ? "" : ": \(detail)")")
            }
        } catch {
            Log.error("lid hook (\(event)) failed: \(error.localizedDescription)")
        }
    }
}
