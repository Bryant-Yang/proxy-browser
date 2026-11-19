import XCTest
@testable import ProxyBrowser

final class DNSSamplingTests: XCTestCase {
    func testEmptyRepliesAreReplacedWithFreshSamples() throws {
        let replies: [[String: Any]] = [
            ["ip": []],
            ["ip": ["192.0.2.10": 1]],
            ["ip": [String: Any]()],
            ["ip": ["192.0.2.20": 1]],
            ["ip": ["192.0.2.10": 1]]
        ]
        var attempts: [Int] = []
        var retries: [Int] = []
        let result = try Engine.collectDNSResolvers { attempt in
            attempts.append(attempt)
            return replies[attempt - 1]
        } retrying: { retry, _ in
            retries.append(retry)
        }
        XCTAssertEqual(attempts, [1, 2, 3, 4, 5])
        XCTAssertEqual(retries, [1, 2])
        XCTAssertEqual(result, Set(["192.0.2.10", "192.0.2.20"]))
    }

    func testExhaustedRetryBudgetRejectsPartialResults() {
        var attempts = 0
        var retries = 0
        XCTAssertThrowsError(try Engine.collectDNSResolvers { attempt in
            attempts += 1
            return ["ip": attempt == 1 ? ["192.0.2.10": 1] as Any : [] as Any]
        } retrying: { _, _ in retries += 1 })
        XCTAssertEqual(attempts, 5)
        XCTAssertEqual(retries, 3)
    }
}
