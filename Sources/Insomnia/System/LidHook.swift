import Foundation

/// Runs the user's lid hook (`Config.lidHookScript`) on every lid close and
/// open, with or without a session. The script gets the lid state and the
/// session state twice, as arguments (`closed|open`, `active|idle`) and as
/// `INSOMNIA_LID` and `INSOMNIA_SESSION` in its environment, so a one-line
/// script can read either. It never holds up a lid action: callers start it
/// in a task of its own, a failure is only logged, and it is killed after
/// `timeout` seconds.
///
/// The script is handed to the interpreter its `#!` line names, never
/// exec'd itself: Gatekeeper assesses an unsigned file that is exec'd, and
/// on macOS 26 that assessment reached out to the network and took 29 s on
/// one Mac (2026-10-13), past the 20 s limit, so the hook never ran. An
/// interpreter reading the file is not assessed. A script with no `#!`
/// line runs under `/bin/sh`.
enum LidHook {
    static let timeout: TimeInterval = 20
    static let defaultInterpreter = ["/bin/sh"]

    /// The process to launch for one event. The environment goes through
    /// /usr/bin/env because `Shell.run` passes the app's environment as it
    /// is; env adds the two variables and then execs the interpreter, so
    /// the timeout kills the interpreter and its script.
    struct Invocation: Equatable, Sendable {
        let script: String
        let executable: String
        let arguments: [String]
    }

    /// Pure: what to run for this event, or nil when the hook is off or the
    /// path is unusable. The path must be absolute (a leading `~/` is
    /// expanded) and must not contain `=`, which env would read as one more
    /// variable instead of the program to run. `interpreter` is the
    /// program, with its argument if any, the script is handed to
    /// (`interpreter(of:)`).
    static func invocation(script: String, closed: Bool, sessionActive: Bool, interpreter: [String] = defaultInterpreter) -> Invocation? {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = (trimmed as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), !path.contains("=") else { return nil }
        let lid = closed ? "closed" : "open"
        let session = sessionActive ? "active" : "idle"
        return Invocation(
            script: path,
            executable: "/usr/bin/env",
            arguments: ["INSOMNIA_LID=\(lid)", "INSOMNIA_SESSION=\(session)"] + interpreter + [path, lid, session]
        )
    }

    /// Pure: the interpreter a script's first line names, as the kernel
    /// would run it: the absolute path after `#!` and, if anything follows
    /// it, the rest of the line as one argument. `defaultInterpreter` when
    /// the line is not a `#!` line, names no absolute path, or the path or
    /// argument contains `=` (env would read it as a variable).
    static func interpreter(of firstLine: String) -> [String] {
        guard firstLine.hasPrefix("#!") else { return defaultInterpreter }
        let rest = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
        let parts = rest.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard let program = parts.first, program.hasPrefix("/"), !program.contains("=") else { return defaultInterpreter }
        var result = [String(program)]
        if parts.count == 2 {
            let argument = parts[1].trimmingCharacters(in: .whitespaces)
            if !argument.isEmpty, !argument.contains("=") { result.append(argument) }
        }
        return result
    }

    /// The interpreter for the script at `path`, from its first line.
    static func interpreter(ofFileAt path: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return defaultInterpreter }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 512)) ?? Data()
        let firstLine = String(decoding: head, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return interpreter(of: firstLine)
    }

    /// Runs the hook for one lid event and logs the outcome. Returns
    /// without running anything when the hook is off, the path is unusable
    /// or the file is not executable.
    static func run(script: String, closed: Bool, sessionActive: Bool) async {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let probe = invocation(script: trimmed, closed: closed, sessionActive: sessionActive) else {
            Log.error("lid hook skipped: \(trimmed) is not an absolute path without \"=\"")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: probe.script) else {
            Log.error("lid hook skipped: \(probe.script) is not an executable file")
            return
        }
        let interpreter = interpreter(ofFileAt: probe.script)
        guard let call = invocation(script: trimmed, closed: closed, sessionActive: sessionActive, interpreter: interpreter) else { return }
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
