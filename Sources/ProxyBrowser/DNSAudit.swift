import Foundation
import Darwin

struct DNSLocations {
    let records: [[String: String]]

    var countries: [String] { records.map { $0["country"] ?? "" } }

    var hasKnownCountries: Bool { !records.isEmpty && countries.allSatisfy { !$0.isEmpty } }

    var label: String {
        Set(countries.map { $0.isEmpty ? "未知" : NodeRegions.name($0) }).sorted().joined(separator: "、")
    }

    func matches(_ country: String) -> Bool {
        !records.isEmpty && countries.allSatisfy { $0 == country }
    }

    func hasCrossRegion(_ country: String) -> Bool {
        countries.contains { !$0.isEmpty && $0 != country }
    }

    static func isAddress(_ value: String) -> Bool {
        if ResolvedProxy.ipv4(value) { return true }
        var address = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }

    static func resolverAddress(_ response: Data) -> String? {
        guard let reply = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any],
              reply["Status"] as? Int == 0, let records = reply["Answer"] as? [[String: Any]] else { return nil }
        for record in records where record["type"] as? Int == 16 {
            guard let text = record["data"] as? String, text.hasPrefix("FROM: "),
                  let host = text.dropFirst(6).split(separator: "#", maxSplits: 1).first,
                  isAddress(String(host)) else { continue }
            return String(host)
        }
        return nil
    }
}

struct DNSEvidence {
    let exit: String
    var exitIP: String? = nil
    var tool: DNSLocations? = nil
    var page: DNSLocations? = nil
    var downstream: DNSLocations? = nil

    var summary: String {
        var parts = ["出口 " + NodeRegions.name(exit)]
        if let tool { parts.append("工具 DNS " + tool.label) }
        if let downstream, downstream.hasCrossRegion(exit) { parts.append("下游 DNS " + downstream.label) }
        else if let page { parts.append("网页 DNS " + page.label) }
        return parts.joined(separator: " · ")
    }

    var checkedPage: DNSLocations? { downstream?.hasCrossRegion(exit) == true ? downstream : page }
}
