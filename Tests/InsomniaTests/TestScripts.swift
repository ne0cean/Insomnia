import CryptoKit
import Foundation

/// Writes the shell scripts tests author: fakes of system tools, stand-in
/// backstops and app binaries, wrappers. A broken fake makes a test fail, or
/// pass, for the wrong reason (a fake gh that used `$10`, which bash reads
/// as `${1}0`, faked 16 failures on #51), so every one goes through here
/// and CI runs ShellCheck over them.
///
/// When INSOMNIA_TEST_SCRIPT_DUMP names a folder, each script is also copied
/// there, once per distinct text. UUIDs (the per-test temp folders) are
/// replaced with zeros first, so a fake that every fixture writes lands
/// once. A copy is named after the script and a hash of that text, and
/// index.tsv gives the source line that first wrote it. A script with no
/// `#!` line is one a test runs with /bin/bash, so its copy starts with a
/// `# shellcheck shell=bash` line.
///
/// Patched copies of the real scripts in scripts/, and harnesses built
/// from functions cut out of them, do not go through here; the ShellCheck
/// job lints the originals.
enum TestScripts {
    static let dumpKey = "INSOMNIA_TEST_SCRIPT_DUMP"

    /// Writes `text` to `url`, makes it executable (0755) unless the test
    /// runs it through an interpreter, and copies it to the dump folder.
    static func write(
        _ text: String, to url: URL, executable: Bool = true,
        file: StaticString = #fileID, line: UInt = #line
    ) throws {
        if let problem = shebangProblem(text) {
            throw ShebangError(where: "\(file):\(line)", problem: problem)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try dump(text, name: url.lastPathComponent, source: "\(file):\(line)")
    }

    struct ShebangError: Error, CustomStringConvertible {
        let `where`: String
        let problem: String
        var description: String { "\(`where`): \(problem)" }
    }

    /// Shells ShellCheck reads, by interpreter name. CI lints every script
    /// a test writes, and a zsh or relative shebang failed that job twice
    /// (SC1071, SC2239) after the tests themselves had passed; this makes
    /// the same mistake fail locally, in the test that wrote it.
    static let lintableShells: Set<String> = ["bash", "sh", "dash", "ksh"]

    /// Why ShellCheck could not lint `text`, or nil. A script with no `#!`
    /// line is linted as bash and is fine. The interpreter must be an
    /// absolute path whose name (or, through /usr/bin/env, whose argument)
    /// is one of `lintableShells`.
    static func shebangProblem(_ text: String) -> String? {
        guard text.hasPrefix("#!") else { return nil }
        let line = String(text.prefix { $0 != "\n" }.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let program = parts.first else { return "empty #! line" }
        guard program.hasPrefix("/") else { return "#!\(line): not an absolute path (ShellCheck SC2239)" }
        let name = program == "/usr/bin/env" && parts.count > 1 ? parts[1] : (program as NSString).lastPathComponent
        guard lintableShells.contains(name) else {
            return "#!\(line): ShellCheck cannot lint \(name) (SC1071); use bash, sh, dash or ksh"
        }
        return nil
    }

    private static let lock = NSLock()
    private static let uuid = try! NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

    private static func dump(_ text: String, name: String, source: String) throws {
        guard let raw = ProcessInfo.processInfo.environment[dumpKey], !raw.isEmpty else { return }
        let dir = URL(fileURLWithPath: raw, isDirectory: true)
        let normalized = uuid.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: "00000000-0000-0000-0000-000000000000")
        let lintable = normalized.hasPrefix("#!") ? normalized : "# shellcheck shell=bash\n" + normalized
        let hash = SHA256.hash(data: Data(lintable.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let copy = dir.appendingPathComponent("\(name)-\(hash)")

        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: copy.path) else { return }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // The index line goes first: a copy the index does not name would
        // never be linted, while an index line with no copy fails the lint.
        let index = dir.appendingPathComponent("index.tsv")
        if !fm.fileExists(atPath: index.path) {
            try Data().write(to: index)
        }
        let handle = try FileHandle(forWritingTo: index)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(copy.lastPathComponent)\t\(source)\n".utf8))
        try lintable.write(to: copy, atomically: true, encoding: .utf8)
    }
}
