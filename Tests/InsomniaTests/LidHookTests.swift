import XCTest
@testable import Insomnia

/// The lid hook and auto-start settings: their config.json keys, and what
/// the hook is handed for each lid event.
final class LidHookConfigTests: XCTestCase {
    func testDefaultsAreOff() {
        let c = Config()
        XCTAssertFalse(c.autoStartOnLidClose, "auto-start is opt in")
        XCTAssertEqual(c.autoStartDuration, 10 * 3600)
        XCTAssertEqual(c.lidHookScript, "")
    }

    /// A config.json written before the keys existed loads with the defaults.
    func testMissingKeysDecodeAsDefaults() throws {
        let old = try Store.makeDecoder().decode(Config.self, from: Data(#"{"tmuxTargets": ["agents:0.0"]}"#.utf8))
        XCTAssertFalse(old.autoStartOnLidClose)
        XCTAssertEqual(old.autoStartDuration, 10 * 3600)
        XCTAssertEqual(old.lidHookScript, "")
    }

    func testPresentKeysDecodeAndRoundTrip() throws {
        let json = #"{"autoStartOnLidClose": true, "autoStartDuration": 28800, "lidHookScript": "/usr/local/bin/lid-hook"}"#
        let c = try Store.makeDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertTrue(c.autoStartOnLidClose)
        XCTAssertEqual(c.autoStartDuration, 28800)
        XCTAssertEqual(c.lidHookScript, "/usr/local/bin/lid-hook")
        let data = try Store.makeEncoder().encode(c)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), c)
    }

    /// A hand-edited duration is kept inside the stepper's range and under
    /// the session ceiling.
    func testEffectiveAutoStartDurationIsClamped() {
        var c = Config()
        c.autoStartDuration = 0
        XCTAssertEqual(c.effectiveAutoStartDuration, 3600)
        c.autoStartDuration = 100 * 3600
        XCTAssertEqual(c.effectiveAutoStartDuration, 24 * 3600)
        c.autoStartDuration = 8 * 3600
        XCTAssertEqual(c.effectiveAutoStartDuration, 8 * 3600)
        c.maxDuration = 2 * 3600
        XCTAssertEqual(c.effectiveAutoStartDuration, 2 * 3600)
    }

    func testStandbyDefaultsDecodeAndClamp() throws {
        let c = Config()
        XCTAssertFalse(c.standbyBeforeLidClose, "standby is opt in")
        XCTAssertEqual(c.standbyDuration, 30 * 60)
        XCTAssertEqual(c.effectiveStandbyDuration, 30 * 60)

        let old = try Store.makeDecoder().decode(Config.self, from: Data(#"{"autoStartOnLidClose": true}"#.utf8))
        XCTAssertFalse(old.standbyBeforeLidClose)
        XCTAssertEqual(old.standbyDuration, 30 * 60)

        let json = #"{"standbyBeforeLidClose": true, "standbyDuration": 600}"#
        var on = try Store.makeDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertTrue(on.standbyBeforeLidClose)
        XCTAssertEqual(on.standbyDuration, 600)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: Store.makeEncoder().encode(on)), on)

        on.standbyDuration = 10
        XCTAssertEqual(on.effectiveStandbyDuration, 5 * 60, "floor")
        on.standbyDuration = 9 * 3600
        XCTAssertEqual(on.effectiveStandbyDuration, 2 * 3600, "ceiling")
        on.autoStartDuration = 3600
        XCTAssertEqual(on.effectiveStandbyDuration, 3600, "never longer than the session it becomes")
    }
}

final class LidHookTests: XCTestCase {
    func testEmptyScriptIsOff() {
        XCTAssertNil(LidHook.invocation(script: "", closed: true, sessionActive: false))
        XCTAssertNil(LidHook.invocation(script: "   ", closed: true, sessionActive: false))
    }

    func testRelativeOrAssignmentLikePathsAreRefused() {
        XCTAssertNil(LidHook.invocation(script: "hook.sh", closed: true, sessionActive: false))
        XCTAssertNil(LidHook.invocation(script: "-i", closed: true, sessionActive: false))
        XCTAssertNil(LidHook.invocation(script: "/tmp/a=b/hook.sh", closed: true, sessionActive: false))
    }

    func testArgumentsAndEnvironmentNameTheEvent() throws {
        let close = try XCTUnwrap(LidHook.invocation(script: "/opt/hook.sh", closed: true, sessionActive: false))
        XCTAssertEqual(close.executable, "/usr/bin/env")
        XCTAssertEqual(close.script, "/opt/hook.sh")
        XCTAssertEqual(close.arguments, ["INSOMNIA_LID=closed", "INSOMNIA_SESSION=idle", "/bin/sh", "/opt/hook.sh", "closed", "idle"])

        let open = try XCTUnwrap(LidHook.invocation(script: " /opt/hook.sh ", closed: false, sessionActive: true, interpreter: ["/bin/bash", "-e"]))
        XCTAssertEqual(open.arguments, ["INSOMNIA_LID=open", "INSOMNIA_SESSION=active", "/bin/bash", "-e", "/opt/hook.sh", "open", "active"])
    }

    /// The `#!` line names the interpreter as the kernel would run it; the
    /// script is never exec'd itself, so Gatekeeper does not assess it.
    func testShebangNamesTheInterpreter() {
        XCTAssertEqual(LidHook.interpreter(of: "#!/bin/bash"), ["/bin/bash"])
        XCTAssertEqual(LidHook.interpreter(of: "#! /bin/zsh -f"), ["/bin/zsh", "-f"])
        XCTAssertEqual(LidHook.interpreter(of: "#!/usr/bin/env python3"), ["/usr/bin/env", "python3"])
        XCTAssertEqual(LidHook.interpreter(of: "#!/usr/bin/env -S python3 -u"), ["/usr/bin/env", "-S python3 -u"], "the rest of the line is one argument")
        XCTAssertEqual(LidHook.interpreter(of: "echo hi"), ["/bin/sh"], "no shebang")
        XCTAssertEqual(LidHook.interpreter(of: ""), ["/bin/sh"])
        XCTAssertNil(LidHook.interpreter(of: "#!bash"), "a relative interpreter is refused, not replaced by sh")
        XCTAssertNil(LidHook.interpreter(of: "#!/bin/A=B/sh"), "a program path env would read as a variable")
        XCTAssertEqual(LidHook.interpreter(of: "#!/usr/bin/env -S FOO=1 python3"), ["/usr/bin/env", "-S FOO=1 python3"], "= in the argument is fine: env has seen the program by then")
    }

    /// A shebang that names no absolute interpreter is skipped: the script
    /// is not handed to /bin/sh, which it was not written for.
    func testRunSkipsAScriptWithAnUnusableShebang() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidhook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.txt")
        let script = dir.appendingPathComponent("hook.sh")
        try TestScripts.write("""
        #!bash
        touch "\(out.path)"
        """, to: script)
        await LidHook.run(script: script.path, closed: true, sessionActive: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testTildeIsExpanded() throws {
        let call = try XCTUnwrap(LidHook.invocation(script: "~/bin/hook.sh", closed: true, sessionActive: true))
        XCTAssertTrue(call.script.hasPrefix("/"), call.script)
        XCTAssertTrue(call.script.hasSuffix("/bin/hook.sh"), call.script)
    }

    /// The real run: the script sees both arguments and both variables.
    func testRunHandsTheScriptArgumentsAndEnvironment() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidhook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.txt")
        let script = dir.appendingPathComponent("hook.sh")
        try TestScripts.write("""
        #!/bin/bash
        printf '%s %s %s %s\\n' "$1" "$2" "$INSOMNIA_LID" "$INSOMNIA_SESSION" > "\(out.path)"
        """, to: script)

        await LidHook.run(script: script.path, closed: true, sessionActive: false)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "closed idle closed idle\n")
    }

    /// The shebang's interpreter and its argument are what runs the script:
    /// `#!/bin/bash -e` stops at the first failing command, so the line
    /// after it never runs. A script without a shebang runs under /bin/sh.
    func testRunUsesTheScriptsOwnInterpreterAndArgument() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidhook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.txt")
        let strict = dir.appendingPathComponent("strict.sh")
        try TestScripts.write("""
        #!/bin/bash -e
        printf '%s' "$BASH_VERSION" > "\(out.path)"
        false
        printf 'ran past the failure' > "\(out.path)"
        """, to: strict)
        await LidHook.run(script: strict.path, closed: false, sessionActive: false)
        let written = try String(contentsOf: out, encoding: .utf8)
        XCTAssertFalse(written.isEmpty, "BASH_VERSION was empty: not run by bash")
        XCTAssertNotEqual(written, "ran past the failure", "-e from the shebang was not passed to bash")

        let bare = dir.appendingPathComponent("bare.sh")
        try TestScripts.write("""
        printf '%s' "$INSOMNIA_SESSION" > "\(out.path)"
        """, to: bare)
        await LidHook.run(script: bare.path, closed: true, sessionActive: true)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "active")
    }

    /// A file that is not executable is skipped, not run through a shell.
    func testRunSkipsANonExecutableFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidhook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.txt")
        let script = dir.appendingPathComponent("hook.sh")
        try TestScripts.write("""
        #!/bin/bash
        touch "\(out.path)"
        """, to: script, executable: false)

        await LidHook.run(script: script.path, closed: false, sessionActive: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}
