import AppKit

@MainActor
final class RegionCheckPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 466),
                         styleMask: [.titled], backing: .buffered, defer: false)
    private let country: String
    private let action: (String?) -> Void
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let details = RegionCheckDetails()
    private let detailsButton = NSButton(title: "展开检测详情", target: nil, action: nil)
    private let tableHeight: NSLayoutConstraint
    private let closeButton = NSButton(title: "停止检查", target: nil, action: nil)
    private let useButton = NSButton(title: "使用此节点", target: nil, action: nil)
    private var nodes: [String]
    private var results: [String: NodeCheck] = [:]
    private var activeSteps: [String: ConnectionStep] = [:]
    private var scanError: ConnectionProblem?
    private var scanning = true
    private var stopping = false

    init(country: String, nodes: [String], action: @escaping (String?) -> Void) {
        let scroll = NSScrollView()
        tableHeight = scroll.heightAnchor.constraint(equalToConstant: 232)
        self.country = country
        self.nodes = nodes
        self.action = action
        super.init()
        window.title = "节点检查"
        window.isReleasedWhenClosed = false
        window.contentView = BrowserSurface(BrowserPalette.canvas)

        let title = NSTextField(labelWithString: NodeRegions.name(country) + "节点")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = BrowserPalette.ink
        summary.font = .systemFont(ofSize: 14, weight: .medium)
        summary.textColor = BrowserPalette.muted
        progress.isIndeterminate = true
        progress.maxValue = Double(nodes.count)
        progress.style = .bar
        progress.controlSize = .small
        progress.heightAnchor.constraint(equalToConstant: 8).isActive = true

        table.delegate = self
        table.dataSource = self
        table.rowHeight = 30
        table.style = .inset
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (id, heading, width) in [("node", "节点", 380.0), ("result", "检查结果", 145.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = heading
            column.width = width
            table.addTableColumn(column)
        }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        tableHeight.isActive = true

        detail.font = .systemFont(ofSize: 13)
        detail.textColor = BrowserPalette.muted
        detail.maximumNumberOfLines = 2
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailsButton.target = self
        detailsButton.action = #selector(toggleDetails)
        detailsButton.bezelStyle = .rounded
        detailsButton.imagePosition = .imageTrailing
        detailsButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        detailsButton.setContentHuggingPriority(.required, for: .horizontal)
        let selection = NSStackView(views: [detail, NSView(), detailsButton])
        selection.spacing = 12
        selection.alignment = .centerY
        selection.heightAnchor.constraint(equalToConstant: 36).isActive = true
        closeButton.target = self
        closeButton.action = #selector(closeOrStop)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        useButton.target = self
        useButton.action = #selector(useSelected)
        useButton.bezelStyle = .rounded
        useButton.keyEquivalent = "\r"
        useButton.isEnabled = false
        let footer = NSStackView(views: [NSView(), closeButton, useButton])
        footer.spacing = 10
        footer.alignment = .centerY
        footer.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let content = NSStackView(views: [title, summary, progress, scroll, selection, details.view, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        let canvas = window.contentView!
        canvas.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: canvas.bottomAnchor, constant: -16)
        ] + content.arrangedSubviews.map { $0.widthAnchor.constraint(equalTo: content.widthAnchor) })
        progress.startAnimation(nil)
        refreshSummary()
        refreshSelection()
    }

    func updateProgress(node: String, step: ConnectionStep) {
        guard scanning, !stopping, results[node] == nil, let row = nodes.firstIndex(of: node) else { return }
        activeSteps[node] = step
        refreshSummary()
        reload(row)
    }

    func add(_ result: NodeCheck) {
        guard let row = nodes.firstIndex(of: result.name) else { return }
        results[result.name] = result
        activeSteps.removeValue(forKey: result.name)
        if progress.isIndeterminate {
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
        }
        progress.doubleValue = Double(results.count)
        refreshSummary()
        reload(row)
        refreshSelection()
    }

    private func reload(_ row: Int) {
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 1))
    }

    func finish(_ error: ConnectionProblem?) {
        scanError = error
        scanning = false
        closeButton.title = "关闭"
        closeButton.isEnabled = true
        progress.stopAnimation(nil)
        progress.isHidden = true
        activeSteps.removeAll()
        refreshSummary()
        let previous = selectedName
        let passed = nodes.filter { results[$0]?.canUse == true }
        nodes = passed + nodes.filter { results[$0]?.canUse != true }
        table.reloadData()
        let selected = previous.flatMap { nodes.firstIndex(of: $0) }
            ?? (passed.isEmpty ? nodes.firstIndex(where: { results[$0] != nil }) : 0)
        if let selected {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            table.scrollRowToVisible(selected)
        }
        refreshSelection()
    }

    private func refreshSummary() {
        let passed = results.values.filter(\.canUse).count
        if scanning {
            if stopping {
                summary.stringValue = "正在停止检查…"
            } else if activeSteps.isEmpty {
                summary.stringValue = "准备检查 · 已完成 \(results.count)/\(nodes.count)"
            } else {
                summary.stringValue = "正在检查 \(activeSteps.count) 个节点 · 已完成 \(results.count)/\(nodes.count)"
            }
        } else if scanError != nil {
            summary.stringValue = "检查未能完成"
        } else if stopping {
            summary.stringValue = "已停止 · 已检查 \(results.count) 个，\(passed) 个符合要求"
        } else {
            summary.stringValue = "已检查 \(results.count) 个节点，\(passed) 个符合要求"
        }
        summary.textColor = !scanning && passed > 0 ? BrowserPalette.accent : BrowserPalette.muted
    }

    private var selectedName: String? {
        nodes.indices.contains(table.selectedRow) ? nodes[table.selectedRow] : nil
    }

    private var selectedResult: NodeCheck? {
        selectedName.flatMap { results[$0] }
    }

    private func refreshSelection() {
        let selected = selectedResult
        useButton.isEnabled = !scanning && selected?.canUse == true
        detailsButton.isEnabled = !results.isEmpty || scanError != nil || !details.view.isHidden
        let reachable = results.values.filter { $0.websiteReachable == true }.count
        let batchReachability = results.isEmpty ? "" : "本批 Google \(reachable)/\(results.count) 可达"

        guard let result = selected else {
            if let scanError {
                detail.stringValue = "请返回检查配置后重试。"
                details.update(node: nil, batchReachability: batchReachability,
                               record: CheckPresentation.details(problem: scanError))
            } else {
                detail.stringValue = scanning ? "检查通过后可以选用节点。" : "选中一个已检查的节点可查看结果。"
                details.update(node: selectedName, batchReachability: batchReachability,
                               record: selectedName == nil ? "选中一个已检查的节点可查看详情。" : "这个节点暂无检查结果。")
            }
            return
        }
        let google: String
        switch result.websiteReachable {
        case true?: google = "可达"
        case false?: google = "未通过"
        case nil: google = "未测试"
        }

        let exit: String?
        let evidence: DNSEvidence?
        let dnsLocations: DNSLocations?
        let reason: String
        switch result.result {
        case let .success(probe):
            detail.stringValue = "这条线路符合要求。连接时会再检查一次。"
            exit = NodeRegions.name(probe.country) + " · " + probe.exitIP
            evidence = probe.evidence
            dnsLocations = probe.evidence.checkedPage
            reason = ""
        case let .failure(problem):
            detail.stringValue = CheckPresentation(problem: problem, region: country).message
            evidence = problem.evidence
            dnsLocations = problem.step == .toolDNS ? evidence?.tool : evidence?.checkedPage
            let confirmed = problem.confirmedExit
            exit = (confirmed?.country ?? evidence?.exit).map(NodeRegions.name).map { location in
                (confirmed?.ip ?? evidence?.exitIP).map { location + " · " + $0 } ?? location
            }
            reason = problem.message == evidence?.summary ? problem.title : problem.message
        }
        let diagnostic = [reason, CheckPresentation.resolvers(evidence)].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let dns = dnsLocations?.label ?? (evidence == nil ? nil : "未确认")
        details.update(node: result.name, batchReachability: batchReachability, exit: exit, dns: dns, google: google,
                       record: diagnostic.isEmpty ? "暂无更多检测记录。" : diagnostic)
    }

    @objc private func toggleDetails() {
        let open = details.view.isHidden
        details.view.isHidden = !open
        detailsButton.title = open ? "收起检测详情" : "展开检测详情"
        detailsButton.image = NSImage(systemSymbolName: open ? "chevron.up" : "chevron.down",
                                      accessibilityDescription: nil)
        let expandedHeight: CGFloat = 590
        let collapsedHeight: CGFloat = 466
        var height = open ? expandedHeight : collapsedHeight
        if open, let screen = window.sheetParent?.screen ?? window.screen {
            // A sheet expands below its attachment point. Keep the footer above the Dock.
            let top = min(window.frame.maxY, screen.visibleFrame.maxY)
            height = min(height, max(collapsedHeight, top - screen.visibleFrame.minY - 12))
        }
        tableHeight.constant = open ? 196 - (expandedHeight - height) : 232
        window.setContentSize(NSSize(width: 620, height: height))
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
        refreshSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { nodes.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let name = nodes[row]
        let value: String
        let color: NSColor
        if column?.identifier.rawValue == "node" {
            (value, color) = (name, BrowserPalette.ink)
        } else {
            switch results[name]?.result {
            case .success?: (value, color) = ("符合要求", BrowserPalette.accent)
            case let .failure(problem)?:
                let explanation = CheckPresentation(problem: problem, region: country)
                (value, color) = (explanation.rowLabel, BrowserPalette.warning)
            case nil:
                if let step = activeSteps[name] {
                    switch step {
                    case .prepare: value = "正在连接"
                    case .exit: value = "正在检查出口"
                    case .toolDNS, .pageDNS: value = "正在检查地址查询"
                    case .browser: value = "正在完成"
                    }
                    color = BrowserPalette.accent
                } else {
                    (value, color) = (scanning ? "等待检查" : "未检查", BrowserPalette.muted)
                }
            }
        }
        return RegionCheckCell(value: value, textColor: color)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshSelection()
    }

    @objc private func closeOrStop() {
        if scanning {
            stopping = true
            closeButton.title = "正在停止…"
            closeButton.isEnabled = false
            refreshSummary()
        }
        action(nil)
    }

    @objc private func useSelected() {
        guard !scanning, let selection = selectedResult, selection.canUse else { return }
        action(selection.name)
    }
}

/// Keep status and node names legible when AppKit emphasizes the selected row.
private final class RegionCheckCell: NSTableCellView {
    private let normalColor: NSColor

    init(value: String, textColor: NSColor) {
        normalColor = textColor
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: value)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = textColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            textField?.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : normalColor
        }
    }
}
