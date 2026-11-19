import Foundation
import CFNetwork
import CryptoKit
import Darwin

struct ConnectionRequest {
    let source: URL
    let node: String
    let core: URL
    let browser: URL
    let country: String
}
struct ProbeResult {
    let exitIP: String
    let country: String
    let dns: [[String: String]]
    let evidence: DNSEvidence
}

struct ExitLocation {
    let ip: String
    let country: String

    init?(ip: String?, country: String?) {
        guard let ip, ResolvedProxy.ipv4(ip), let country, country.count == 2,
              Locale.Region.isoRegions.contains(Locale.Region(country)) else { return nil }
        self.ip = ip
        self.country = country
    }

    static func cloudflare(_ body: Data) -> ExitLocation? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0] == "ip" || pair[0] == "loc" else { continue }
            let key = String(pair[0])
            guard fields[key] == nil else { return nil }
            fields[key] = String(pair[1])
        }
        return ExitLocation(ip: fields["ip"], country: fields["loc"])
    }
}

struct RegionCheckRequest {
    let source: URL
    let nodes: [String]
    let core: URL
    let country: String
}

struct NodeCheck {
    let name: String
    let websiteReachable: Bool?
    let result: Result<ProbeResult, ConnectionProblem>

    var canUse: Bool {
        if case .success = result { return true }
        return false
    }
}

enum ConnectionStep: Int {
    case prepare, exit, toolDNS, pageDNS, browser
}

enum ConnectionUpdate {
    case checking(ConnectionStep, String, DNSEvidence? = nil)
    case opening(ProbeResult, String, pid_t)
}

struct ConnectionProblem: LocalizedError {
    enum Recovery { case retry, selectNode, allRegions, settings, importConfig }
    let step: ConnectionStep
    let title: String
    let message: String
    let recovery: Recovery
    let evidence: DNSEvidence?
    let confirmedExit: ExitLocation?
    var errorDescription: String? { message }

    init(step: ConnectionStep, title: String, message: String, recovery: Recovery,
         evidence: DNSEvidence? = nil, confirmedExit: ExitLocation? = nil) {
        self.step = step
        self.title = title
        self.message = message
        self.recovery = recovery
        self.evidence = evidence
        self.confirmedExit = confirmedExit
    }
}

final class Engine: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var reopen = false
    private var proxy: Process?
    private var browser: Process?
    private var resolvedProxy: ResolvedProxy?
    private var logs: [FileHandle] = []
    private var state: [String: Any] = [:]
    private let notify: (ConnectionUpdate) -> Void
    private let finished: (ConnectionProblem?) -> Void
    private let parentStopped: () -> Bool
    static let startURL = "https://ipleak.net/"

    init(notify: @escaping (ConnectionUpdate) -> Void = { _ in },
         finished: @escaping (ConnectionProblem?) -> Void = { _ in },
         parentStopped: @escaping () -> Bool = { false }) {
        self.notify = notify
        self.finished = finished
        self.parentStopped = parentStopped
    }

    func stop() { lock.lock(); cancelled = true; lock.unlock() }
    func openPage() { lock.lock(); reopen = true; lock.unlock() }
    private var stopped: Bool {
        lock.lock()
        let local = cancelled
        lock.unlock()
        return local || parentStopped()
    }
    private func consumeOpen() -> Bool { lock.lock(); defer { lock.unlock() }; let value = reopen; reopen = false; return value }

    static func validateCountries(exit: String, expected: String, dns: [String]) throws {
        guard exit.count == 2, !dns.isEmpty else { throw AppFailure("出口或 DNS 检测未得到有效结果。") }
        guard expected.isEmpty || exit == expected else { throw AppFailure("出口地区为 \(exit)，与选择的目标地区不一致。") }
        guard dns.allSatisfy({ $0 == exit }) else {
            throw AppFailure("DNS 地区与出口不一致，已停止启动；可以更换节点后重试。")
        }
    }

    private func writeState(_ changes: [String: Any]) {
        state.merge(changes, uniquingKeysWith: { _, new in new })
        state["updated"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Configuration.support.appendingPathComponent("current-run.json"), options: .atomic)
        }
    }

    private func port() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppFailure("无法创建本地连接。") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw AppFailure("无法分配本地代理端口。") }
        var count = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &count) }
        }
        guard result == 0 else { throw AppFailure("无法读取本地代理端口。") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private func launch(_ executable: URL, _ arguments: [String], log: URL) throws -> Process {
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        logs.append(handle)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }

    private func end(_ child: Process?) {
        guard let child = child, child.isRunning else { return }
        child.terminate()
        for _ in 0..<60 {
            if !child.isRunning { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // Retains the actual Process object; never targets a name or a saved PID.
        if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
    }

    private func session(port: Int) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: port
        ]
        return URLSession(configuration: configuration)
    }

    private func fetchData(_ session: URLSession, _ url: String, deadline: DispatchTime,
                           expectedStatus: Int = 200) throws -> Data {
        try fetchData(session, URLRequest(url: URL(string: url)!), deadline: deadline, expectedStatus: expectedStatus)
    }

    private func fetchData(_ session: URLSession, _ request: URLRequest, deadline: DispatchTime,
                           expectedStatus: Int = 200) throws -> Data {
        if stopped { throw AppFailure("启动已取消。") }
        let now = DispatchTime.now()
        guard now < deadline else { throw AppFailure("检测服务响应超时。") }
        let limit = min(deadline, now + 14)
        let gate = DispatchSemaphore(value: 0)
        var received: Data?
        var status = 0
        let task = session.dataTask(with: request) { data, response, _ in
            received = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            gate.signal()
        }
        task.resume()
        while gate.wait(timeout: min(limit, .now() + .milliseconds(100))) != .success {
            if stopped || DispatchTime.now() >= limit {
                task.cancel()
                throw AppFailure(stopped ? "连接已取消。" : "检测服务响应超时。")
            }
        }
        guard status == expectedStatus, let received, received.count <= 262144 else {
            throw AppFailure("检查服务暂不可用，或所选节点连接失败。")
        }
        return received
    }

    private func fetch(_ session: URLSession, _ url: String, deadline: DispatchTime) throws -> [String: Any] {
        let data = try fetchData(session, url, deadline: deadline)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppFailure("检查服务返回了无法识别的结果。")
        }
        return object
    }

    static func collectDNSResolvers(sample: (Int) throws -> [String: Any],
                                    retrying: (Int, Int) -> Void) throws -> Set<String> {
        let requiredSamples = 3
        let retryLimit = 3
        var successfulSamples = 0
        var emptySamples = 0
        var resolvers = Set<String>()

        // Each attempt gets a fresh DNS hostname. An empty reply cannot count as a sample.
        for attempt in 1...(requiredSamples + retryLimit) {
            let reply = try sample(attempt)
            if let found = reply["ip"] as? [String: Any], !found.isEmpty {
                resolvers.formUnion(found.keys)
                successfulSamples += 1
                if successfulSamples == requiredSamples { return resolvers }
                continue
            }
            let emptyDictionary = (reply["ip"] as? [String: Any])?.isEmpty == true
            let emptyArray = (reply["ip"] as? [Any])?.isEmpty == true
            guard emptyDictionary || emptyArray else {
                throw AppFailure("DNS 检测返回了无法识别的样本。")
            }
            emptySamples += 1
            guard emptySamples <= retryLimit else { break }
            retrying(emptySamples, retryLimit)
        }
        throw AppFailure("DNS 补测后仍未取得足够的解析器样本。")
    }

    static func reviewExit(_ primary: ExitLocation, expected: String, secondary: () -> ExitLocation?) throws {
        let actual = NodeRegions.name(primary.country)
        let target = NodeRegions.name(expected)
        guard let other = secondary() else {
            throw ConnectionProblem(step: .exit, title: "出口复核未完成",
                                    message: "IPLeak 显示\(actual)（\(primary.ip)），Cloudflare 暂无有效结果。请重试。",
                                    recovery: .retry)
        }
        let regions = "IPLeak 为\(actual)，Cloudflare 为\(NodeRegions.name(other.country))。"
        if other.ip != primary.ip {
            throw ConnectionProblem(step: .exit, title: "出口 IP 有变化",
                                    message: "两个服务看到不同出口 IP。\(regions)\nIPLeak  \(primary.ip)\nCloudflare  \(other.ip)",
                                    recovery: .retry)
        }
        if other.country != primary.country {
            throw ConnectionProblem(step: .exit, title: "出口定位有分歧",
                                    message: "同一出口 IP（\(primary.ip)），\(regions)", recovery: .selectNode)
        }
        guard expected.isEmpty || primary.country == expected else {
            throw ConnectionProblem(step: .exit, title: "出口与地区筛选不符",
                                    message: "两个来源均显示\(actual)（\(primary.ip)），所选地区为\(target)。",
                                    recovery: .selectNode, confirmedExit: primary)
        }
    }

    private func readExit(_ session: URLSession, expected: String) throws -> ExitLocation {
        let deadline = DispatchTime.now() + 24
        notify(.checking(.exit, "正在用两个服务确认实际出口。"))
        var openProblem: ConnectionProblem?
        for attempt in 1...2 {
            guard !stopped, DispatchTime.now() < deadline else { break }
            let limit = min(deadline, .now() + 6)
            if let response = try? fetch(session, "https://ipv4.ipleak.net/json/", deadline: limit),
               let address = ExitLocation(ip: response["ip"] as? String, country: response["country_code"] as? String) {
                do {
                    try Self.reviewExit(address, expected: expected) {
                        guard let trace = try? fetchData(session, "https://www.cloudflare.com/cdn-cgi/trace",
                                                         deadline: min(deadline, .now() + 6)) else { return nil }
                        return ExitLocation.cloudflare(trace)
                    }
                    return address
                } catch let problem as ConnectionProblem {
                    openProblem = problem
                }
            }
            if attempt == 1, !stopped {
                notify(.checking(.exit, "正在重新核对出口。"))
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        throw openProblem ?? ConnectionProblem(step: .exit, title: "未取得出口信息",
                                               message: "节点或出口检测服务响应异常。请重试。", recovery: .retry)
    }

    private func locate(_ addresses: Set<String>, via session: URLSession,
                        deadline: DispatchTime) throws -> DNSLocations {
        let records = try addresses.sorted().map { address in
            guard DNSLocations.isAddress(address) else { throw AppFailure("DNS 样本地址无效。") }
            let location = try fetch(session, "https://ipleak.net/json/" + address, deadline: deadline)
            let country = location["country_code"] as? String ?? ""
            return ["ip": address, "country": Locale.Region.isoRegions.contains(Locale.Region(country)) ? country : ""]
        }
        return DNSLocations(records: records)
    }

    private func measureToolDNS(core: URLSession, relay: URLSession, evidence: DNSEvidence, deadline: DispatchTime) throws -> DNSLocations {
        let addresses = try Self.collectDNSResolvers { _ in
            let name = String(UUID().uuidString.lowercased().prefix(8)) + ".test.dnscheck.tools"
            guard let data = try? fetchData(core, ResolvedProxy.dnsQuery(name, type: "TXT"), deadline: deadline),
                  let address = DNSLocations.resolverAddress(data) else { return ["ip": []] }
            return ["ip": [address: 1]]
        } retrying: { retry, limit in
            notify(.checking(.toolDNS, "正在补测工具 DNS 样本（\(retry)/\(limit)）。", evidence))
        }
        return try locate(addresses, via: relay, deadline: deadline)
    }

    private func measurePageDNS(_ session: URLSession, evidence: DNSEvidence,
                                deadline: DispatchTime) throws -> DNSLocations {
        let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") + "prbcheck"
        let addresses = try Self.collectDNSResolvers { attempt in
            (try? fetch(session, "https://\(token)-\(attempt).ipleak.net/dnsdetection/", deadline: deadline)) ?? ["ip": []]
        } retrying: { retry, limit in
            notify(.checking(.pageDNS, "正在补测网页 DNS 样本（\(retry)/\(limit)）。", evidence))
            Thread.sleep(forTimeInterval: 0.4)
        }
        return try locate(addresses, via: session, deadline: deadline)
    }

    private func reviewDownstream(corePort: Int, core: URLSession, relay: URLSession,
                                  deadline: DispatchTime) throws -> DNSLocations? {
        // Resolve a different name to obtain the detector address. The probe names themselves
        // enter the tunnel solely via the fixed address and normal certificate-checked HTTPS.
        let prefix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") + "prbcheck"
        let request = ResolvedProxy.dnsQuery(prefix + "-1.ipleak.net", type: "A")
        let data = try fetchData(core, request, deadline: deadline)
        let target = try ResolvedProxy.answer(data)
        let names = (0..<2).map { _ in UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") + "prbcheck-1.ipleak.net" }
        let control = ResolvedProxy(upstreamPort: corePort,
                                    probeTargets: Dictionary(uniqueKeysWithValues: names.map { ($0, target) }))
        let controlSession = session(port: try control.start())
        defer { controlSession.invalidateAndCancel(); control.stop() }
        var addresses = Set<String>()
        for name in names {
            let reply = try? fetch(controlSession, "https://\(name)/dnsdetection/", deadline: deadline)
            if let found = reply?["ip"] as? [String: Any] { addresses.formUnion(found.keys) }
        }
        guard !addresses.isEmpty else { return nil }
        return try locate(addresses, via: relay, deadline: deadline)
    }

    private func probe(_ relay: URLSession, corePort: Int, expected: String) throws -> ProbeResult {
        let exit = try readExit(relay, expected: expected)
        var evidence = DNSEvidence(exit: exit.country, exitIP: exit.ip)
        let core = session(port: corePort)
        defer { core.invalidateAndCancel() }
        notify(.checking(.toolDNS, "正在确认加密 DNS 的解析器地区。", evidence))
        do {
            evidence.tool = try measureToolDNS(core: core, relay: relay, evidence: evidence, deadline: .now() + 20)
        } catch {
            throw ConnectionProblem(step: .toolDNS, title: "工具 DNS 待确认",
                                    message: "加密 DNS 的有效样本不足。请重试。",
                                    recovery: .retry, evidence: evidence)
        }
        guard let tool = evidence.tool, tool.matches(exit.country) else {
            let crossesRegion = evidence.tool?.hasCrossRegion(exit.country) == true
            throw ConnectionProblem(step: .toolDNS, title: crossesRegion ? "工具 DNS 跨区" : "工具 DNS 待确认",
                                    message: evidence.summary, recovery: crossesRegion ? .selectNode : .retry,
                                    evidence: evidence)
        }

        notify(.checking(.pageDNS, "正在检查网页访问时观测到的 DNS。", evidence))
        do {
            evidence.page = try measurePageDNS(relay, evidence: evidence, deadline: .now() + 32)
        } catch {
            throw ConnectionProblem(step: .pageDNS, title: "网页 DNS 待确认",
                                    message: "网页 DNS 的有效样本不足。请重试。",
                                    recovery: .retry, evidence: evidence)
        }
        guard let page = evidence.page,
              (try? Self.validateCountries(exit: exit.country, expected: expected, dns: page.countries)) != nil else {
            notify(.checking(.pageDNS, "网页 DNS 地区未通过，正在复核代理下游。", evidence))
            evidence.downstream = try? reviewDownstream(corePort: corePort, core: core, relay: relay,
                                                       deadline: .now() + 10)
            let downstreamMismatch = evidence.downstream?.hasCrossRegion(exit.country) == true
            let pageMismatch = evidence.page?.hasCrossRegion(exit.country) == true
            let title = downstreamMismatch ? "代理下游 DNS 跨区" : (pageMismatch ? "网页 DNS 跨区" : "网页 DNS 待确认")
            throw ConnectionProblem(step: .pageDNS, title: title,
                                    message: evidence.summary,
                                    recovery: downstreamMismatch || pageMismatch ? .selectNode : .retry, evidence: evidence)
        }
        return ProbeResult(exitIP: exit.ip, country: exit.country, dns: page.records, evidence: evidence)
    }

    func start(_ request: ConnectionRequest) {
        DispatchQueue.global(qos: .userInitiated).async { self.run(request) }
    }

    func checkRegion(_ request: RegionCheckRequest,
                     onProgress: @escaping (String, ConnectionStep) -> Void,
                     onResult: @escaping (NodeCheck) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let original = try Configuration.load(request.source)
                let interface = try Configuration.physicalInterface()
                let workers = OperationQueue()
                workers.maxConcurrentOperationCount = 3
                workers.qualityOfService = .userInitiated
                let startupLock = NSLock()
                for node in request.nodes {
                    workers.addOperation {
                        guard !self.stopped else { return }
                        onProgress(node, .prepare)
                        let worker = Engine(notify: { update in
                            if case let .checking(step, _, _) = update, !self.stopped {
                                onProgress(node, step)
                            }
                        }, parentStopped: { self.stopped })
                        let result = worker.checkNode(node, request: request, original: original,
                                                      interface: interface, startupLock: startupLock)
                        if !self.stopped { onResult(result) }
                    }
                }
                workers.waitUntilAllOperationsAreFinished()
                self.finished(nil)
            } catch {
                self.finished(Self.preparationProblem(error))
            }
        }
    }

    static func profileKey(source: URL, node: String, browser: URL) -> String {
        let identity = source.path + "\n" + node + "\n" + browser.path
        return SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func preparationProblem(_ error: Error) -> ConnectionProblem {
        error as? ConnectionProblem ?? ConnectionProblem(
            step: .prepare, title: "无法建立连接",
            message: (error as? AppFailure)?.message ?? "请检查配置文件、浏览器和 Mihomo 内核是否可用。",
            recovery: .retry)
    }

    private func checkNode(_ node: String, request: RegionCheckRequest, original: [String: Any],
                           interface: String, startupLock: NSLock) -> NodeCheck {
        let run = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyBrowser-check-" + UUID().uuidString)
        var websiteReachable: Bool?
        defer {
            closeRelay()
            try? FileManager.default.removeItem(at: run)
        }
        do {
            let ports = try openRelay(core: request.core, original: original, node: node,
                                      interface: interface, run: run, startupLock: startupLock)
            let session = session(port: ports.relay)
            defer { session.invalidateAndCancel() }
            websiteReachable = (try? fetchData(session, "https://www.gstatic.com/generate_204",
                                               deadline: .now() + 7, expectedStatus: 204)) != nil
            let probe = try probe(session, corePort: ports.mihomo, expected: request.country)
            guard let proxy, proxy.isRunning,
                  Self.ownsLoopbackListener(pid: proxy.processIdentifier, port: ports.mihomo) else {
                throw AppFailure("独立内核监听已结束，请重新检查。")
            }
            return NodeCheck(name: node, websiteReachable: websiteReachable, result: .success(probe))
        } catch {
            return NodeCheck(name: node, websiteReachable: websiteReachable,
                             result: .failure(Self.preparationProblem(error)))
        }
    }

    private func openRelay(core: URL, original: [String: Any], node: String, interface: String,
                           run: URL, startupLock: NSLock? = nil) throws -> (mihomo: Int, relay: Int) {
        startupLock?.lock()
        defer { startupLock?.unlock() }
        guard !stopped else { throw AppFailure("连接已取消。") }
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let mixedPort = try port()
        let config = try Configuration.runtime(config: original, selected: node, port: mixedPort, interface: interface)
        let file = run.appendingPathComponent("proxy.json")
        try Configuration.encodeRuntime(config).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let arguments = ["-d", run.path, "-f", file.path]
        let validator = try launch(core, ["-t"] + arguments, log: run.appendingPathComponent("validation.log"))
        let deadline = DispatchTime.now() + 10
        while validator.isRunning {
            if stopped || DispatchTime.now() >= deadline {
                end(validator)
                throw AppFailure(stopped ? "连接已取消。" : "内核配置检查超时，未建立连接。")
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        guard validator.terminationStatus == 0 else {
            throw AppFailure("本机 Mihomo 无法加载所选节点或链路，请检查内核版本与完整配置。")
        }
        let child = try launch(core, arguments, log: run.appendingPathComponent("proxy.log"))
        proxy = child
        let readyDeadline = DispatchTime.now() + 4
        while true {
            guard !stopped, child.isRunning, DispatchTime.now() < readyDeadline else {
                throw AppFailure("独立内核未能启动本地监听。")
            }
            if Self.ownsLoopbackListener(pid: child.processIdentifier, port: mixedPort) { break }
            Thread.sleep(forTimeInterval: 0.03)
        }
        let relay = ResolvedProxy(upstreamPort: mixedPort)
        resolvedProxy = relay
        return (mixedPort, try relay.start())
    }

    static func ownsLoopbackListener(pid: pid_t, port: Int) -> Bool {
        // The reserved port is released before launching Mihomo. Only its own
        // listener can confirm readiness if another process takes the port first.
        let stride = MemoryLayout<proc_fdinfo>.stride
        let estimatedBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimatedBytes > 0 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimatedBytes) / stride + 8)
        let bytes = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return false }
        let socketBytes = Int32(MemoryLayout<socket_fdinfo>.size)
        for descriptor in descriptors.prefix(Int(bytes) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, socketBytes) == socketBytes,
                  info.psi.soi_kind == SOCKINFO_TCP, info.psi.soi_family == AF_INET else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            if tcp.tcpsi_state == TSI_S_LISTEN,
               Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))) == port,
               tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr == INADDR_LOOPBACK.bigEndian {
                return true
            }
        }
        return false
    }

    private func closeRelay() {
        resolvedProxy?.stop()
        end(proxy)
        for handle in logs { try? handle.close() }
    }

    private func run(_ request: ConnectionRequest) {
        let oldMask = umask(0o077)
        defer { umask(oldMask) }
        var failure: ConnectionProblem?
        var configFile: URL?
        var lockFD: Int32 = -1
        var ownsLock = false
        defer {
            end(browser)
            closeRelay()
            if let file = configFile { try? FileManager.default.removeItem(at: file) }
            if ownsLock {
                writeState(["status": failure == nil ? "stopped" : "error", "children_stopped": true,
                            "error": failure?.message ?? ""])
            }
            if lockFD >= 0 { Darwin.close(lockFD) }
            finished(failure)
        }
        do {
            try FileManager.default.createDirectory(at: Configuration.support, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            lockFD = Darwin.open(Configuration.support.appendingPathComponent("run.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                throw AppFailure("另一个独立纯净代理正在运行，请先关闭它。")
            }
            ownsLock = true
            let run = Configuration.support.appendingPathComponent("Runs/" + UUID().uuidString)
            configFile = run.appendingPathComponent("proxy.json")
            notify(.checking(.prepare, "正在加载所选节点和独立代理内核。"))
            let original = try Configuration.load(request.source)
            let interface = try Configuration.physicalInterface()
            writeState(["status": "starting", "runtime": run.path,
                        "source": request.source.path, "node": request.node, "app_pid": getpid(), "interface": interface])
            let ports = try openRelay(core: request.core, original: original, node: request.node,
                                      interface: interface, run: run)
            let browserPort = ports.relay
            writeState(["port": ports.mihomo, "proxy_pid": proxy!.processIdentifier,
                        "browser_proxy_port": browserPort, "dns_transport": "DoH through selected node, CONNECT by IPv4"])
            let checkingSession = session(port: browserPort)
            let checks: ProbeResult
            do {
                defer { checkingSession.invalidateAndCancel() }
                checks = try probe(checkingSession, corePort: ports.mihomo, expected: request.country)
            }
            if stopped { return }
            guard let proxy, proxy.isRunning,
                  Self.ownsLoopbackListener(pid: proxy.processIdentifier, port: ports.mihomo) else {
                throw AppFailure("独立内核监听已结束，未打开浏览器。")
            }
            let key = Self.profileKey(source: request.source, node: request.node, browser: request.browser)
            let profile = Configuration.support.appendingPathComponent("Browser Profiles/" + key)
            let defaultDir = profile.appendingPathComponent("Default")
            try FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let prefsURL = defaultDir.appendingPathComponent("Preferences")
            var prefs: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: prefsURL.path) {
                guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: prefsURL)) as? [String: Any] else {
                    throw AppFailure("专用浏览器资料无法读取，已保留原文件。")
                }
                prefs = existing
            }
            var doh = prefs["dns_over_https"] as? [String: Any] ?? [:]
            doh["mode"] = "off"; prefs["dns_over_https"] = doh
            var rtc = prefs["webrtc"] as? [String: Any] ?? [:]
            rtc["ip_handling_policy"] = "disable_non_proxied_udp"; prefs["webrtc"] = rtc
            try JSONSerialization.data(withJSONObject: prefs).write(to: prefsURL, options: .atomic)
            let args = ["--user-data-dir=" + profile.path, "--proxy-server=http://127.0.0.1:\(browserPort)",
                        "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost",
                        "--force-webrtc-ip-handling-policy=disable_non_proxied_udp", "--no-first-run",
                        "--no-default-browser-check", "--disable-background-networking",
                        "--window-size=1300,950", Self.startURL]
            browser = try launch(request.browser, args, log: run.appendingPathComponent("browser.log"))
            writeState(["status": "running", "browser_pid": browser!.processIdentifier,
                        "profile": profile.path, "exit_ip": checks.exitIP,
                        "exit_country": checks.country, "dns": checks.dns,
                        "tool_dns": checks.evidence.tool?.records ?? [],
                        "browser_executable": request.browser.path])
            notify(.opening(checks, interface, browser!.processIdentifier))
            while !stopped {
                guard proxy.isRunning else { throw ConnectionProblem(step: .prepare, title: "连接已中断", message: "独立内核退出，专用浏览器已关闭。可重新连接。", recovery: .retry) }
                if browser?.isRunning != true { break }
                if consumeOpen() {
                    _ = try launch(request.browser, ["--user-data-dir=" + profile.path, Self.startURL], log: run.appendingPathComponent("reopen-\(UUID().uuidString).log"))
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
        } catch {
            if !stopped { failure = Self.preparationProblem(error) }
        }
    }
}
