import XCTest
@testable import ProxyBrowser

final class CheckPresentationTests: XCTestCase {
    func testConclusionShowsOnlyForeignRegionsAndKeepsDiagnosticsAvailable() {
        let tool = DNSLocations(records: [["ip": "192.0.2.7", "country": "US"]])
        let page = DNSLocations(records: [["ip": "192.0.2.8", "country": "US"],
                                          ["ip": "192.0.2.9", "country": "HK"]])
        let evidence = DNSEvidence(exit: "US", exitIP: "203.0.113.1", tool: tool, page: page, downstream: page)
        let problem = ConnectionProblem(step: .pageDNS, title: "代理下游 DNS 跨区",
                                        message: evidence.summary, recovery: .selectNode, evidence: evidence)

        let copy = CheckPresentation(problem: problem, region: "US")
        XCTAssertEqual(copy.rowLabel, "地区不符")
        XCTAssertEqual(copy.message, "网页出口在美国，但检测到这条线路也会在香港查询网站地址。")
        let details = CheckPresentation.details(problem: problem)
        for text in ["203.0.113.1", "192.0.2.7", "192.0.2.9", "工具 DNS", "网页 DNS", "下游 DNS"] {
            XCTAssertTrue(details.contains(text))
        }
    }

    func testIncompleteCheckDoesNotClaimAForeignRegion() {
        let evidence = DNSEvidence(exit: "US", page: DNSLocations(records: [["ip": "192.0.2.9", "country": ""]]))
        let problem = ConnectionProblem(step: .pageDNS, title: "网页 DNS 待确认",
                                        message: "样本不足", recovery: .retry, evidence: evidence)
        let copy = CheckPresentation(problem: problem, region: "US")
        XCTAssertEqual(copy.title, "网页 DNS 待确认")
        XCTAssertEqual(copy.message, "样本不足")
        XCTAssertEqual(copy.rowLabel, "待确认")
        XCTAssertTrue(CheckPresentation.details(problem: problem).contains("样本不足"))
    }
}
