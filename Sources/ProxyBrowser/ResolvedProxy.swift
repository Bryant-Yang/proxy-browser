import Foundation
import Network
import CFNetwork
import Darwin

/// Resolves destination names through proxied DoH, then tunnels numeric addresses.
/// TLS remains end-to-end between the browser and the destination.
final class ResolvedProxy: @unchecked Sendable {
    struct Target {
        let host: String
        let port: UInt16
        let tunnel: Bool
        let request: Data
    }
    private let upstreamPort: Int
    private let probeTargets: [String: String]
    private let queue = DispatchQueue(label: "proxy-browser.resolved-proxy")
    private let session: URLSession
    private var listener: NWListener?
    private var connections: [UUID: Tunnel] = [:]
    private var cache: [String: (String, Date)] = [:]
    private var closed = false

    init(upstreamPort: Int, probeTargets: [String: String] = [:]) {
        self.upstreamPort = upstreamPort
        self.probeTargets = probeTargets
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1, kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: upstreamPort,
            kCFNetworkProxiesHTTPSEnable as String: 1, kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: upstreamPort
        ]
        session = URLSession(configuration: config)
    }

    static func ipv4(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }

    static func answer(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["Status"] as? Int == 0,
              let records = json["Answer"] as? [[String: Any]],
              let ip = records.first(where: { ($0["type"] as? Int) == 1 && ipv4($0["data"] as? String ?? "") })?["data"] as? String else {
            throw AppFailure("加密 DNS 没有返回有效 IPv4 地址，连接已停止。")
        }
        return ip
    }

    static func target(_ header: Data) throws -> Target {
        guard let text = String(data: header, encoding: .utf8) else { throw AppFailure("代理请求格式无效。") }
        let lines = text.components(separatedBy: "\r\n")
        let words = (lines.first ?? "").split(separator: " ").map(String.init)
        guard words.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(words[2]) else { throw AppFailure("代理请求格式无效。") }
        let tunnel = words[0] == "CONNECT"
        guard let url = URLComponents(string: tunnel ? "https://" + words[1] : words[1]),
              let host = url.host, !host.isEmpty, host.utf8.count <= 253,
              !host.contains(where: { $0.isWhitespace }), url.user == nil, url.password == nil,
              tunnel || url.scheme == "http",
              let port = UInt16(exactly: url.port ?? (tunnel ? 443 : 80)), port > 0,
              !host.contains(":") else { throw AppFailure("请求地址无效或不支持 IPv6。") }
        if tunnel { return Target(host: host, port: port, tunnel: true, request: Data()) }
        let path = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        let kept = lines.dropFirst().filter { line in
            let name = line.split(separator: ":", maxSplits: 1).first?.lowercased() ?? ""
            return !line.isEmpty && !["proxy-authorization", "proxy-connection", "connection"].contains(name)
        }
        let request = ([words[0] + " " + path + " " + words[2]] + kept + ["Connection: close", "", ""]).joined(separator: "\r\n")
        return Target(host: host, port: port, tunnel: false, request: Data(request.utf8))
    }

    func start() throws -> Int {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        let gate = DispatchSemaphore(value: 0)
        var result: Result<Int, Error>?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: result = .success(Int(listener.port!.rawValue)); gate.signal()
            case .failed(let error): result = .failure(error); gate.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self, !self.closed, self.connections.count < 128 else { connection.cancel(); return }
            let tunnel = Tunnel(client: connection, owner: self)
            self.connections[tunnel.id] = tunnel
            tunnel.start()
        }
        listener.start(queue: queue)
        guard gate.wait(timeout: .now() + 5) == .success, let result = result else {
            listener.cancel(); throw AppFailure("无法启动独立 DNS 代理。")
        }
        return try result.get()
    }

    func stop() {
        queue.sync {
            closed = true; listener?.cancel()
            for tunnel in Array(connections.values) { tunnel.finish() }
            session.invalidateAndCancel()
        }
    }

    static func dnsQuery(_ host: String, type: String) -> URLRequest {
        var url = URLComponents(string: "https://8.8.8.8/resolve")!
        url.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: type)]
        var request = URLRequest(url: url.url!)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        return request
    }

    private func resolve(_ host: String, then: @escaping (String?) -> Void) {
        if let pinned = probeTargets[host] { then(pinned); return }
        if Self.ipv4(host) { then(host); return }
        if let (ip, expiry) = cache[host], expiry > Date() { then(ip); return }
        session.dataTask(with: Self.dnsQuery(host, type: "A")) { [weak self] data, response, _ in
            self?.queue.async {
                guard let self = self, !self.closed else { then(nil); return }
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
                      data.count <= 262144, let ip = try? Self.answer(data) else { then(nil); return }
                // Negative answers are not cached, and failures never use the system resolver.
                if self.cache.count >= 2048 { self.cache.removeAll() }
                self.cache[host] = (ip, Date().addingTimeInterval(30))
                then(ip)
            }
        }.resume()
    }

    private final class Tunnel {
        let id = UUID()
        let client: NWConnection
        weak var owner: ResolvedProxy?
        var upstream: NWConnection?
        var closed = false
        var deadline: DispatchWorkItem?
        init(client: NWConnection, owner: ResolvedProxy) { self.client = client; self.owner = owner }
        func finish() {
            guard !closed else { return }; closed = true
            deadline?.cancel(); client.cancel(); upstream?.cancel(); owner?.connections.removeValue(forKey: id)
        }
        func fail() {
            guard !closed else { return }
            client.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.finish() })
        }
        func start() {
            guard let owner = owner else { return }
            let timeout = DispatchWorkItem { [weak self] in self?.finish() }
            deadline = timeout; owner.queue.asyncAfter(deadline: .now() + 30, execute: timeout)
            client.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.finish() } }
            client.start(queue: owner.queue)
            readHeader(client, buffer: Data()) { [weak self] head, extra in self?.connect(head, extra: extra) }
        }
        func readHeader(_ connection: NWConnection, buffer: Data, then: @escaping (Data, Data) -> Void) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
                guard let self = self, !self.closed else { return }
                var merged = buffer; if let data = data { merged.append(data) }
                guard merged.count <= 65536, error == nil else { self.fail(); return }
                if let range = merged.range(of: Data("\r\n\r\n".utf8)) {
                    then(Data(merged[..<range.upperBound]), Data(merged[range.upperBound...])); return
                }
                guard !done else { self.finish(); return }
                self.readHeader(connection, buffer: merged, then: then)
            }
        }
        func connect(_ header: Data, extra: Data) {
            guard let owner = owner, let target = try? ResolvedProxy.target(header) else { fail(); return }
            owner.resolve(target.host) { [weak self] ip in
                guard let self = self, !self.closed, let owner = self.owner else { return }
                guard let ip = ip else { self.fail(); return }
                let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(owner.upstreamPort))!, using: .tcp)
                self.upstream = upstream
                upstream.stateUpdateHandler = { [weak self] state in
                    guard let self = self, !self.closed else { return }
                    if case .failed = state { self.fail() }
                    if case .ready = state {
                        let destination = ip + ":" + String(target.port)
                        let request = Data("CONNECT \(destination) HTTP/1.1\r\nHost: \(destination)\r\n\r\n".utf8)
                        upstream.send(content: request, completion: .contentProcessed { [weak self] error in
                            guard let self = self, !self.closed else { return }
                            guard error == nil else { self.fail(); return }
                            self.readHeader(upstream, buffer: Data()) { [weak self] response, tail in
                                guard let self = self, !self.closed else { return }
                                let status = String(data: response, encoding: .utf8)?.components(separatedBy: "\r\n").first?.split(separator: " ")
                                guard status?.count ?? 0 >= 2, status?[1] == "200" else { self.fail(); return }
                                self.deadline?.cancel()
                                let reply = target.tunnel ? Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8) + tail : tail
                                self.client.send(content: reply.isEmpty ? nil : reply, completion: .contentProcessed { [weak self] error in
                                    guard let self = self, !self.closed else { return }
                                    guard error == nil else { self.finish(); return }
                                    let initial = target.request + extra
                                    upstream.send(content: initial.isEmpty ? nil : initial, completion: .contentProcessed { [weak self] error in
                                        guard let self = self, !self.closed else { return }
                                        guard error == nil else { self.finish(); return }
                                        self.pump(self.client, to: upstream); self.pump(upstream, to: self.client)
                                    })
                                })
                            }
                        })
                    }
                }
                upstream.start(queue: owner.queue)
            }
        }
        func pump(_ from: NWConnection, to: NWConnection) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self = self, !self.closed else { return }
                guard error == nil else { self.finish(); return }
                to.send(content: data, isComplete: done, completion: .contentProcessed { [weak self] error in
                    guard let self = self, !self.closed else { return }
                    if error != nil || done { self.finish() } else { self.pump(from, to: to) }
                })
            }
        }
    }
}
