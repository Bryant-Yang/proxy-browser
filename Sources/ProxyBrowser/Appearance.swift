import AppKit

enum BrowserPalette {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }

    static let canvas = adaptive(0xF0F4F2, 0x101715)
    static let card = adaptive(0xFFFFFF, 0x1A2420)
    static let status = adaptive(0xE7F2EC, 0x142923)
    static let statusEdge = adaptive(0xDAECE3, 0x1A352C)
    static let edge = adaptive(0xDCE7E0, 0x2C3D35)
    static let ink = adaptive(0x152C23, 0xEBF5EF)
    static let muted = adaptive(0x526B60, 0xA8BFB4)
    static let accent = adaptive(0x146B50, 0x79E0B9)
    static let warning = adaptive(0x8F5017, 0xF1BC83)
    static let iconFill = adaptive(0xDDEFE6, 0x203D32)
}

final class BrowserSurface: NSView {
    private let fill: NSColor
    private let end: NSColor?
    private let radius: CGFloat
    private let border: Bool

    init(_ fill: NSColor, to end: NSColor? = nil, radius: CGFloat = 0, border: Bool = false) {
        self.fill = fill
        self.end = end
        self.radius = radius
        self.border = border
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: border ? 0.5 : 0, dy: border ? 0.5 : 0),
                                xRadius: radius, yRadius: radius)
        if let end {
            NSGradient(starting: fill, ending: end)?.draw(in: path, angle: -38)
        } else {
            fill.setFill()
            path.fill()
        }
        if border {
            BrowserPalette.edge.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

final class RouteMark: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        BrowserPalette.iconFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        BrowserPalette.accent.setStroke()
        let points = [NSPoint(x: 13, y: 15), NSPoint(x: 26, y: 32), NSPoint(x: 39, y: 22)]
        let route = NSBezierPath()
        route.move(to: points[0])
        route.line(to: points[1])
        route.line(to: points[2])
        route.lineWidth = 1.7
        route.lineCapStyle = .round
        route.stroke()
        for point in points {
            let circle = NSBezierPath(ovalIn: NSRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
            BrowserPalette.iconFill.setFill()
            circle.fill()
            circle.lineWidth = 1.7
            circle.stroke()
        }
    }
}

final class CheckRow: NSStackView {
    enum State { case waiting, active, passed, failed }
    private let mark = NSImageView()
    private let label: NSTextField
    private let caption: NSTextField
    private let name: String

    init(_ name: String) {
        self.name = name
        label = NSTextField(labelWithString: name)
        caption = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        label.font = .systemFont(ofSize: 12, weight: .medium)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.setContentHuggingPriority(.required, for: .horizontal)
        mark.widthAnchor.constraint(equalToConstant: 16).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 16).isActive = true
        mark.imageScaling = .scaleProportionallyDown
        for view in [mark, label, NSView(), caption] { addArrangedSubview(view) }
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        show(.waiting)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    func show(_ state: State) {
        let symbol: String
        let wording: String
        let tint: NSColor
        switch state {
        case .waiting: (symbol, wording, tint) = ("circle", "待检查", BrowserPalette.muted)
        case .active: (symbol, wording, tint) = ("circle.dotted", "进行中", BrowserPalette.accent)
        case .passed: (symbol, wording, tint) = ("checkmark.circle.fill", "通过", BrowserPalette.accent)
        case .failed: (symbol, wording, tint) = ("exclamationmark.circle.fill", "未通过", BrowserPalette.warning)
        }
        mark.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        mark.contentTintColor = tint
        label.textColor = BrowserPalette.ink
        caption.textColor = tint
        caption.stringValue = wording
        setAccessibilityLabel(name + " " + wording)
    }
}

final class ConnectButton: NSButton {
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var title: String {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    private var shape: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 10, yRadius: 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor
        if !isEnabled {
            fill = BrowserPalette.iconFill
        } else if isHighlighted {
            fill = NSColor(srgbRed: 0.36, green: 0.72, blue: 0.59, alpha: 1)
        } else {
            fill = NSColor(srgbRed: hovered ? 0.56 : 0.48, green: hovered ? 0.91 : 0.85, blue: 0.71, alpha: 1)
        }
        fill.setFill()
        shape.fill()
        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: isEnabled ? NSColor(srgbRed: 0.04, green: 0.16, blue: 0.12, alpha: 1) : BrowserPalette.muted
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSColor.black.setFill(); shape.fill() }
}

final class CheckProgress: NSView {
    var completed = 0 {
        didSet {
            setAccessibilityValue(completed)
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("连接检查进度")
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(3)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 5
        let width = (bounds.width - gap * 2) / 3
        for index in 0..<3 {
            (index < completed ? BrowserPalette.accent : BrowserPalette.edge).setFill()
            let bar = NSRect(x: CGFloat(index) * (width + gap), y: (bounds.height - 3) / 2,
                             width: width, height: 3)
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
