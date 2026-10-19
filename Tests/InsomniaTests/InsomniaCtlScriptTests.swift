import Foundation
import XCTest
@testable import Insomnia

/// scripts/insomnia-ctl.sh run as is, with a stub `open` first on PATH that
/// records its arguments, so each case checks the exact URL and that it is
/// addressed to this app's bundle id (Kong's Insomnia claims insomnia:// too).
final class InsomniaCtlScriptTests: XCTestCase {
    private static var repoRoot: URL {
        // .../Tests/InsomniaTests/InsomniaCtlScriptTests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The id the app is built with, so the script and Info.plist cannot drift apart.
    private static var bundleID: String {
        let plist = NSDictionary(contentsOf: repoRoot.appendingPathComponent("Resources/Info.plist"))
        return plist?["CFBundleIdentifier"] as? String ?? "missing"
    }

    private let fm = FileManager.default
    private var root: URL!
    private var argsFile: URL { root.appendingPathComponent("open.args") }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("insomnia-ctl-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try stubOpen(exitStatus: 0)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    func testEachCommandOpensItsURLInThisAppInTheBackground() throws {
        let cases: [([String], String)] = [
            (["start"], "insomnia://start"),
            (["start", "8h"], "insomnia://start?seconds=28800"),
            (["start", "090"], "insomnia://start?seconds=90"),
            (["extend", "30m"], "insomnia://extend?seconds=1800"),
            (["extend", "45s"], "insomnia://extend?seconds=45"),
            (["end"], "insomnia://end"),
            (["pause"], "insomnia://pause"),
            (["resume"], "insomnia://resume"),
            (["status"], "insomnia://status"),
        ]
        XCTAssertEqual(Self.bundleID, "com.kgarg.insomnia")
        for (args, url) in cases {
            try? fm.removeItem(at: argsFile)
            let r = try run(args)
            XCTAssertEqual(r.status, 0, "\(args): \(r.stderr)")
            XCTAssertEqual(try recordedArgs(), ["-g", "-b", Self.bundleID, url], "\(args)")
        }
    }

    func testBadInputIsRefusedWithoutOpeningAnything() throws {
        for args in [[], ["start", "0"], ["start", "-5"], ["start", "8x"], ["start", "1", "2"],
                     ["extend"], ["extend", "h"], ["end", "1"], ["stop"]] {
            let r = try run(args)
            XCTAssertEqual(r.status, 2, "\(args)")
            XCTAssertTrue(r.stderr.contains("usage:"), "\(args): \(r.stderr)")
            XCTAssertFalse(fm.fileExists(atPath: argsFile.path), "\(args) opened a URL")
        }
    }

    /// A missing app (open cannot resolve the bundle id) must surface as a
    /// failure, not as a URL silently handed to another app.
    func testAnOpenFailureIsTheScriptsFailure() throws {
        try stubOpen(exitStatus: 1)

        let r = try run(["status"])

        XCTAssertEqual(r.status, 1, r.stderr)
    }

    private func stubOpen(exitStatus: Int32) throws {
        try TestScripts.write("""
            #!/bin/bash
            printf '%s\\n' "$@" > \(argsFile.path)
            exit \(exitStatus)

            """, to: root.appendingPathComponent("bin/open"))
    }

    private func recordedArgs() throws -> [String] {
        try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private func run(_ args: [String]) throws -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.repoRoot.appendingPathComponent("scripts/insomnia-ctl.sh").path] + args
        p.environment = ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin"]
        // Capture to a file rather than a pipe: nothing to drain, nothing to deadlock.
        let errURL = root.appendingPathComponent("stderr")
        fm.createFile(atPath: errURL.path, contents: nil)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? err.close() }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        let childExit = ProcessExit(p)
        try p.run()
        childExit.wait()
        return (p.terminationStatus, (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }
}
