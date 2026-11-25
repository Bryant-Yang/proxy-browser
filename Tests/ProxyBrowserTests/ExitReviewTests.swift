import XCTest
@testable import ProxyBrowser

final class ExitReviewTests: XCTestCase {
    func testExitCheckStartsBothRequestsBeforeWaitingForEither() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PairedExitResponses.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let exit = try Engine().readExit(session, expected: "US")
        XCTAssertEqual(exit.ip, "203.0.113.17")
        XCTAssertEqual(exit.country, "US")
    }

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

private final class PairedExitResponses: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var pending: [String: PairedExitResponses] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "ipv4.ipleak.net" || request.url?.host == "www.cloudflare.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host else { return }
        let pair = Self.lock.withLock {
            Self.pending[host] = self
            guard Self.pending.count == 2 else { return [PairedExitResponses]() }
            let pair = Array(Self.pending.values)
            Self.pending.removeAll()
            return pair
        }
        for response in pair { response.sendSample() }
    }

    override func stopLoading() {
        Self.lock.withLock {
            if let host = request.url?.host, Self.pending[host] === self {
                Self.pending[host] = nil
            }
        }
    }

    private func sendSample() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        let body = url.host == "ipv4.ipleak.net"
            ? #"{"ip":"203.0.113.17","country_code":"US"}"#
            : "ip=203.0.113.17\nloc=US\n"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
