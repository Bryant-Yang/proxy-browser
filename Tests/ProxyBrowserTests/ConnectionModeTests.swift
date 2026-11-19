import XCTest
@testable import ProxyBrowser

final class ConnectionModeTests: XCTestCase {
    func testOnlyOrdinaryModeCanConfirmKnownCrossRegionDNS() {
        let crossRegion = DNSLocations(records: [["country": "HK"]])
        let evidence = DNSEvidence(exit: "US", exitIP: "203.0.113.1", tool: crossRegion, page: crossRegion)

        for step in [ConnectionStep.toolDNS, .pageDNS] {
            let problem = ConnectionProblem(step: step, title: "", message: "", recovery: .selectNode, evidence: evidence)
            XCTAssertTrue(ConnectionMode.ordinary.canConfirmDNSWarning(problem, country: "US"))
            XCTAssertFalse(ConnectionMode.strict.canConfirmDNSWarning(problem, country: "US"))
            XCTAssertFalse(ConnectionMode.ordinary.canConfirmDNSWarning(problem, country: "SG"))
            XCTAssertFalse(ConnectionMode.ordinary.canConfirmDNSWarning(problem, country: ""))
        }

        let badExit = ConnectionProblem(step: .exit, title: "", message: "", recovery: .selectNode, evidence: evidence)
        XCTAssertFalse(ConnectionMode.ordinary.canConfirmDNSWarning(badExit, country: "US"))
    }

    func testInsufficientSamplesAndUnverifiedExitCannotBeConfirmed() {
        let missingCountry = DNSLocations(records: [["country": ""]])
        let crossRegion = DNSLocations(records: [["country": "HK"]])
        let evidence = [
            DNSEvidence(exit: "US", exitIP: "203.0.113.1", tool: crossRegion, page: missingCountry),
            DNSEvidence(exit: "US", tool: crossRegion, page: crossRegion)
        ]
        for report in evidence {
            let problem = ConnectionProblem(step: .pageDNS, title: "", message: "", recovery: .retry, evidence: report)
            XCTAssertFalse(ConnectionMode.ordinary.canConfirmDNSWarning(problem, country: "US"))
        }
    }

    func testToolDNSWarningRequiresCompletedPageDNS() {
        let crossRegion = DNSLocations(records: [["country": "HK"]])
        let sameRegion = DNSLocations(records: [["country": "US"]])
        let mixed = DNSLocations(records: [["country": "HK"], ["country": ""]])

        for (page, allowed) in [(nil, false), (mixed, false), (sameRegion, true)] {
            let evidence = DNSEvidence(exit: "US", exitIP: "203.0.113.1", tool: crossRegion, page: page)
            let problem = ConnectionProblem(step: .toolDNS, title: "", message: "", recovery: .selectNode, evidence: evidence)
            XCTAssertEqual(ConnectionMode.ordinary.canConfirmDNSWarning(problem, country: "US"), allowed)
        }
    }
}
