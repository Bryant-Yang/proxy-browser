import AppKit

@MainActor
final class CheckDetails: NSObject {
    let button = NSButton(title: "检测详情", target: nil, action: nil)
    private let popover = NSPopover()
    private let textView = NSTextView()
    private let extraButton = NSButton(title: "打开检测页", target: nil, action: nil)
    private var openPage: (() -> Void)?

    override init() {
        super.init()
        button.target = self
        button.action = #selector(toggle)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        button.imagePosition = .imageTrailing
        button.isHidden = true

        let heading = NSTextField(labelWithString: "检测详情")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.textColor = BrowserPalette.ink
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 5)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.setAccessibilityLabel("技术检测结果")
        scroll.heightAnchor.constraint(equalToConstant: 182).isActive = true

        extraButton.target = self
        extraButton.action = #selector(showPage)
        extraButton.bezelStyle = .rounded
        extraButton.isHidden = true
        let content = NSStackView(views: [heading, scroll, extraButton])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false

        let controller = NSViewController()
        controller.view = BrowserSurface(BrowserPalette.card)
        controller.view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 14),
            content.bottomAnchor.constraint(lessThanOrEqualTo: controller.view.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 394, height: 270)
        popover.behavior = .transient
    }

    func update(_ text: String, openPage: (() -> Void)? = nil) {
        if textView.string != text {
            textView.string = text
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        self.openPage = openPage
        extraButton.isHidden = openPage == nil
        button.isHidden = text.isEmpty
        if text.isEmpty { close() }
    }

    func close() { popover.performClose(nil) }

    @objc private func toggle() {
        if popover.isShown { close() }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY) }
    }

    @objc private func showPage() {
        close()
        openPage?()
    }
}
