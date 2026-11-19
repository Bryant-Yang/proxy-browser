import XCTest
@testable import ProxyBrowser

final class DNSAuditTests: XCTestCase {
    func testUsesObservedResolverAddressInsteadOfClaimedLocation() {
        let reply = Data(#"{"Status":0,"Answer":[{"type":16,"data":"ECS: 192.0.2.0/24 - US"},{"type":16,"data":"FROM: 2001:db8::12#4200 (UDP) - Test - US"}]}"#.utf8)
        XCTAssertEqual(DNSLocations.resolverAddress(reply), "2001:db8::12")
        let invalid = Data(#"{"Status":0,"Answer":[{"type":16,"data":"FROM: example.com#4200 (UDP) - US"}]}"#.utf8)
        XCTAssertNil(DNSLocations.resolverAddress(invalid))
    }

    func testEvidenceDistinguishesUnknownFromConfirmedCrossRegion() {
        let us = DNSLocations(records: [["ip": "192.0.2.7", "country": "US"]])
        let unknown = DNSLocations(records: [["ip": "192.0.2.8", "country": ""]])
        let hongKong = DNSLocations(records: [["ip": "192.0.2.9", "country": "HK"]])
        XCTAssertTrue(us.matches("US"))
        XCTAssertFalse(unknown.matches("US"))
        XCTAssertFalse(unknown.hasCrossRegion("US"))
        XCTAssertTrue(hongKong.hasCrossRegion("US"))
        XCTAssertEqual(DNSEvidence(exit: "US", tool: us, page: hongKong).summary, "出口 美国 · 工具 DNS 美国 · 网页 DNS 香港")
        XCTAssertEqual(DNSEvidence(exit: "US", tool: us, page: hongKong, downstream: hongKong).summary,
                       "出口 美国 · 工具 DNS 美国 · 下游 DNS 香港")
    }

    func testSameRegionControlCannotOverrideForeignPageDNS() {
        let us = DNSLocations(records: [["ip": "192.0.2.7", "country": "US"]])
        let hongKong = DNSLocations(records: [["ip": "192.0.2.9", "country": "HK"]])
        let evidence = DNSEvidence(exit: "US", tool: us, page: hongKong, downstream: us)
        XCTAssertEqual(evidence.checkedPage?.countries, ["HK"])
        XCTAssertTrue(CheckPresentation.locations(evidence).contains("下游 DNS  美国"))
    }
}
