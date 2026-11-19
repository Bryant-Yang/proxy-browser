import AppKit

@MainActor
final class CheckDetails: NSObject {
    let button = NSButton(title: "展开检测详情", target: nil, action: nil)
    let view = BrowserSurface(BrowserPalette.card, radius: 14, border: true)
    var onExpansionChange: (() -> Void)?
    var isExpanded: Bool { !view.isHidden }
    private let textView: NSTextView
    private let metrics = NSStackView()
    private let values = (0..<4).map { _ in NSTextField(labelWithString: "") }
    private let extraButton = NSButton(title: "打开检测页", target: nil, action: nil)
    private var openPage: (() -> Void)?

    override init() {
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init()
        button.target = self
        button.action = #selector(toggle)
        button.bezelStyle = .inline
        button.controlSize = .small
        button.imagePosition = .imageTrailing
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        button.contentTintColor = BrowserPalette.accent
        button.isHidden = true

        let heading = NSTextField(labelWithString: "检测详情")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = BrowserPalette.ink
        scroll.drawsBackground = false
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.setAccessibilityLabel("技术检测结果")

        extraButton.target = self
        extraButton.action = #selector(showPage)
        extraButton.bezelStyle = .rounded
        extraButton.controlSize = .small
        extraButton.isHidden = true
        let header = NSStackView(views: [heading, NSView(), extraButton])
        header.alignment = .centerY
        header.heightAnchor.constraint(equalToConstant: 22).isActive = true

        metrics.distribution = .fillEqually
        metrics.spacing = 14
        metrics.alignment = .top
        for (label, value) in zip(["实际出口", "工具 DNS", "网页 DNS", "下游 DNS"], values) {
            metrics.addArrangedSubview(RegionCheckDetails.metric(label, value: value))
        }
        metrics.isHidden = true

        let content = NSStackView(views: [header, metrics, scroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        view.isHidden = true

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ] + content.arrangedSubviews.map { $0.widthAnchor.constraint(equalTo: content.widthAnchor) })
    }

    func update(_ note: String, evidence: DNSEvidence?, confirmedExit: ExitLocation?, openPage: (() -> Void)?) {
        let country = confirmedExit?.country ?? evidence?.exit
        let ip = confirmedExit?.ip ?? evidence?.exitIP
        let exit = country.map { country in
            [NodeRegions.name(country), ip].compactMap { $0 }.joined(separator: " · ")
        }
        let labels = [exit, evidence?.tool?.label, evidence?.page?.label, evidence?.downstream?.label]
        for (index, label) in labels.enumerated() {
            values[index].stringValue = label ?? ""
            values[index].toolTip = label
            metrics.arrangedSubviews[index].isHidden = label == nil
        }
        metrics.isHidden = labels.allSatisfy { $0 == nil }

        let text = [note, CheckPresentation.resolvers(evidence)].filter { !$0.isEmpty }.joined(separator: "\n")
        if textView.string != text {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: BrowserPalette.ink,
                .paragraphStyle: paragraph
            ]))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        self.openPage = openPage
        extraButton.isHidden = openPage == nil
        button.isHidden = text.isEmpty && metrics.isHidden
        if button.isHidden { close() }
    }

    func close() { setExpanded(false) }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        view.isHidden = !expanded
        button.title = expanded ? "收起检测详情" : "展开检测详情"
        button.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)
        onExpansionChange?()
    }

    @objc private func toggle() { setExpanded(!isExpanded) }

    @objc private func showPage() {
        close()
        openPage?()
    }
}
