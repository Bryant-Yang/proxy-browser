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
}


enum ConnectionStep: Int {
    case prepare, exit, dns, browser
}

enum ConnectionUpdate {
    case checking(ConnectionStep, String)
    case opening(ProbeResult, String, pid_t)
}

struct ConnectionProblem: LocalizedError {
    enum Recovery { case retry, selectNode, allRegions, settings, importConfig }
    let step: ConnectionStep
    let title: String
    let message: String
    let recovery: Recovery
    var errorDescription: String? { message }
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
    static let startURL = "https://ipleak.net/"

    init(notify: @escaping (ConnectionUpdate) -> Void, finished: @escaping (ConnectionProblem?) -> Void) {
        self.notify = notify
        self.finished = finished
    }

    func stop() { lock.lock(); cancelled = true; lock.unlock() }
    func openPage() { lock.lock(); reopen = true; lock.unlock() }
    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
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

    private func fetch(_ session: URLSession, _ url: String, deadline: DispatchTime) throws -> [String: Any] {
        if stopped { throw AppFailure("启动已取消。") }
        let now = DispatchTime.now()
        guard now < deadline else { throw AppFailure("检测服务响应超时。") }
        let limit = min(deadline, now + 14)
        let gate = DispatchSemaphore(value: 0)
        var received: Data?
        var status = 0
        let task = session.dataTask(with: URL(string: url)!) { data, response, _ in
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
        guard status == 200, let received = received, received.count <= 262144,
              let object = try JSONSerialization.jsonObject(with: received) as? [String: Any] else {
            throw AppFailure("检查服务暂不可用，或所选节点连接失败。")
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

    private func probe(_ port: Int, expected: String) throws -> ProbeResult {
        let session = session(port: port)
        defer { session.invalidateAndCancel() }
        let deadline = DispatchTime.now() + 42
        notify(.checking(.exit, "正在通过所选节点查询公网出口。"))
        var address: [String: Any]?
        for _ in 0..<3 {
            do {
                address = try fetch(session, "https://ipv4.ipleak.net/json/", deadline: deadline)
                break
            } catch {
                if stopped || DispatchTime.now() >= deadline { break }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        guard let address, let ip = address["ip"] as? String, ResolvedProxy.ipv4(ip),
              let country = address["country_code"] as? String, country.count == 2 else {
            throw ConnectionProblem(step: .exit, title: "未取得出口信息",
                                    message: "节点或检测服务响应异常。可以重试，或选择同地区的另一个节点。",
                                    recovery: .retry)
        }
        guard expected.isEmpty || country == expected else {
            throw ConnectionProblem(step: .exit, title: "出口与地区筛选不符",
                                    message: "此节点实际出口为\(NodeRegions.name(country))。当前筛选为\(NodeRegions.name(expected))，请选择其他节点。",
                                    recovery: .allRegions)
        }
        notify(.checking(.dns, "出口 \(NodeRegions.name(country)) · \(ip)"))
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) + "prbcheck"
        var dns: [[String: String]] = []
        do {
            let resolvers = try Self.collectDNSResolvers { attempt in
                try fetch(session, "https://\(token)-\(attempt).ipleak.net/dnsdetection/", deadline: deadline)
            } retrying: { retry, limit in
                notify(.checking(.dns, "出口 \(NodeRegions.name(country)) · \(ip)\nDNS 样本为空，正在补测 \(retry)/\(limit)。"))
                Thread.sleep(forTimeInterval: 0.4)
            }
            for address in resolvers.sorted() {
                guard let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }
                let location = try fetch(session, "https://ipleak.net/json/" + encoded, deadline: deadline)
                dns.append(["ip": address, "country": location["country_code"] as? String ?? ""])
            }
        } catch {
            throw ConnectionProblem(step: .dns, title: "DNS 检查未完成",
                                    message: "已确认出口为\(NodeRegions.name(country))，但检测服务未返回完整的 DNS 结果。可以重试。",
                                    recovery: .retry)
        }
        let dnsCountries = dns.compactMap { $0["country"] }
        do {
            try Self.validateCountries(exit: country, expected: expected, dns: dnsCountries)
        } catch {
            let places = Set(dnsCountries.map { $0.isEmpty ? "未知" : NodeRegions.name($0) }).sorted()
            throw ConnectionProblem(step: .dns, title: "DNS 地区校验未通过",
                                    message: "出口为\(NodeRegions.name(country))，DNS 地区为\(places.joined(separator: "、"))。请换用同地区的另一个节点。",
                                    recovery: .selectNode)
        }
        return ProbeResult(exitIP: ip, country: country, dns: dns)
    }

    func start(_ request: ConnectionRequest) {
        DispatchQueue.global(qos: .userInitiated).async { self.run(request) }
    }

    static func profileKey(source: URL, node: String, browser: URL) -> String {
        let identity = source.path + "\n" + node + "\n" + browser.path
        return SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
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
            resolvedProxy?.stop()
            end(proxy)
            for handle in logs { try? handle.close() }
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
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            notify(.checking(.prepare, "正在加载所选节点和独立代理内核。"))
            let original = try Configuration.load(request.source)
            let chosenPort = try port()
            let interface = try Configuration.physicalInterface()
            let config = try Configuration.runtime(config: original, selected: request.node, port: chosenPort, interface: interface)
            let file = run.appendingPathComponent("proxy.json")
            configFile = file
            try Configuration.encodeRuntime(config).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            writeState(["status": "starting", "port": chosenPort, "runtime": run.path,
                        "source": request.source.path, "node": request.node, "app_pid": getpid(), "interface": interface])
            let validator = try launch(request.core, ["-t", "-d", run.path, "-f", file.path], log: run.appendingPathComponent("validation.log"))
            for _ in 0..<100 {
                if !validator.isRunning { break }
                if stopped { end(validator); return }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if validator.isRunning { end(validator); throw AppFailure("内核配置检查超时，未建立连接。") }
            guard validator.terminationStatus == 0 else {
                throw AppFailure("本机 Mihomo 无法加载所选节点或链路，请检查内核版本与完整配置。")
            }
            proxy = try launch(request.core, ["-d", run.path, "-f", file.path], log: run.appendingPathComponent("proxy.log"))
            writeState(["proxy_pid": proxy!.processIdentifier])
            let relay = ResolvedProxy(upstreamPort: chosenPort)
            resolvedProxy = relay
            let browserPort = try relay.start()
            writeState(["browser_proxy_port": browserPort, "dns_transport": "DoH through selected node, CONNECT by IPv4"])
            let checks = try probe(browserPort, expected: request.country)
            if stopped { return }
            guard proxy?.isRunning == true else { throw AppFailure("独立内核已经退出，未打开浏览器。") }
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
                        "browser_executable": request.browser.path])
            notify(.opening(checks, interface, browser!.processIdentifier))
            while !stopped {
                guard proxy?.isRunning == true else { throw ConnectionProblem(step: .prepare, title: "连接已中断", message: "独立内核退出，专用浏览器已关闭。可重新连接。", recovery: .retry) }
                if browser?.isRunning != true { break }
                if consumeOpen() {
                    _ = try launch(request.browser, ["--user-data-dir=" + profile.path, Self.startURL], log: run.appendingPathComponent("reopen-\(UUID().uuidString).log"))
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
        } catch {
            if !stopped {
                failure = error as? ConnectionProblem ?? ConnectionProblem(
                    step: .prepare, title: "无法建立连接",
                    message: (error as? AppFailure)?.message ?? "请检查配置文件、浏览器和 Mihomo 内核是否可用。",
                    recovery: .retry
                )
            }
        }
    }
}
