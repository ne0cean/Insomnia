import Foundation

enum ShellTimeoutError: Error, LocalizedError {
    case timedOut(exe: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .timedOut(exe, seconds):
            return "\(exe) did not finish within \(Int(seconds)) s"
        }
    }
}

extension Shell {
    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ p: Process) { process = p }
    }

    /// An unlinked temp file the child writes its output to. Not a pipe: a
    /// pipe's read end sees EOF only when every writer has closed, so a
    /// descendant the child left running (`cmd &` without a redirect) would
    /// hold the reader, and the timeout, until it exited. A file has no EOF to
    /// wait for; the output is read once the child itself has exited.
    private static func outputFile() throws -> (writer: FileHandle, reader: FileHandle) {
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("insomnia-shell-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw ShellError.launchFailed(exe: "output file", underlying: String(decoding: Data(bytes: strerror(errno), count: strlen(strerror(errno))), as: UTF8.self)) }
        let path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        defer { unlink(path) }
        guard let reader = FileHandle(forReadingAtPath: path) else {
            close(fd)
            throw ShellError.launchFailed(exe: "output file", underlying: "cannot reopen \(path)")
        }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), reader)
    }

    /// `Shell.run` with a wall-clock limit. On timeout the child is killed
    /// (SIGTERM, then SIGKILL) and `ShellTimeoutError.timedOut` is thrown.
    /// The limit holds when the child exits but leaves descendants holding
    /// its stdout/stderr: output goes to files, so nothing waits for them.
    /// The descendants are left alone (a hook may background a tunnel on
    /// purpose); only the child is killed at the limit.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exe)
                process.arguments = args
                process.standardInput = FileHandle.nullDevice
                let out: (writer: FileHandle, reader: FileHandle)
                let err: (writer: FileHandle, reader: FileHandle)
                do {
                    out = try outputFile()
                    err = try outputFile()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                process.standardOutput = out.writer
                process.standardError = err.writer
                let childExit = ProcessExit(process)

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ShellError.launchFailed(exe: exe, underlying: error.localizedDescription))
                    return
                }
                // The child has its own copies; ours would only leak.
                try? out.writer.close()
                try? err.writer.close()

                let box = ProcessBox(process)
                let killer = DispatchWorkItem {
                    guard box.process.isRunning else { return }
                    box.process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                childExit.wait()
                let timedOut = !killer.isCancelled && process.terminationReason == .uncaughtSignal
                killer.cancel()

                if timedOut {
                    continuation.resume(throwing: ShellTimeoutError.timedOut(exe: exe, seconds: timeout))
                    return
                }
                continuation.resume(returning: ShellResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: out.reader.readDataToEndOfFile(), as: UTF8.self),
                    stderr: String(decoding: err.reader.readDataToEndOfFile(), as: UTF8.self)
                ))
            }
        }
    }

    /// First existing path among `candidates`, or nil.
    static func locate(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
