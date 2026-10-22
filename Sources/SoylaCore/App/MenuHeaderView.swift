import AppKit

/// The status menu's two-line header (audit 2026-10-19 V-05). A disabled `NSMenuItem` is greyed by macOS (2.34:1, the
/// least legible line in the menu), so the header is a custom view: the dot in system green or orange, the title in
/// `labelColor` 13/600, the detail in `secondaryLabelColor` 12. It never highlights and takes no clicks.
@MainActor
final class MenuHeaderView: NSView {
    private let dot = NSTextField(labelWithString: "●")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        dot.font = .systemFont(ofSize: 11)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        for f in [title, detail] { f.lineBreakMode = .byTruncatingTail; f.maximumNumberOfLines = 1 }
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [dot, text])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ w: MenuHeader.Text, tone: MenuHeader.Tone) {
        dot.textColor = tone == .ok ? .systemGreen : .systemOrange
        title.stringValue = w.title
        detail.stringValue = w.detail
        setAccessibilityLabel("\(w.title). \(w.detail)")
        let size = fittingSize
        setFrameSize(NSSize(width: max(220, size.width), height: size.height))
    }

    /// No highlight, no click: the header only reports.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
