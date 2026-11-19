import AppKit
import DevTabsCore

struct TabItem: Equatable {
    let id: WindowID
    let title: String
    let pid: pid_t
    let active: Bool
    /// Cambió de título desde la última vez que se la miró.
    let activity: Bool
}

/// La barra de un stack: una ventana flotante sin borde que no se lleva el foco al hacer clic.
final class TabBarPanel: NSPanel {
    let bar = TabBarView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 28),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.ignoresCycle, .fullScreenNone]
        contentView = bar
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class TabBarView: NSView {
    var tabs: [TabItem] = [] {
        didSet { if tabs != oldValue { needsDisplay = true } }
    }
    var onClick: ((WindowID) -> Void)?
    /// Una pestaña arrastrada y soltada sobre otra posición: la ventana y la posición nueva.
    var onReorder: ((WindowID, Int) -> Void)?

    private let accent = NSColor(srgbRed: 0.98, green: 0.70, blue: 0.36, alpha: 1)
    private var icons: [pid_t: NSImage] = [:]
    private var dragStart: Int?
    private var dropTarget: Int? {
        didSet { if dropTarget != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        guard !tabs.isEmpty else { return }
        let width = bounds.width / CGFloat(tabs.count)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for (index, tab) in tabs.enumerated() {
            let cell = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height).insetBy(dx: 2, dy: 3)
            if tab.active {
                accent.setFill()
                NSBezierPath(roundedRect: cell, xRadius: 5, yRadius: 5).fill()
            } else if index > 0 && !tabs[index - 1].active {
                NSColor.separatorColor.setFill()
                NSRect(x: cell.minX - 2, y: cell.minY + 4, width: 1, height: cell.height - 8).fill()
            }
            var x = cell.minX + 8
            if let icon = icon(for: tab.pid) {
                icon.draw(in: NSRect(x: x, y: cell.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver,
                          fraction: 1, respectFlipped: true, hints: nil)
                x += 22
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: tab.active ? .semibold : .regular),
                .foregroundColor: tab.active ? NSColor.black : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            var textEnd = cell.maxX - 6
            if tab.activity && !tab.active {
                accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: cell.maxX - 14, y: cell.midY - 4, width: 8, height: 8)).fill()
                textEnd -= 12
            }
            let text = NSRect(x: x, y: cell.midY - 8, width: max(0, textEnd - x), height: 16)
            (tab.title as NSString).draw(with: text, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
            if index == dropTarget {
                accent.setStroke()
                let outline = NSBezierPath(roundedRect: cell.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
                outline.lineWidth = 2
                outline.stroke()
            }
        }
    }

    /// Un clic elige la pestaña; arrastrarla y soltarla sobre otra la lleva a esa posición.
    override func mouseDown(with event: NSEvent) {
        dragStart = index(at: event)
        dropTarget = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let current = index(at: event) else { return }
        dropTarget = current == start ? nil : current
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dropTarget = nil
        }
        guard let start = dragStart, tabs.indices.contains(start) else { return }
        if let target = dropTarget {
            onReorder?(tabs[start].id, target)
        } else if index(at: event) == start {
            onClick?(tabs[start].id)
        }
    }

    private func index(at event: NSEvent) -> Int? {
        guard !tabs.isEmpty else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.x / (bounds.width / CGFloat(tabs.count)))
        return tabs.indices.contains(index) ? index : nil
    }

    private func icon(for pid: pid_t) -> NSImage? {
        if let cached = icons[pid] { return cached }
        let image = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = image
        return image
    }
}
