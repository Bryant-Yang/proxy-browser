import AppKit
import CoreGraphics
import UniformTypeIdentifiers

@MainActor
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum Screen {
        case idle
        case checking(ConnectionStep, String)
        case opening(ProbeResult, String, Date)
        case connected(ProbeResult, String)
        case stopping(String)
        case failed(ConnectionProblem)
    }

    private var window: NSWindow!
    private let sources = NSPopUpButton()
    private let regions = NSPopUpButton()
    private let nodes = NSPopUpButton()
    private let browsers = NSPopUpButton()
    private let importButton = NSButton(title: "导入…", target: nil, action: nil)
    private let settingsButton = NSButton(title: "浏览器与内核", target: nil, action: nil)
    private let primary = ConnectButton(frame: .zero)
    private let secondary = NSButton(title: "", target: nil, action: nil)
    private let deviceSummary = NSTextField(labelWithString: "")
    private let nodeHint = NSTextField(wrappingLabelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let progress = CheckProgress(frame: .zero)
    private let checks = [CheckRow("建立连接"), CheckRow("确认出口"), CheckRow("核对 DNS")]
    private let advanced = NSPopover()
    private let coreLabel = NSTextField(labelWithString: "")
    private var profiles: [ProfileChoice] = []
    private var browserChoices: [BrowserChoice] = []
    private var coreURL: URL?
    private var route = RouteSelection()
    private var routesBySource: [String: RouteSelection] = [:]
    private var preferences: [String: String] = [:]
    private var sourceError: String?
    private var screen = Screen.idle
    private var engine: Engine?
    private var timer: Timer?
    private var browserPID: pid_t = 0
    private var absentTicks = 0
    private var quitting = false
    private var closingProblem: ConnectionProblem?
    private var settingsURL: URL { Configuration.support.appendingPathComponent("settings.json") }

    private var source: ProfileChoice? {
        guard let path = sources.selectedItem?.representedObject as? String else { return nil }
        return profiles.first { $0.url.path == path }
    }

    private var browser: BrowserChoice? {
        guard let path = browsers.selectedItem?.representedObject as? String else { return nil }
        return browserChoices.first { $0.executable.path == path }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let data = try? Data(contentsOf: settingsURL),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            preferences = saved
        }
        buildMenu()
        buildWindow()
        discover()
    }

    private func buildMenu() {
        let menu = NSMenu()
        let root = NSMenuItem()
        menu.addItem(root)
        let appMenu = NSMenu()
        let refresh = appMenu.addItem(withTitle: "重新查找本机配置", action: #selector(refreshSources), keyEquivalent: "r")
        refresh.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出独立纯净代理", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = menu
    }

    private func text(_ value: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular,
                      color: NSColor = BrowserPalette.ink) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 10) -> NSStackView {
        let result = NSStackView(views: views)
        result.distribution = .fill
        result.orientation = vertical ? .vertical : .horizontal
        result.alignment = vertical ? .leading : .centerY
        result.spacing = spacing
        result.translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            for view in views { view.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true }
        }
        return result
    }

    private func place(_ view: NSView, in container: NSView, inset: CGFloat) {
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            view.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -inset)
        ])
    }

    private func field(_ label: String, _ control: NSView) -> NSStackView {
        stack([text(label, 12, .semibold, color: BrowserPalette.muted), control], vertical: true, spacing: 6)
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 824, height: 512),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "独立纯净代理"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        let canvas = BrowserSurface(BrowserPalette.canvas)
        canvas.translatesAutoresizingMaskIntoConstraints = true
        window.contentView = canvas

        let mark = RouteMark()
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant: 52), mark.heightAnchor.constraint(equalToConstant: 52)])
        let header = stack([
            mark,
            stack([text("独立纯净代理", 27, .semibold),
                   text("为专用窗口选择出口，验证通过后开始浏览。", 13, color: BrowserPalette.muted)],
                  vertical: true, spacing: 4)
        ], spacing: 14)
        let connection = buildRouteCard()
        let status = buildStatusCard()
        let body = stack([connection, status], spacing: 16)
        body.alignment = .top
        NSLayoutConstraint.activate([
            body.heightAnchor.constraint(equalToConstant: 306),
            connection.heightAnchor.constraint(equalTo: body.heightAnchor),
            status.heightAnchor.constraint(equalTo: body.heightAnchor),
            status.widthAnchor.constraint(equalToConstant: 298)
        ])

        primary.target = self
        primary.action = #selector(primaryAction)
        primary.bezelStyle = .rounded
        primary.controlSize = .large
        primary.isBordered = false
        primary.focusRingType = .exterior
        primary.widthAnchor.constraint(equalToConstant: 176).isActive = true
        primary.heightAnchor.constraint(equalToConstant: 42).isActive = true
        secondary.target = self
        secondary.action = #selector(secondaryAction)
        secondary.bezelStyle = .rounded
        secondary.controlSize = .large
        secondary.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        let footer = stack([text("专用窗口 · 独立登录资料", 12, .medium, color: BrowserPalette.muted),
                            NSView(), secondary, primary], spacing: 10)
        footer.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let column = stack([header, body, footer], vertical: true, spacing: 18)
        canvas.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 42),
            column.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 28),
            column.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -28),
            column.bottomAnchor.constraint(lessThanOrEqualTo: canvas.bottomAnchor, constant: -18)
        ])
        window.initialFirstResponder = sources
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildRouteCard() -> NSView {
        let card = BrowserSurface(BrowserPalette.card, radius: 18, border: true)
        for (control, label, action) in [(sources, "配置来源", #selector(sourceChanged)),
                                         (regions, "地区筛选", #selector(regionChanged)),
                                         (nodes, "代理节点", #selector(nodeChanged))] {
            control.target = self
            control.action = action
            control.controlSize = .large
            control.font = .systemFont(ofSize: 13)
            control.setAccessibilityLabel(label)
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            control.heightAnchor.constraint(equalToConstant: 33).isActive = true
            control.cell?.lineBreakMode = .byTruncatingTail
        }
        importButton.target = self
        importButton.action = #selector(importProfile)
        importButton.bezelStyle = .rounded
        importButton.controlSize = .large
        importButton.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let region = field("地区", regions)
        region.widthAnchor.constraint(equalToConstant: 145).isActive = true
        let pickers = stack([region, field("节点", nodes)], spacing: 10)
        pickers.alignment = .top
        nodeHint.font = .systemFont(ofSize: 12)
        nodeHint.textColor = BrowserPalette.muted
        nodeHint.maximumNumberOfLines = 2
        nodeHint.heightAnchor.constraint(greaterThanOrEqualToConstant: 33).isActive = true
        deviceSummary.font = .systemFont(ofSize: 12, weight: .medium)
        deviceSummary.textColor = BrowserPalette.muted
        settingsButton.target = self
        settingsButton.action = #selector(showSettings)
        settingsButton.bezelStyle = .rounded
        settingsButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        settingsButton.imagePosition = .imageLeading
        let divider = NSBox()
        divider.boxType = .separator
        let form = stack([
            text("选择线路", 18, .semibold),
            field("配置", stack([sources, importButton])),
            pickers,
            nodeHint,
            divider,
            stack([deviceSummary, NSView(), settingsButton])
        ], vertical: true, spacing: 12)
        form.setCustomSpacing(16, after: form.arrangedSubviews[0])
        place(form, in: card, inset: 20)
        return card
    }

    private func buildStatusCard() -> NSView {
        let card = BrowserSurface(BrowserPalette.status, to: BrowserPalette.statusEdge, radius: 18, border: true)
        let eyebrow = text("连接检查", 12, .semibold, color: BrowserPalette.accent)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = BrowserPalette.ink
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = BrowserPalette.muted
        detail.maximumNumberOfLines = 4
        detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 63).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let list = stack(checks, vertical: true, spacing: 4)
        let content = stack([eyebrow, title, detail, progress, list], vertical: true, spacing: 10)
        content.setCustomSpacing(14, after: progress)
        place(content, in: card, inset: 22)
        return card
    }

    private func addItem(_ title: String, id: String, to popup: NSPopUpButton) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = id
        popup.menu?.addItem(item)
    }

    private func choose(_ id: String?, in popup: NSPopUpButton) {
        let item = popup.itemArray.first { ($0.representedObject as? String) == id }
        popup.select(item ?? popup.itemArray.first)
    }

    private func discover() {
        profiles = Configuration.profiles()
        if let custom = preferences["source"],
           !profiles.contains(where: { $0.url.path == custom }),
           (try? Configuration.nodes(URL(fileURLWithPath: custom))) != nil {
            profiles.append(ProfileChoice(name: URL(fileURLWithPath: custom).lastPathComponent, url: URL(fileURLWithPath: custom)))
        }
        sources.removeAllItems()
        for profile in profiles { addItem(profile.name, id: profile.url.path, to: sources) }
        if profiles.isEmpty { addItem("尚未找到配置", id: "", to: sources) }
        choose(preferences["source"], in: sources)

        let savedCore = preferences["core"].map { URL(fileURLWithPath: $0) }
        coreURL = savedCore.flatMap {
            FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil
        } ?? Configuration.core()

        browserChoices = Configuration.browsers()
        if let path = preferences["browser"], !browserChoices.contains(where: { $0.executable.path == path }),
           FileManager.default.isExecutableFile(atPath: path) {
            browserChoices.append(BrowserChoice(name: URL(fileURLWithPath: path).lastPathComponent,
                                                executable: URL(fileURLWithPath: path)))
        }
        refreshBrowserMenu(selected: preferences["browser"])
        loadRoute()
    }

    private func refreshBrowserMenu(selected path: String?) {
        browsers.removeAllItems()
        for option in browserChoices { addItem(option.name, id: option.executable.path, to: browsers) }
        choose(path, in: browsers)
    }

    private func loadRoute() {
        sourceError = nil
        route = RouteSelection()
        if let source {
            do {
                let names = try Configuration.nodes(source.url).compactMap { $0["name"] as? String }
                let cached = routesBySource[source.url.path]
                let useSaved = preferences["source"] == source.url.path
                route = RouteSelection(names: names, savedNode: cached?.selected?.name ?? (useSaved ? preferences["node"] : nil),
                                       savedFilter: cached?.filter ?? (useSaved ? preferences["region_filter"] : nil),
                                       legacyCountry: useSaved ? preferences["country"] : nil)
                routesBySource[source.url.path] = route
            } catch {
                sourceError = (error as? AppFailure)?.message ?? "无法读取这份配置。请重新查找或导入。"
            }
        }
        populateRegions()
        populateNodes()
        screen = .idle
        render()
    }

    private func populateRegions() {
        regions.removeAllItems()
        addItem("全部地区", id: "", to: regions)
        for code in route.regions {
            addItem(NodeRegions.name(code) + " · " + code, id: code, to: regions)
        }
        choose(route.filter, in: regions)
    }

    private func populateNodes() {
        nodes.removeAllItems()
        addItem(route.filter.isEmpty ? "选择节点…" : "选择" + NodeRegions.name(route.filter) + "节点…", id: "", to: nodes)
        for node in route.available { addItem(node.name, id: node.name, to: nodes) }
        choose(route.selected?.name ?? "", in: nodes)
        nodes.toolTip = route.selected?.name
    }

    private func saveSelection() {
        guard let source else { return }
        routesBySource[source.url.path] = route
        preferences = ["source": source.url.path, "node": route.selected?.name ?? "", "region_filter": route.filter]
        preferences["browser"] = browser?.executable.path
        preferences["core"] = coreURL?.path
        do {
            try FileManager.default.createDirectory(at: Configuration.support, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: preferences)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            NSLog("ProxyBrowser could not save its own settings: %@", error.localizedDescription)
        }
    }

    @objc private func refreshSources() {
        guard engine == nil else { return }
        discover()
    }

    @objc private func sourceChanged() {
        loadRoute()
        saveSelection()
    }

    @objc private func regionChanged() {
        route.setFilter(regions.selectedItem?.representedObject as? String ?? "")
        populateNodes()
        selectionChanged()
    }

    @objc private func nodeChanged() {
        route.select(nodes.selectedItem?.representedObject as? String)
        selectionChanged()
    }

    private func selectionChanged() {
        saveSelection()
        screen = .idle
        render()
    }

    @objc private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml"), .json].compactMap { $0 }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择包含代理节点的 Clash YAML 或 JSON 配置。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try Configuration.nodes(url)
            if !profiles.contains(where: { $0.url == url }) {
                profiles.append(ProfileChoice(name: url.lastPathComponent, url: url))
                addItem(url.lastPathComponent, id: url.path, to: sources)
            }
            choose(url.path, in: sources)
            sourceChanged()
        } catch {
            screen = .failed(ConnectionProblem(step: .prepare, title: "无法导入配置",
                                               message: (error as? AppFailure)?.message ?? "请选择有效的 Clash 配置。",
                                               recovery: .importConfig))
            render()
        }
    }

    @objc private func showSettings() {
        if advanced.isShown { advanced.close(); return }
        let controller = NSViewController()
        let canvas = BrowserSurface(BrowserPalette.card)
        canvas.translatesAutoresizingMaskIntoConstraints = true
        controller.view = canvas
        let selectBrowser = NSButton(title: "选择应用…", target: self, action: #selector(chooseBrowser))
        let selectCore = NSButton(title: "选择内核…", target: self, action: #selector(chooseCore))
        browsers.target = self
        browsers.action = #selector(browserChanged)
        browsers.setAccessibilityLabel("专用浏览器")
        browsers.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        coreLabel.textColor = BrowserPalette.muted
        coreLabel.font = .systemFont(ofSize: 12)
        coreLabel.stringValue = coreURL?.lastPathComponent ?? "尚未找到 Mihomo 内核"
        coreLabel.toolTip = coreURL?.path
        let content = stack([text("浏览器与内核", 17, .semibold),
                             field("专用浏览器", stack([browsers, selectBrowser])),
                             field("代理内核", stack([coreLabel, NSView(), selectCore]))],
                            vertical: true, spacing: 12)
        place(content, in: canvas, inset: 18)
        advanced.behavior = .transient
        advanced.contentViewController = controller
        advanced.contentSize = NSSize(width: 360, height: 184)
        advanced.show(relativeTo: settingsButton.bounds, of: settingsButton, preferredEdge: .maxY)
    }

    @objc private func browserChanged() { selectionChanged() }

    @objc private func chooseBrowser() {
        advanced.close()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.message = "选择 Chrome、Edge、Brave 或 Chromium 应用。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let option = Configuration.browser(at: url) else {
            showSettingsIssue("请选择受支持的 Chromium 系浏览器。")
            return
        }
        if !browserChoices.contains(where: { $0.executable == option.executable }) {
            browserChoices.append(option)
        }
        refreshBrowserMenu(selected: option.executable.path)
        selectionChanged()
    }

    @objc private func chooseCore() {
        advanced.close()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.message = "选择 Clash Verge 自带的 verge-mihomo 或 mihomo。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path),
              ["mihomo", "verge-mihomo"].contains(url.lastPathComponent) else {
            showSettingsIssue("请选择可执行的 Mihomo 内核文件。")
            return
        }
        coreURL = url
        selectionChanged()
    }

    private func showSettingsIssue(_ message: String) {
        screen = .failed(ConnectionProblem(step: .prepare, title: "请检查浏览器设置",
                                           message: message, recovery: .settings))
        render()
    }

    private func render() {
        let busy = engine != nil
        sources.isEnabled = !busy && !profiles.isEmpty
        regions.isEnabled = !busy && !route.regions.isEmpty
        nodes.isEnabled = !busy && !route.available.isEmpty
        importButton.isEnabled = !busy
        settingsButton.isEnabled = !busy
        deviceSummary.stringValue = browser?.name ?? "尚未选择浏览器"

        let count = route.available.count
        if source == nil {
            nodeHint.stringValue = "导入配置，或使用菜单中的「重新查找本机配置」。"
        } else if route.filter.isEmpty {
            nodeHint.stringValue = "\(count) 个节点 · 连接时确认实际出口与 DNS 地区"
        } else {
            nodeHint.stringValue = "\(NodeRegions.name(route.filter)) · \(count) 个节点\n按名称归类，连接时核对实际出口。"
        }
        primary.title = "连接并打开"
        primary.isEnabled = false
        primary.keyEquivalent = ""
        secondary.isHidden = true
        secondary.isEnabled = true
        title.textColor = BrowserPalette.ink
        checks.forEach { $0.show(.waiting) }
        progress.completed = 0

        switch screen {
        case .idle:
            if let sourceError {
                title.stringValue = "配置无法读取"
                detail.stringValue = sourceError
                primary.title = "导入配置…"
                primary.isEnabled = true
            } else if source == nil {
                title.stringValue = "先添加一份配置"
                detail.stringValue = "选择本机 Clash 配置，或导入包含代理节点的文件。"
                primary.title = "导入配置…"
                primary.isEnabled = true
            } else if browser == nil || coreURL == nil {
                title.stringValue = "还缺一项设置"
                detail.stringValue = browser == nil ? "选择一个 Chromium 系浏览器。" : "选择本机的 Mihomo 内核。"
                primary.title = "浏览器与内核"
                primary.isEnabled = true
            } else if route.selected == nil {
                title.stringValue = "选择一个节点"
                detail.stringValue = route.filter.isEmpty ? "先从节点列表选择你想使用的出口。" :
                    "请选择一个\(NodeRegions.name(route.filter))节点。完成选择后即可连接。"
            } else {
                title.stringValue = "准备就绪"
                detail.stringValue = "将检查实际出口、DNS 地区，然后打开专用浏览器。"
                primary.isEnabled = true
            }
        case let .checking(step, message):
            title.stringValue = ["正在建立连接", "正在确认出口", "正在核对 DNS", "正在打开浏览器"][step.rawValue]
            detail.stringValue = message
            progress.completed = step.rawValue
            showChecks(upTo: step, active: .active)
            primary.title = "连接检查中"
            secondary.title = "取消"
            secondary.isHidden = false
        case let .opening(result, _, _):
            title.stringValue = "正在打开浏览器"
            detail.stringValue = "已验证\(NodeRegions.name(result.country))出口，正在等待专用窗口。"
            completeChecks()
            primary.title = "正在打开"
            secondary.title = "取消"
            secondary.isHidden = false
        case let .connected(result, interface):
            title.stringValue = NodeRegions.name(result.country) + " · 已连接"
            detail.stringValue = "\(result.exitIP)\n\(result.dns.count) 个 DNS 均为\(NodeRegions.name(result.country)) · \(interface)"
            completeChecks()
            primary.title = "打开检测页"
            primary.isEnabled = true
            secondary.title = "断开"
            secondary.isHidden = false
        case let .stopping(message):
            title.stringValue = "正在结束连接"
            detail.stringValue = message
            primary.title = "正在结束"
        case let .failed(problem):
            title.stringValue = problem.title
            title.textColor = BrowserPalette.warning
            detail.stringValue = problem.message
            showChecks(upTo: problem.step, active: .failed)
            progress.completed = problem.step.rawValue
            switch problem.recovery {
            case .retry: primary.title = "重试连接"
            case .selectNode, .allRegions: primary.title = route.available.count > 1 ? "更换节点" : "查看全部节点"
            case .settings: primary.title = "浏览器与内核"
            case .importConfig: primary.title = "重新导入…"
            }
            primary.isEnabled = true
            if !route.filter.isEmpty, route.available.count > 1,
               problem.recovery == .allRegions || problem.recovery == .selectNode {
                secondary.title = "查看全部节点"
                secondary.isHidden = false
            }
        }
        detail.toolTip = detail.stringValue
        primary.toolTip = primary.title
        if primary.isEnabled { primary.keyEquivalent = "\r" }
    }

    private func showChecks(upTo step: ConnectionStep, active: CheckRow.State) {
        for (index, row) in checks.enumerated() {
            row.show(index < step.rawValue ? .passed : index == step.rawValue ? active : .waiting)
        }
    }

    private func completeChecks() {
        progress.completed = 3
        checks.forEach { $0.show(.passed) }
    }

    @objc private func primaryAction() {
        if case .connected = screen {
            engine?.openPage()
            NSRunningApplication(processIdentifier: browserPID)?.activate(options: [.activateAllWindows])
            return
        }
        guard engine == nil else { return }
        if case let .failed(problem) = screen {
            if problem.recovery == .settings { showSettings(); return }
            if problem.recovery == .importConfig { importProfile(); return }
            if problem.recovery == .selectNode || problem.recovery == .allRegions {
                if route.available.count > 1 { nodes.performClick(nil) } else { showAllNodes() }
                return
            }
        }
        guard let source, sourceError == nil else { importProfile(); return }
        guard let browser, let core = coreURL else { showSettings(); return }
        guard let node = route.selected, route.available.contains(node) else { return }
        let request = ConnectionRequest(source: source.url, node: node.name, core: core,
                                        browser: browser.executable, country: route.filter)
        advanced.close()
        saveSelection()
        screen = .checking(.prepare, "正在启动独立代理内核。")
        browserPID = 0
        absentTicks = 0
        let connection = Engine(notify: { [weak self] update in
            DispatchQueue.main.async { self?.connectionUpdated(update) }
        }, finished: { [weak self] error in
            DispatchQueue.main.async { self?.connectionEnded(error) }
        })
        engine = connection
        render()
        connection.start(request)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWindows() }
        }
    }

    @objc private func secondaryAction() {
        if case .failed = screen {
            showAllNodes()
        } else if engine != nil {
            stop("正在关闭专用窗口和独立代理。")
        }
    }

    private func showAllNodes() {
        choose("", in: regions)
        regionChanged()
        nodes.performClick(nil)
    }

    private func connectionUpdated(_ update: ConnectionUpdate) {
        guard !quitting else { return }
        if case .stopping = screen { return }
        switch update {
        case let .checking(step, message):
            screen = .checking(step, message)
        case let .opening(result, interface, pid):
            browserPID = pid
            screen = .opening(result, interface, Date())
        }
        render()
    }

    private func stop(_ message: String) {
        screen = .stopping(message)
        render()
        engine?.stop()
    }

    private func connectionEnded(_ error: ConnectionProblem?) {
        let problem = closingProblem ?? error
        closingProblem = nil
        let browserExitedBeforeShowing: Bool
        if case .opening = screen { browserExitedBeforeShowing = true } else { browserExitedBeforeShowing = false }
        engine = nil
        browserPID = 0
        timer?.invalidate()
        timer = nil
        if quitting { NSApp.reply(toApplicationShouldTerminate: true); return }
        if let problem {
            screen = .failed(problem)
        } else if browserExitedBeforeShowing {
            screen = .failed(browserLaunchProblem())
        } else {
            screen = .idle
        }
        render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func browserLaunchProblem() -> ConnectionProblem {
        ConnectionProblem(step: .browser, title: "浏览器未打开",
                          message: "代理检查已通过。请确认所选浏览器能够启动，或换一个浏览器。",
                          recovery: .settings)
    }

    private func checkWindows() {
        guard browserPID > 0, !quitting,
              let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return }
        let exists = windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == browserPID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return false }
            return ((bounds["Width"] as? NSNumber)?.doubleValue ?? 0) > 180 &&
                   ((bounds["Height"] as? NSNumber)?.doubleValue ?? 0) > 100
        }
        switch screen {
        case let .opening(result, interface, started):
            if exists {
                screen = .connected(result, interface)
                render()
                NSRunningApplication(processIdentifier: browserPID)?.activate(options: [.activateAllWindows])
            } else if Date().timeIntervalSince(started) > 18 {
                closingProblem = browserLaunchProblem()
                stop("正在收回本次连接。")
            }
        case .connected:
            absentTicks = exists ? 0 : absentTicks + 1
            if absentTicks >= 6 { stop("专用窗口已关闭，正在结束代理连接。") }
        default:
            break
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard engine != nil else { return .terminateNow }
        quitting = true
        stop("正在关闭专用窗口和独立代理。")
        return .terminateLater
    }
}
