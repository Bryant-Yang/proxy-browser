import XCTest
import Yams
@testable import ProxyBrowser

final class ConfigurationTests: XCTestCase {
    func testPhysicalBindingCoversNodeDependenciesAndBootstrapDNS() throws {
        let config: [String: Any] = ["proxies": [["name": "exit", "type": "socks5", "dialer-proxy": "front", "interface-name": "utun8"],
                                                           ["name": "front", "type": "trojan"]]]
        let runtime = try Configuration.runtime(config: config, selected: "exit", port: 23456, interface: "en0")
        XCTAssertEqual(runtime["interface-name"] as? String, "en0")
        XCTAssertTrue((runtime["proxies"] as! [[String: Any]]).allSatisfy { $0["interface-name"] as? String == "en0" })
        let dns = runtime["dns"] as! [String: Any]
        XCTAssertTrue((dns["proxy-server-nameserver"] as! [String]).allSatisfy { $0.hasSuffix("#en0") })
        XCTAssertEqual(runtime["rules"] as? [String], ["MATCH,Independent Browser Exit"])
        XCTAssertThrowsError(try Configuration.runtime(config: config, selected: "exit", port: 23456, interface: "utun8"))
    }
    func testEncodedRuntimeIsValidYAMLIncludingURLs() throws {
        let fixture: [String: Any] = ["dns": ["nameserver": ["https://1.1.1.1/dns-query"]],
                                      "proxies": [["password": "fixture/with/slashes"]]]
        let encoded = try Configuration.encodeRuntime(fixture)
        let text = String(data: encoded, encoding: .utf8)!
        XCTAssertFalse(text.contains("\\/"))
        XCTAssertNoThrow(try Yams.load(yaml: text))
    }
    func testDifferentBrowsersAndNodesDoNotShareProfile() {
        let source = URL(fileURLWithPath: "/fixture/config.yaml")
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        let edge = URL(fileURLWithPath: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
        let original = Engine.profileKey(source: source, node: "one", browser: chrome)
        XCTAssertNotEqual(original, Engine.profileKey(source: source, node: "one", browser: edge))
        XCTAssertNotEqual(original, Engine.profileKey(source: source, node: "two", browser: chrome))
        XCTAssertEqual(original, Engine.profileKey(source: source, node: "one", browser: chrome))
    }
    func testSelectedNodeOnlyAndNoSystemListeners() throws {
        let input: [String: Any] = ["tun": ["enable": true], "external-controller": "0.0.0.0:9999",
            "proxies": [["name": "chosen", "type": "trojan", "server": "example.com", "password": "fixture"],
                        ["name": "unselected", "type": "ss", "password": "must-not-export"]]]
        let output = try Configuration.runtime(config: input, selected: "chosen", port: 12345)
        XCTAssertEqual((output["proxies"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((output["tun"] as? [String: Bool])?["enable"], false)
        XCTAssertNil(output["external-controller"])
        XCTAssertEqual(output["bind-address"] as? String, "127.0.0.1")
        XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8)!.contains("must-not-export"))
    }
    func testExplicitChainRetained() throws {
        let input: [String: Any] = ["proxies": [["name": "exit", "type": "socks5", "dialer-proxy": "front"],
                                               ["name": "entry", "type": "trojan"]],
                                   "proxy-groups": [["name": "front", "type": "select", "proxies": ["entry"]]]]
        let graph = try Configuration.graph(config: input, selected: "exit")
        XCTAssertEqual(Set(graph.nodes.compactMap { $0["name"] as? String }), Set(["exit", "entry"]))
        XCTAssertEqual(graph.groups.count, 1)
    }
    func testAmbiguousChainRejected() {
        let input: [String: Any] = ["proxies": [["name": "exit", "dialer-proxy": "front"]],
                                   "proxy-groups": [["name": "front", "proxies": ["one", "two"]]]]
        XCTAssertThrowsError(try Configuration.graph(config: input, selected: "exit"))
    }
    func testCycleAndMissingDependenciesRejected() {
        XCTAssertThrowsError(try Configuration.graph(config: ["proxies": [["name": "x", "dialer-proxy": "x"]]], selected: "x"))
        XCTAssertThrowsError(try Configuration.graph(config: ["proxies": [["name": "x", "dialer-proxy": "missing"]]], selected: "x"))
    }
    func testDNSMustBeNonemptyAndMatchExit() {
        XCTAssertThrowsError(try Engine.validateCountries(exit: "SG", expected: "SG", dns: []))
        XCTAssertThrowsError(try Engine.validateCountries(exit: "SG", expected: "SG", dns: ["SG", "HK"]))
        XCTAssertThrowsError(try Engine.validateCountries(exit: "US", expected: "SG", dns: ["US"]))
        XCTAssertNoThrow(try Engine.validateCountries(exit: "JP", expected: "", dns: ["JP", "JP"]))
    }
}
