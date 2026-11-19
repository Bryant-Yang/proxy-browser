import Darwin
import XCTest
@testable import ProxyBrowser

final class ListenerOwnershipTests: XCTestCase {
    func testOnlyTheOwningProcessWithAListeningSocketIsReady() {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return XCTFail("Could not create test socket") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = UInt8(AF_INET)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                XCTAssertEqual(Darwin.bind(descriptor, socketAddress, size), 0)
                var length = size
                XCTAssertEqual(getsockname(descriptor, socketAddress, &length), 0)
            }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertFalse(Engine.ownsLoopbackListener(pid: getpid(), port: port))
        XCTAssertEqual(listen(descriptor, 1), 0)
        XCTAssertTrue(Engine.ownsLoopbackListener(pid: getpid(), port: port))
        XCTAssertFalse(Engine.ownsLoopbackListener(pid: getppid(), port: port))
    }
}
