import XCTest
@testable import ProxyBrowser

final class ExitReviewTests: XCTestCase {
    func testDisagreeingLocationStaysBlockedEvenWhenSecondSourceMatches() throws {
        let primary = try XCTUnwrap(ExitLocation(ip: "203.0.113.17", country: "SC"))
        let review = try XCTUnwrap(ExitLocation(ip: primary.ip, country: "US"))
        XCTAssertThrowsError(try Engine.reviewExit(primary, expected: "US") { review }) { error in
            let problem = error as? ConnectionProblem
            XCTAssertEqual(problem?.step, .exit)
            XCTAssertEqual(problem?.title, "出口定位有分歧")
            XCTAssertTrue(problem?.message.contains("IPLeak 为塞舌尔，Cloudflare 为美国") == true)
        }
    }

    func testChangingIPAndUnavailableReviewCannotOverrideStrictCheck() throws {
        let primary = try XCTUnwrap(ExitLocation(ip: "203.0.113.17", country: "SC"))
        let otherIP = try XCTUnwrap(ExitLocation(ip: "203.0.113.18", country: "US"))
        XCTAssertThrowsError(try Engine.reviewExit(primary, expected: "US") { otherIP }) { error in
            let problem = error as? ConnectionProblem
            XCTAssertEqual(problem?.title, "出口 IP 有变化")
            XCTAssertTrue(problem?.message.contains(primary.ip) == true)
            XCTAssertTrue(problem?.message.contains(otherIP.ip) == true)
        }
        XCTAssertThrowsError(try Engine.reviewExit(primary, expected: "US") { nil })
        XCTAssertThrowsError(try Engine.reviewExit(primary, expected: "SC") { nil })
        XCTAssertThrowsError(try Engine.reviewExit(primary, expected: "") { otherIP })
        XCTAssertNoThrow(try Engine.reviewExit(primary, expected: "SC") { primary })
    }

    func testAgreedWrongExitShowsActualRegionWithoutAllowingConnection() throws {
        let actual = try XCTUnwrap(ExitLocation(ip: "203.0.113.17", country: "HK"))
        XCTAssertThrowsError(try Engine.reviewExit(actual, expected: "US") { actual }) { error in
            guard let problem = error as? ConnectionProblem else { return XCTFail("Expected an exit mismatch") }
            XCTAssertEqual(problem.confirmedExit?.ip, actual.ip)
            XCTAssertEqual(CheckPresentation(problem: problem, region: "US").message,
                           "网页出口在香港，你选择的是美国。")
        }
    }

    func testCloudflareParserUsesVisitorLocationRatherThanDataCenter() throws {
        let sample = Data("ip=203.0.113.17\r\ncolo=LAX\r\nloc=SC\r\n".utf8)
        XCTAssertEqual(ExitLocation.cloudflare(sample)?.country, "SC")
        XCTAssertNil(ExitLocation.cloudflare(Data("ip=203.0.113.17\ncolo=LAX\nloc=XX\n".utf8)))
        XCTAssertNil(ExitLocation.cloudflare(Data("ip=203.0.113.17\nloc=US\nloc=SC\n".utf8)))
    }
}
