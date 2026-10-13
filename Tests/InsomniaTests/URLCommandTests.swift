import XCTest
@testable import Insomnia

final class URLCommandTests: XCTestCase {
    private func parse(_ text: String) -> URLCommand? {
        guard let url = URL(string: text) else { return nil }
        return URLCommand.parse(url)
    }

    func testStartWithoutADurationUsesTheDefaultPreset() {
        XCTAssertEqual(parse("insomnia://start"), .start(nil))
    }

    func testStartTakesSecondsOrHours() {
        XCTAssertEqual(parse("insomnia://start?seconds=28800"), .start(28800))
        XCTAssertEqual(parse("insomnia://start?hours=8"), .start(8 * 3600))
        XCTAssertEqual(parse("insomnia://start?hours=0.5"), .start(1800))
        XCTAssertEqual(parse("INSOMNIA://START?hours=1"), .start(3600), "scheme and command are case-insensitive")
    }

    func testBothUnitsAreRefused() {
        XCTAssertNil(parse("insomnia://start?seconds=60&hours=1"))
        XCTAssertNil(parse("insomnia://extend?seconds=60&hours=1"))
    }

    func testZeroNegativeAndNonNumericDurationsAreRefused() {
        XCTAssertNil(parse("insomnia://start?seconds=-60"))
        XCTAssertNil(parse("insomnia://start?hours=0"))
        XCTAssertNil(parse("insomnia://start?hours=abc"))
        XCTAssertNil(parse("insomnia://start?seconds="))
        XCTAssertNil(parse("insomnia://extend?hours=-1"))
        XCTAssertNil(parse("insomnia://extend?hours=inf"))
    }

    func testExtendNeedsADuration() {
        XCTAssertEqual(parse("insomnia://extend?hours=1"), .extend(3600))
        XCTAssertEqual(parse("insomnia://extend?seconds=90"), .extend(90))
        XCTAssertNil(parse("insomnia://extend"))
    }

    func testEndAndStatus() {
        XCTAssertEqual(parse("insomnia://end"), .end)
        XCTAssertEqual(parse("insomnia://status"), .status)
    }

    func testPauseAndResume() {
        XCTAssertEqual(parse("insomnia://pause"), .pause)
        XCTAssertEqual(parse("insomnia://resume"), .resume)
        XCTAssertEqual(parse("insomnia://pause?seconds=5"), .pause, "a query is ignored, as for end and status")
    }

    func testOtherSchemesAndCommandsAreRefused() {
        XCTAssertNil(parse("https://start?hours=1"))
        XCTAssertNil(parse("insomnia://quit"))
        XCTAssertNil(parse("insomnia:"))
    }

    /// The bundle registers the scheme the parser expects.
    func testInfoPlistRegistersTheScheme() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let types = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertEqual(schemes, [URLCommand.scheme])
    }
}
