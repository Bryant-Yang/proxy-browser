import XCTest
import Network
import Darwin
@testable import ProxyBrowser

final class ResolvedProxyTests: XCTestCase {
    func testDoHFailureAndNonAddressAnswersFailClosed() throws {
        for json in [#"{"Status":3,"Answer":[{"type":1,"data":"203.0.113.7"}]}"#,
                     #"{"Status":0,"Answer":[{"type":5,"data":"example.com"}]}"#,
                     #"{"Status":0,"Answer":[{"type":1,"data":"example.com"}]}"#] {
            XCTAssertThrowsError(try ResolvedProxy.answer(Data(json.utf8)))
        }
        XCTAssertEqual(try ResolvedProxy.answer(Data(#"{"Status":0,"Answer":[{"type":1,"data":"203.0.113.7"}]}"#.utf8)), "203.0.113.7")
    }
    func testHTTPPreservesOriginAndRemovesProxyCredentials() throws {
        let target = try ResolvedProxy.target(Data("GET http://example.com/path?q=1 HTTP/1.1\r\nHost: example.com\r\nProxy-Authorization: Basic private\r\nProxy-Connection: keep-alive\r\n\r\n".utf8))
        XCTAssertEqual(target.host, "example.com"); XCTAssertEqual(target.port, 80)
        let text = String(decoding: target.request, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /path?q=1 HTTP/1.1\r\nHost: example.com\r\n"))
        XCTAssertTrue(text.contains("Connection: close")); XCTAssertFalse(text.contains("private"))
    }
    func testMalformedTargetsAreRejected() {
        for header in ["CONNECT example.com:0 HTTP/1.1\r\n\r\n", "CONNECT [::1]:443 HTTP/1.1\r\n\r\n",
                       "GET https://example.com/ HTTP/1.1\r\n\r\n", "GET http://user:password@example.com/ HTTP/1.1\r\n\r\n"] {
            XCTAssertThrowsError(try ResolvedProxy.target(Data(header.utf8)))
        }
    }
    func testDiagnosticHostTunnelsItsPinnedAddressAndStopsListener() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let upstream = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "test.upstream")
        let ready = expectation(description: "upstream ready")
        let observed = expectation(description: "numeric destination received")
        let payload = expectation(description: "opaque bytes forwarded")
        var retained: NWConnection?
        upstream.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        upstream.newConnectionHandler = { connection in
            retained = connection
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                XCTAssertEqual(String(decoding: data ?? Data(), as: UTF8.self), "CONNECT 203.0.113.7:443 HTTP/1.1\r\nHost: 203.0.113.7:443\r\n\r\n")
                observed.fulfill()
                connection.send(content: Data("HTTP/1.1 200 OK\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, _ in
                        XCTAssertEqual(data, Data([0x16, 0x03, 0x01, 0xff])); payload.fulfill()
                        connection.send(content: data, completion: .contentProcessed { _ in })
                    }
                })
            }
        }
        upstream.start(queue: queue); wait(for: [ready], timeout: 3)
        let relay = ResolvedProxy(upstreamPort: Int(upstream.port!.rawValue), probeTargets: ["original.example": "203.0.113.7"])
        let port = try relay.start()
        defer { relay.stop(); upstream.cancel(); retained?.cancel() }
        let fd = socket(AF_INET, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(result, 0)
        let header = Data("CONNECT original.example:443 HTTP/1.1\r\nHost: original.example\r\n\r\n".utf8)
        _ = header.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, header.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &buffer, buffer.count)
        XCTAssertGreaterThan(count, 0)
        if count > 0 { XCTAssertTrue(String(decoding: buffer.prefix(count), as: UTF8.self).contains("200 Connection Established")) }
        let bytes: [UInt8] = [0x16, 0x03, 0x01, 0xff]
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, bytes.count) }
        let echoed = Darwin.read(fd, &buffer, buffer.count)
        XCTAssertEqual(echoed, bytes.count)
        if echoed > 0 { XCTAssertEqual(Array(buffer.prefix(echoed)), bytes) }
        wait(for: [observed, payload], timeout: 3)
    }
}
