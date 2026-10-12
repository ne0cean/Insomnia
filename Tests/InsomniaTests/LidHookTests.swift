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
        XCTAssertEqual(close.arguments, ["INSOMNIA_LID=closed", "INSOMNIA_SESSION=idle", "/opt/hook.sh", "closed", "idle"])

        let open = try XCTUnwrap(LidHook.invocation(script: " /opt/hook.sh ", closed: false, sessionActive: true))
        XCTAssertEqual(open.arguments, ["INSOMNIA_LID=open", "INSOMNIA_SESSION=active", "/opt/hook.sh", "open", "active"])
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
