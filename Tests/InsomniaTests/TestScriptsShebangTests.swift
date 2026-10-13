import XCTest
@testable import Insomnia

/// `TestScripts.write` refuses a script ShellCheck cannot lint, so the
/// mistake fails in the test that wrote it instead of in CI's lint step
/// after every test has passed (twice on 2026-10-13: a zsh and a `#!bash`
/// fixture).
final class TestScriptsShebangTests: XCTestCase {
    func testLintableShebangsPass() {
        for text in ["#!/bin/bash\necho", "#!/bin/sh -e\necho", "#!/usr/bin/env bash\necho", "#!/bin/A=B/sh\necho", "echo no shebang"] {
            XCTAssertNil(TestScripts.shebangProblem(text), text)
        }
    }

    func testUnlintableShebangsAreNamed() {
        XCTAssertNotNil(TestScripts.shebangProblem("#!/bin/zsh\nprint"))
        XCTAssertNotNil(TestScripts.shebangProblem("#!bash\necho"))
        XCTAssertNotNil(TestScripts.shebangProblem("#!/usr/bin/env python3\nprint()"))
        XCTAssertNotNil(TestScripts.shebangProblem("#!\necho"))
    }

    func testWriteRefusesBeforeTouchingDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shebang-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try TestScripts.write("#!/bin/zsh\nprint hi\n", to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
