import AppKit

@MainActor
final class RegionCheckDetails {
    let view = BrowserSurface(BrowserPalette.card, radius: 12, border: true)
    private let nodeName = NSTextField(labelWithString: "")
    private let reachability = NSTextField(labelWithString: "")
    private let exit = NSTextField(labelWithString: "")
    private let dns = NSTextField(labelWithString: "")
    private let google = NSTextField(labelWithString: "")
    private let record: NSTextView

    init() {
        let scroll = NSTextView.scrollableTextView()
        record = scroll.documentView as! NSTextView
        record.isEditable = false
        record.isSelectable = true
        record.drawsBackground = false
        record.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        record.textColor = BrowserPalette.muted
        record.textContainerInset = NSSize(width: 0, height: 3)
        record.setAccessibilityLabel("检测记录")
        scroll.drawsBackground = false
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        scroll.heightAnchor.constraint(equalToConstant: 86).isActive = true

        nodeName.font = .systemFont(ofSize: 13, weight: .semibold)
        nodeName.textColor = BrowserPalette.ink
        nodeName.isSelectable = true
        nodeName.lineBreakMode = .byTruncatingTail
        nodeName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reachability.font = .systemFont(ofSize: 11, weight: .medium)
        reachability.textColor = BrowserPalette.muted
        reachability.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [nodeName, NSView(), reachability])
        header.spacing = 8
        header.alignment = .centerY

        let metrics = NSStackView(views: [
            Self.metric("网页出口", value: exit),
            Self.metric("地址查询", value: dns),
            Self.metric("Google", value: google)
        ])
        metrics.spacing = 16
        metrics.distribution = .fillEqually
        metrics.alignment = .top
        let separator = NSBox()
        separator.boxType = .separator
        let content = NSStackView(views: [header, metrics, separator, scroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ] + content.arrangedSubviews.map { $0.widthAnchor.constraint(equalTo: content.widthAnchor) })
        view.isHidden = true
    }

    private static func metric(_ title: String, value: NSTextField) -> NSStackView {
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = BrowserPalette.muted
        value.font = .systemFont(ofSize: 13, weight: .semibold)
        value.textColor = BrowserPalette.ink
        value.lineBreakMode = .byTruncatingTail
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [caption, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        value.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    func update(node: String?, batchReachability: String, exit: String? = nil, dns: String? = nil,
                google: String? = nil, record: String) {
        nodeName.stringValue = node ?? "批量检查"
        nodeName.toolTip = node
        reachability.stringValue = batchReachability
        reachability.isHidden = batchReachability.isEmpty
        self.exit.stringValue = exit ?? "—"
        self.dns.stringValue = dns ?? "—"
        self.google.stringValue = google ?? "—"
        self.exit.toolTip = exit
        self.dns.toolTip = dns
        if self.record.string != record {
            self.record.string = record
            self.record.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }
}
