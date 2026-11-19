import Foundation

struct CheckPresentation {
    let title: String
    let message: String
    let rowLabel: String

    init(problem: ConnectionProblem, region: String) {
        if let evidence = problem.evidence {
            let locations = problem.step == .toolDNS ? evidence.tool : evidence.checkedPage
            let places = Self.foreignRegions(locations, comparedWith: evidence.exit)
            if !places.isEmpty {
                title = "这条线路未通过检查"
                message = "网页出口在\(NodeRegions.name(evidence.exit))，但检测到这条线路也会在\(places)查询网站地址。"
                rowLabel = "地区不符"
                return
            }
        }

        if let exit = problem.confirmedExit {
            title = "出口与所选地区不符"
            message = "网页出口在\(NodeRegions.name(exit.country))，你选择的是\(NodeRegions.name(region))。"
            rowLabel = "地区不符"
            return
        }

        switch (problem.step, problem.recovery) {
        case (.exit, .selectNode), (.exit, .allRegions):
            title = "出口地区未确认"
            message = region.isEmpty ? "暂时无法确认这条线路从哪里访问网络。可以试试其他节点。"
                : "暂时无法确认这条线路的出口在\(NodeRegions.name(region))。可以试试其他节点。"
            rowLabel = "出口未确认"
        case (.exit, _), (.toolDNS, _), (.pageDNS, _):
            title = "暂时无法确认"
            message = "这次检查未取得足够的结果。请重新检查。"
            rowLabel = "待确认"
        case (_, .settings):
            title = "请检查浏览器设置"
            message = "打开设置，确认专用浏览器和代理内核都已就绪。"
            rowLabel = "需要设置"
        case (_, .importConfig):
            title = "请重新导入配置"
            message = "选择一份包含代理节点的配置文件后再连接。"
            rowLabel = "配置异常"
        default:
            title = problem.step == .browser ? "专用窗口未打开" : "连接未建立"
            message = problem.step == .browser ? "请重新连接并打开专用浏览器。" : "请检查节点和网络后重试。"
            rowLabel = "连接失败"
        }
    }

    static func foreignRegions(_ locations: DNSLocations?, comparedWith exit: String) -> String {
        Set((locations?.countries ?? []).filter { !$0.isEmpty && $0 != exit })
            .map(NodeRegions.name).sorted().joined(separator: "、")
    }

    static func details(problem: ConnectionProblem) -> String {
        let sections = [problem.title, problem.message, locations(problem.evidence)]
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func locations(_ evidence: DNSEvidence?, exitIP: String? = nil) -> String {
        guard let evidence else { return "" }
        var exit = "实际出口  \(NodeRegions.name(evidence.exit))"
        if let ip = exitIP ?? evidence.exitIP { exit += "  ·  \(ip)" }
        return [exit, resolvers(evidence)].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func resolvers(_ evidence: DNSEvidence?) -> String {
        guard let evidence else { return "" }
        var lines: [String] = []
        let groups = [("工具 DNS", evidence.tool), ("网页 DNS", evidence.page), ("下游 DNS", evidence.downstream)]
        for (label, group) in groups {
            guard let group else { continue }
            lines.append("\(label)  \(group.label)")
            for record in group.records {
                guard let ip = record["ip"], !ip.isEmpty else { continue }
                let country = record["country"].flatMap { $0.isEmpty ? nil : NodeRegions.name($0) } ?? "未知"
                lines.append("    \(ip)  ·  \(country)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
