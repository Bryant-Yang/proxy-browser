import Foundation

enum NodeRegions {
    private static let chinese = Locale(identifier: "zh_CN")
    private static let english = Locale(identifier: "en_US")
    private static let codes = Set(Locale.Region.isoRegions.map(\.identifier))
    private static let displayNames = [
        "HK": "香港", "MO": "澳门", "TW": "台湾", "KR": "韩国", "GB": "英国",
        "US": "美国", "SG": "新加坡", "JP": "日本"
    ]

    static func name(_ code: String) -> String {
        displayNames[code] ?? chinese.localizedString(forRegionCode: code) ?? code
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: english)
    }

    private static let aliases: [String: String] = {
        var terms: [String: String] = [:]
        for code in codes.sorted() {
            for term in [english.localizedString(forRegionCode: code), chinese.localizedString(forRegionCode: code), displayNames[code]].compactMap({ $0 }) {
                terms[normalized(term)] = code
            }
        }
        for (code, termsForRegion) in [
            "SG": ["狮城", "獅城", "新加坡"], "US": ["美國", "USA", "United States of America"],
            "GB": ["英國", "Great Britain", "UK"], "JP": ["日本", "东京", "東京", "大阪"],
            "KR": ["韓國", "Korea", "South Korea", "首尔", "首爾"],
            "HK": ["香港", "Hong Kong"], "TW": ["台灣", "臺灣", "台北", "Taiwan"],
            "MO": ["澳門", "Macau"], "VN": ["越南", "Vietnam"], "PH": ["菲律賓"],
            "DE": ["德國"], "CA": ["加拿大"], "FR": ["法國"], "MY": ["馬來西亞"]
        ] {
            for term in termsForRegion { terms[normalized(term)] = code }
        }
        return terms
    }()

    private static let namesPattern: NSRegularExpression = {
        let alternatives = aliases.keys.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
        }.map { term in
            let escaped = NSRegularExpression.escapedPattern(for: term)
            return term.first?.isASCII == true ? "(?<![a-z])" + escaped + "(?![a-z])" : escaped
        }
        return try! NSRegularExpression(pattern: alternatives.joined(separator: "|"))
    }()

    static func infer(_ label: String) -> String? {
        var candidates = Set<String>()
        for character in label {
            let scalars = character.unicodeScalars.map(\.value)
            if scalars.count == 2, scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0) }) {
                let code = String(String.UnicodeScalarView(scalars.compactMap { UnicodeScalar($0 - 0x1F1E6 + 65) }))
                if codes.contains(code) { candidates.insert(code) }
            }
        }
        let text = normalized(label)
        for match in namesPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range, in: text), let code = aliases[String(text[range])] {
                candidates.insert(code)
            }
        }
        if let prefix = label.range(of: #"^[A-Z]{2}(?=[\s_\-丨|]|$)"#, options: .regularExpression) {
            let code = String(label[prefix])
            if codes.contains(code) { candidates.insert(code) }
        }
        return candidates.count == 1 ? candidates.first : nil
    }
}

struct RouteSelection {
    struct Node: Equatable {
        let name: String
        let region: String?
    }

    let nodes: [Node]
    private(set) var filter = ""
    private(set) var selected: Node?
    private var remembered: [String: Node] = [:]

    var regions: [String] {
        let identified = Set(nodes.compactMap(\.region))
        return identified.sorted { NodeRegions.name($0).localizedStandardCompare(NodeRegions.name($1)) == .orderedAscending }
    }

    var available: [Node] {
        nodes.filter { filter.isEmpty || $0.region == filter }
    }

    init(names: [String] = [], savedNode: String? = nil, savedFilter: String? = nil, legacyCountry: String? = nil) {
        var seen = Set<String>()
        nodes = names.filter { seen.insert($0).inserted }.map { Node(name: $0, region: NodeRegions.infer($0)) }
        let saved = nodes.first { $0.name == savedNode }
        let requested = savedFilter ?? (legacyCountry?.isEmpty == false ? saved?.region ?? "" : "")
        if regions.contains(requested), saved == nil || saved?.region == requested {
            filter = requested
        }
        selected = saved ?? (available.count == 1 ? available.first : nil)
        if let selected { remembered[filter] = selected }
    }

    mutating func setFilter(_ code: String) {
        guard code != filter, code.isEmpty || regions.contains(code) else { return }
        filter = code
        let choices = available
        if let previous = selected, choices.contains(previous) {
            remembered[code] = previous
        } else if let previous = remembered[code], choices.contains(previous) {
            selected = previous
        } else {
            selected = choices.count == 1 ? choices.first : nil
        }
    }

    mutating func select(_ name: String?) {
        selected = available.first { $0.name == name }
        remembered[filter] = selected
    }
}
