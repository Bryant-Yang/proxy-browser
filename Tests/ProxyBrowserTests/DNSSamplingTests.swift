import XCTest
@testable import ProxyBrowser

final class DNSSamplingTests: XCTestCase {
    func testGeolocationFailureRetainsOtherObservedCountries() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PartialGeolocation.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let evidence = try Engine().locate(["192.0.2.10", "192.0.2.20"], via: session, deadline: .now() + 3)
        XCTAssertTrue(evidence.hasCrossRegion("US"))
        XCTAssertFalse(evidence.hasKnownCountries)
    }

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
        var streaks: [Int] = []
        let result = try Engine.collectDNSResolvers { attempt in
            attempts.append(attempt)
            return replies[attempt - 1]
        } retrying: { retry, _, streak in
            retries.append(retry)
            streaks.append(streak)
        }
        XCTAssertEqual(attempts, [1, 2, 3, 4, 5])
        XCTAssertEqual(retries, [1, 2])
        XCTAssertEqual(streaks, [1, 1])
        XCTAssertEqual(result, Set(["192.0.2.10", "192.0.2.20"]))
    }

    func testExhaustedRetryBudgetRejectsPartialResults() {
        var attempts = 0
        var retries = 0
        XCTAssertThrowsError(try Engine.collectDNSResolvers { attempt in
            attempts += 1
            return ["ip": attempt == 1 ? ["192.0.2.10": 1] as Any : [] as Any]
        } retrying: { _, _, _ in retries += 1 }) { error in
            XCTAssertEqual((error as? IncompleteDNSSamples)?.addresses, ["192.0.2.10"])
        }
        XCTAssertEqual(attempts, 5)
        XCTAssertEqual(retries, 3)
    }

    func testBackupRunsWhilePrimaryCanStillComplete() throws {
        let exit = try XCTUnwrap(ExitLocation(ip: "203.0.113.1", country: "US"))
        let tool = DNSLocations(records: [["ip": "192.0.2.10", "country": "US"]])
        let initial = DNSEvidence(exit: exit.country, exitIP: exit.ip, tool: tool)
        let backupFinished = DispatchSemaphore(value: 0)
        let starts = NSLock()
        var backupCount = 0
        let result = try Engine().probeDNS(exit: exit) { startBackup in
            startBackup(.pageDNS, initial)
            startBackup(.pageDNS, initial)
            XCTAssertEqual(backupFinished.wait(timeout: .now() + 2), .success)
            throw ConnectionProblem(step: .pageDNS, title: "", message: "", recovery: .retry, evidence: initial)
        } backup: { _, seed, _ in
            starts.withLock { backupCount += 1 }
            var result = seed
            result.page = tool
            backupFinished.signal()
            return result
        }
        XCTAssertEqual(starts.withLock { backupCount }, 1)
        XCTAssertEqual(result.evidence.page?.countries, ["US"])
    }

    func testACompletedCheckCannotOverrideConfirmedForeignObservations() throws {
        let exit = try XCTUnwrap(ExitLocation(ip: "203.0.113.1", country: "US"))
        let same = DNSLocations(records: [["ip": "192.0.2.10", "country": "US"]])
        let foreign = DNSLocations(records: [["ip": "192.0.2.11", "country": "DE"]])
        let initial = DNSEvidence(exit: exit.country, exitIP: exit.ip, tool: same)
        let observedForeign = DispatchSemaphore(value: 0)
        XCTAssertThrowsError(try Engine().probeDNS(exit: exit) { startBackup in
            startBackup(.pageDNS, initial)
            XCTAssertEqual(observedForeign.wait(timeout: .now() + 2), .success)
            var complete = initial
            complete.page = same
            return ProbeResult(exitIP: exit.ip, country: exit.country, dns: same.records, evidence: complete)
        } backup: { _, seed, observe in
            var complete = seed
            complete.page = same
            complete.downstream = foreign
            observe(complete)
            observedForeign.signal()
            return complete
        }) { error in
            let problem = error as? ConnectionProblem
            XCTAssertEqual(problem?.recovery, .selectNode)
            XCTAssertEqual(problem?.evidence?.downstream?.countries, ["DE"])
        }
    }

    func testBackupCanReuseToolResultObtainedAfterItStarted() throws {
        let exit = try XCTUnwrap(ExitLocation(ip: "203.0.113.1", country: "US"))
        let same = DNSLocations(records: [["ip": "192.0.2.10", "country": "US"]])
        let initial = DNSEvidence(exit: exit.country, exitIP: exit.ip)
        let lock = NSLock()
        var starts = 0
        let result = try Engine().probeDNS(exit: exit) { startBackup in
            startBackup(.toolDNS, initial)
            var toolVerified = initial
            toolVerified.tool = same
            throw ConnectionProblem(step: .pageDNS, title: "", message: "", recovery: .retry, evidence: toolVerified)
        } backup: { _, seed, _ in
            lock.withLock { starts += 1 }
            XCTAssertNil(seed.tool)
            var complete = seed
            complete.page = same
            return complete
        }
        XCTAssertEqual(result.evidence.tool?.countries, ["US"])
        XCTAssertEqual(result.evidence.page?.countries, ["US"])
        XCTAssertEqual(lock.withLock { starts }, 1)
    }

    func testCompleteBackupKeepsForeignDNSFromIncompletePrimary() throws {
        let exit = try XCTUnwrap(ExitLocation(ip: "203.0.113.1", country: "US"))
        let same = DNSLocations(records: [["ip": "192.0.2.10", "country": "US"]])
        let foreign = DNSLocations(records: [["ip": "192.0.2.11", "country": "DE"]])
        let partial = DNSEvidence(exit: exit.country, exitIP: exit.ip, tool: same, page: foreign)
        XCTAssertThrowsError(try Engine().probeDNS(exit: exit) { _ in
            throw ConnectionProblem(step: .pageDNS, title: "", message: "", recovery: .retry, evidence: partial)
        } backup: { _, seed, _ in
            var complete = seed
            complete.page = same
            return complete
        }) { error in
            let problem = error as? ConnectionProblem
            XCTAssertEqual(problem?.recovery, .selectNode)
            XCTAssertEqual(Set(problem?.evidence?.page?.countries ?? []), ["US", "DE"])
        }
    }

    func testDefinitivePrimaryWarningKeepsConfirmedBackupObservations() throws {
        let exit = try XCTUnwrap(ExitLocation(ip: "203.0.113.1", country: "US"))
        let same = DNSLocations(records: [["ip": "192.0.2.10", "country": "US"]])
        let foreignTool = DNSLocations(records: [["ip": "192.0.2.11", "country": "DE"]])
        let foreignPage = DNSLocations(records: [["ip": "192.0.2.12", "country": "HK"]])
        let initial = DNSEvidence(exit: exit.country, exitIP: exit.ip)
        let observedForeign = DispatchSemaphore(value: 0)
        XCTAssertThrowsError(try Engine().probeDNS(exit: exit) { startBackup in
            startBackup(.toolDNS, initial)
            XCTAssertEqual(observedForeign.wait(timeout: .now() + 2), .success)
            var complete = initial
            complete.tool = same
            complete.page = foreignPage
            throw ConnectionProblem(step: .pageDNS, title: "", message: "", recovery: .selectNode, evidence: complete)
        } backup: { _, seed, observe in
            var partial = seed
            partial.tool = foreignTool
            observe(partial)
            observedForeign.signal()
            throw ConnectionProblem(step: .pageDNS, title: "", message: "", recovery: .retry, evidence: partial)
        }) { error in
            let problem = error as? ConnectionProblem
            XCTAssertEqual(problem?.step, .pageDNS)
            XCTAssertEqual(problem?.recovery, .selectNode)
            XCTAssertEqual(Set(problem?.evidence?.tool?.countries ?? []), ["US", "DE"])
            XCTAssertEqual(problem?.evidence?.page?.countries, ["HK"])
        }
    }

    func testBackupPageCannotPassWithPartialToolEvidence() throws {
        let exit = try XCTUnwrap(ExitLocation(ip: "203.0.113.1", country: "US"))
        let same = DNSLocations(records: [["ip": "192.0.2.10", "country": "US"]])
        let partial = DNSEvidence(exit: exit.country, exitIP: exit.ip, tool: same)
        XCTAssertThrowsError(try Engine().probeDNS(exit: exit) { _ in
            throw ConnectionProblem(step: .toolDNS, title: "", message: "", recovery: .retry, evidence: partial)
        } backup: { _, seed, _ in
            XCTAssertNil(seed.tool)
            var complete = seed
            complete.page = same
            return complete
        }) { error in
            let problem = error as? ConnectionProblem
            XCTAssertEqual(problem?.recovery, .retry)
            XCTAssertEqual(problem?.step, .toolDNS)
        }
    }

    func testBackupRequiresMatchingHTTPSAndDNSForThreeFreshNamesAndACompletedControl() {
        let challenge = DNSCheckObserver.Challenge(id: "0123abcd")
        let names = challenge.pageNames
        let resolver = "192.0.2.1"
        var received = [names[0]: [resolver], names[1]: [resolver], names[2]: [resolver],
                        names[3]: ["192.0.2.2"], challenge.controlName: ["192.0.2.3"]].mapValues(Set.init)
        let completed = Set(Array(names.prefix(3)) + [challenge.controlName])

        XCTAssertFalse(challenge.observations(received, healthy: true, completedHTTPS: completed).isComplete)
        received[challenge.markerNames[0]] = ["192.0.2.4"]
        let missingControl = challenge.observations(received, healthy: true, completedHTTPS: Set(names))
        XCTAssertFalse(missingControl.isComplete)
        XCTAssertEqual(missingControl.control, ["192.0.2.3"])
        let incomplete = challenge.observations(received, healthy: true, completedHTTPS: [names[0], names[1], challenge.controlName])
        XCTAssertFalse(incomplete.isComplete)
        XCTAssertEqual(incomplete.page, [resolver, "192.0.2.2"])
        XCTAssertFalse(challenge.observations(received, healthy: false, completedHTTPS: completed).isComplete)
        let proof = challenge.observations(received, healthy: true, completedHTTPS: completed)
        XCTAssertTrue(proof.isComplete)
        XCTAssertEqual(proof.page, [resolver, "192.0.2.2"])
        XCTAssertEqual(proof.control, ["192.0.2.3"])

        received[challenge.controlName] = nil
        let noControlDNS = challenge.observations(received, healthy: true, completedHTTPS: completed)
        XCTAssertTrue(noControlDNS.isComplete)
        XCTAssertTrue(noControlDNS.control.isEmpty)
    }
}

private final class PartialGeolocation: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ipleak.net" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let status = url.lastPathComponent == "192.0.2.10" ? 200 : 503
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"country_code":"DE"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
