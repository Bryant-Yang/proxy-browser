import Foundation
import Yams
import SystemConfiguration
import Darwin

struct BrowserChoice {
    let name: String
    let executable: URL
}
struct ProfileChoice {
    let name: String
    let url: URL
}
struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum Configuration {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/BraveWaves/Proxy Browser")

    static func physicalInterface() throws -> String {
        guard let store = SCDynamicStoreCreate(nil, "ProxyBrowser" as CFString, nil, nil),
              let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = state["PrimaryInterface"] as? String,
              name.range(of: "^(en|bridge)[0-9]+$", options: .regularExpression) != nil,
              if_nametoindex(name) != 0 else {
            throw AppFailure("未找到可绑定的实体网络出口，已停止；不会自动改走系统 TUN。")
        }
        return name
    }

    static func encodeRuntime(_ config: [String: Any]) throws -> Data {
        // Mihomo parses this as YAML: JSON's optional \/ escape is not valid YAML.
        try JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes])
    }

    static func load(_ file: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        guard data.count <= 32 * 1024 * 1024,
              let string = String(data: data, encoding: .utf8),
              let object = try Yams.load(yaml: string) as? [String: Any] else {
            throw AppFailure("无法读取这份 Clash YAML 配置。")
        }
        return object
    }

    static func nodes(_ file: URL) throws -> [[String: Any]] {
        let config = try load(file)
        let nodes = (config["proxies"] as? [[String: Any]] ?? []).filter {
            $0["name"] is String && $0["type"] is String
        }
        guard !nodes.isEmpty else {
            throw AppFailure("这份配置没有可选节点。请导入含 proxies 的完整 YAML；仅含远程 provider 的配置请先在 Clash 中导出完整配置。")
        }
        return nodes
    }

    static func profiles() -> [ProfileChoice] {
        let roots = [
            home.appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"),
            home.appendingPathComponent("Library/Application Support/io.github.clash-verge.clash-verge"),
            home.appendingPathComponent(".config/io.github.clash-verge-rev.clash-verge-rev"),
            home.appendingPathComponent(".config/clash-verge")
        ]
        var choices: [ProfileChoice] = []
        var seen = Set<String>()
        func append(_ name: String, _ url: URL) {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key), (try? nodes(url)) != nil else { return }
            seen.insert(key)
            choices.append(ProfileChoice(name: name, url: url))
        }
        for root in roots {
            if let index = try? load(root.appendingPathComponent("profiles.yaml")),
               let items = index["items"] as? [[String: Any]] {
                for item in items where ["local", "remote"].contains(item["type"] as? String ?? "") {
                    guard let file = item["file"] as? String else { continue }
                    let folder = root.appendingPathComponent("profiles").standardizedFileURL
                    let url = folder.appendingPathComponent(file).standardizedFileURL
                    guard url.path.hasPrefix(folder.path + "/") else { continue }
                    append(item["name"] as? String ?? file, url)
                }
            }
            append("当前生成配置", root.appendingPathComponent("clash-verge.yaml"))
        }
        return choices
    }

    static func core() -> URL? {
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        for root in roots {
            for app in ["Clash Verge.app", "Clash Verge Rev.app"] {
                for suffix in ["Contents/MacOS/verge-mihomo", "Contents/MacOS/mihomo", "Contents/Resources/verge-mihomo"] {
                    let path = root.appendingPathComponent(app).appendingPathComponent(suffix)
                    if FileManager.default.isExecutableFile(atPath: path.path) { return path }
                }
            }
        }
        return nil
    }

    static func browser(at app: URL) -> BrowserChoice? {
        guard let bundle = Bundle(url: app),
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? app.deletingPathExtension().lastPathComponent
        guard ["chrome", "chromium", "edge", "brave"].contains(where: name.lowercased().contains) else { return nil }
        return BrowserChoice(name: name, executable: executable)
    }

    static func browsers() -> [BrowserChoice] {
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var result: [BrowserChoice] = []
        for root in roots {
            for name in ["Google Chrome.app", "Microsoft Edge.app", "Brave Browser.app", "Chromium.app", "Google Chrome for Testing.app"] {
                if let item = browser(at: root.appendingPathComponent(name)) { result.append(item) }
            }
        }
        return result
    }

    /// Include only an explicit node and its unambiguous dialer dependencies.
    static func graph(config: [String: Any], selected: String) throws -> (nodes: [[String: Any]], groups: [[String: Any]]) {
        let allNodes = config["proxies"] as? [[String: Any]] ?? []
        let allGroups = config["proxy-groups"] as? [[String: Any]] ?? []
        var outputNodes: [[String: Any]] = []
        var outputGroups: [[String: Any]] = []
        var complete = Set<String>()
        var visiting = Set<String>()
        func visit(_ name: String) throws {
            if complete.contains(name) { return }
            guard !visiting.contains(name) else { throw AppFailure("节点链路存在循环依赖。") }
            visiting.insert(name)
            if let node = allNodes.first(where: { $0["name"] as? String == name }) {
                if let dialer = node["dialer-proxy"] as? String {
                    guard dialer != "DIRECT" else { throw AppFailure("链式节点使用了 DIRECT 前置；请导出明确的代理链路。") }
                    try visit(dialer)
                }
                outputNodes.append(node)
            } else if let group = allGroups.first(where: { $0["name"] as? String == name }) {
                guard group["use"] == nil,
                      let candidates = group["proxies"] as? [String], candidates.count == 1 else {
                    throw AppFailure("所选节点依赖多选策略组或 provider；请导出已固定前置节点的完整配置，不会自动替你选前置。")
                }
                try visit(candidates[0])
                outputGroups.append(group)
            } else {
                throw AppFailure("节点缺少链路依赖，请导入完整配置。")
            }
            visiting.remove(name)
            complete.insert(name)
        }
        try visit(selected)
        return (outputNodes, outputGroups)
    }

    static func runtime(config: [String: Any], selected: String, port: Int, interface: String? = nil) throws -> [String: Any] {
        let extracted = try graph(config: config, selected: selected)
        var name = "Independent Browser Exit"
        let names = Set((extracted.nodes + extracted.groups).compactMap { $0["name"] as? String })
        while names.contains(name) { name += "_" }
        let groups = extracted.groups + [["name": name, "type": "select", "proxies": [selected]]]
        var result: [String: Any] = [
            "mixed-port": port, "bind-address": "127.0.0.1", "allow-lan": false,
            "mode": "rule", "log-level": "warning", "ipv6": false,
            "tun": ["enable": false], "proxies": extracted.nodes, "proxy-groups": groups,
            "rules": ["MATCH," + name],
            "dns": ["enable": true, "ipv6": false, "enhanced-mode": "redir-host",
                    "proxy-server-nameserver": ["https://223.5.5.5/dns-query", "https://1.1.1.1/dns-query"],
                    "nameserver": ["https://1.1.1.1/dns-query#" + name]],
            "profile": ["store-selected": false, "store-fake-ip": false]
        ]
        if let interface = interface {
            guard interface.range(of: "^(en|bridge)[0-9]+$", options: .regularExpression) != nil else {
                throw AppFailure("不能将独立连接绑定到 TUN 或无效网卡。")
            }
            result["interface-name"] = interface
            result["proxies"] = extracted.nodes.map { node in
                var node = node; node["interface-name"] = interface; return node
            }
            var dns = result["dns"] as! [String: Any]
            dns["proxy-server-nameserver"] = ["https://223.5.5.5/dns-query#" + interface,
                                              "https://1.1.1.1/dns-query#" + interface]
            result["dns"] = dns
        }
        guard JSONSerialization.isValidJSONObject(result) else { throw AppFailure("节点包含无法转换的配置字段。") }
        return result
    }
}
