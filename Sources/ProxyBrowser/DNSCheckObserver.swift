import Foundation

final class DNSCheckObserver: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    struct Challenge {
        struct Observations {
            let page: Set<String>
            let control: Set<String>
            let isComplete: Bool
        }

        private static let zone = "test.dnscheck.tools"
        let id: String

        init(id: String = String(UUID().uuidString.prefix(8)).lowercased()) {
            self.id = id
        }

        var pageNames: [String] {
            ["", "-compress", "-notruncate", "-compress-notruncate", "-txtfill4", "-txtfill8"].map {
                "\(id)\($0).\(Self.zone)"
            }
        }
        var controlName: String { "\(id)-txtfill64.\(Self.zone)" }
        var markerNames: [String] { [16, 32].map { "\(id)-txtfill\($0).\(Self.zone)" } }
        var addressLookupName: String { "\(UUID().uuidString.prefix(8).lowercased()).\(Self.zone)" }
        var socketURL: URL { URL(string: "wss://ws.dnscheck.tools/watch/" + id)! }

        func observations(_ byName: [String: Set<String>], healthy: Bool, completedHTTPS: Set<String>) -> Observations {
            let matched = pageNames.filter { completedHTTPS.contains($0) && !(byName[$0] ?? []).isEmpty }
            let markerSeen = markerNames.contains { !(byName[$0] ?? []).isEmpty }
            let complete = healthy && markerSeen && completedHTTPS.contains(controlName) && matched.count >= 3
            return Observations(page: Set(pageNames.flatMap { byName[$0] ?? [] }), control: byName[controlName] ?? [],
                                isComplete: complete)
        }
    }

    private struct Event: Decodable {
        let qname: String
        let remoteIp: String
    }

    private let names: Set<String>
    private let markers: Set<String>
    private let opened = DispatchSemaphore(value: 0)
    private let markerReceived = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var byName: [String: Set<String>] = [:]
    private var failed = false

    init(challenge: Challenge) {
        markers = Set(challenge.markerNames)
        names = Set(challenge.pageNames + [challenge.controlName] + challenge.markerNames)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        opened.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task is URLSessionWebSocketTask { lock.withLock { failed = true } }
    }

    func waitForOpen(until deadline: DispatchTime, stopped: () -> Bool) throws {
        try wait(opened, until: deadline, stopped: stopped)
    }

    func waitForMarker(until deadline: DispatchTime, stopped: () -> Bool) {
        _ = try? wait(markerReceived, until: deadline, stopped: stopped)
    }

    func checkpoint(_ socket: URLSessionWebSocketTask, until deadline: DispatchTime, stopped: () -> Bool) throws {
        let pong = DispatchSemaphore(value: 0)
        socket.sendPing { [weak self] error in
            if error != nil { self?.markFailed() }
            pong.signal()
        }
        try wait(pong, until: deadline, stopped: stopped)
    }

    func receive(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            guard case let .success(message) = result else { self.markFailed(); return }
            switch message {
            case let .string(value): self.record(Data(value.utf8))
            case let .data(value): self.record(value)
            @unknown default: self.markFailed(); return
            }
            if !self.lock.withLock({ self.failed }) { self.receive(socket) }
        }
    }

    func snapshot() -> (records: [String: Set<String>], healthy: Bool) {
        lock.withLock { (byName, !failed) }
    }

    private func markFailed() { lock.withLock { failed = true } }

    private func wait(_ gate: DispatchSemaphore, until deadline: DispatchTime, stopped: () -> Bool) throws {
        while !stopped() && !lock.withLock({ failed }) && DispatchTime.now() < deadline {
            if gate.wait(timeout: min(deadline, .now() + .milliseconds(100))) == .success,
               !stopped(), !lock.withLock({ failed }) { return }
        }
        throw AppFailure("备用 DNS 观察连接未就绪。")
    }

    private func record(_ data: Data) {
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else { markFailed(); return }
        let name = event.qname.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard names.contains(name) else { return }
        guard DNSLocations.isAddress(event.remoteIp) else { markFailed(); return }
        lock.withLock {
            byName[name, default: []].insert(event.remoteIp)
            if byName[name, default: []].count > 24 { failed = true }
            if markers.contains(name) { markerReceived.signal() }
        }
    }
}
