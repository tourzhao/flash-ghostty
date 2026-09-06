import AppKit

/// The application-owned Dock surface. Keeping this boundary small also lets
/// tests exercise ownership without modifying the running application's Dock.
@MainActor
protocol SessionAttentionDockTile: AnyObject {
    var size: NSSize { get }
    var contentView: NSView? { get set }
    func display()
}

extension NSDockTile: SessionAttentionDockTile {}

/// Adds a transient attention count without changing the native bell badge,
/// the persisted application icon, or the out-of-process Dock tile plug-in.
@MainActor
final class SessionAttentionDockRenderer {
    private let dockTile: any SessionAttentionDockTile
    private let iconProvider: @MainActor () -> NSImage?
    private var badgeView: SessionAttentionDockView?
    private var previousContentView: NSView?

    init(
        dockTile: (any SessionAttentionDockTile)? = nil,
        iconProvider: (@MainActor () -> NSImage?)? = nil
    ) {
        self.dockTile = dockTile ?? NSApp.dockTile
        self.iconProvider = iconProvider ?? Self.applicationIcon
    }

    func update(count: Int) {
        guard count > 0 else {
            stop()
            return
        }

        let view = badgeView ?? SessionAttentionDockView(
            frame: NSRect(origin: .zero, size: dockTile.size),
            icon: iconProvider(),
            count: count
        )
        let needsInstallation = dockTile.contentView !== view
        guard needsInstallation || view.count != count else { return }

        if needsInstallation {
            previousContentView = dockTile.contentView
            dockTile.contentView = view
        }
        badgeView = view
        view.count = count
        dockTile.display()
    }

    /// Call after the configured app icon has finished updating. In particular,
    /// changing back to the default must not capture the previous custom icon.
    func refreshIcon() {
        guard let badgeView, dockTile.contentView === badgeView else { return }
        badgeView.icon = iconProvider()
        dockTile.display()
    }

    func stop() {
        // Another feature may have replaced the content view since our last
        // update. Never restore an old view over somebody else's replacement.
        if let badgeView, dockTile.contentView === badgeView {
            dockTile.contentView = previousContentView
            dockTile.display()
        }
        badgeView = nil
        previousContentView = nil
    }

    private static func applicationIcon() -> NSImage? {
        if let customIcon = UserDefaults.ghostty.appIcon?.image(in: .main) {
            return customIcon
        }

        // The running application's icon preserves Tahoe's current icon tint.
        // Restoring a nil content view when the count clears also restores the
        // system-managed Icon Composer presentation rather than a static copy.
        return NSRunningApplication.current.icon ??
            NSApp.applicationIconImage ?? NSImage(named: "AppIconImage")
    }
}

enum SessionAttentionDockBadge {
    static func label(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    /// AppKit view coordinates start at the lower-left. Leave the upper-right
    /// available for AppKit's existing, independent terminal bell badge.
    static func frame(in bounds: NSRect) -> NSRect {
        let side = max(0, min(bounds.width, bounds.height))
        let diameter = side * 0.36
        let inset = side * 0.025
        return NSRect(
            x: bounds.minX + inset,
            y: bounds.maxY - inset - diameter,
            width: diameter,
            height: diameter
        )
    }
}

@MainActor
final class SessionAttentionDockView: NSView {
    var icon: NSImage?
    var count: Int {
        didSet { updateAccessibilityLabel() }
    }

    init(frame: NSRect, icon: NSImage?, count: Int) {
        self.icon = icon
        self.count = count
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibilityLabel()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let icon, icon.size.width > 0, icon.size.height > 0 {
            let scale = min(bounds.width / icon.size.width, bounds.height / icon.size.height)
            let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
            icon.draw(in: NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        }

        guard let label = SessionAttentionDockBadge.label(for: count) else { return }
        let badge = SessionAttentionDockBadge.frame(in: bounds)
        guard badge.width > 0 else { return }

        // A fixed red keeps white text readable in light, dark, and tinted icon
        // appearances. Drawing this view does not request notification access.
        NSColor(srgbRed: 0.86, green: 0.12, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(ovalIn: badge).fill()

        let fontScale: CGFloat = label.count > 2 ? 0.40 : 0.55
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: badge.height * fontScale, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = label as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(
            x: badge.midX - textSize.width / 2,
            y: badge.midY - textSize.height / 2
        ), withAttributes: attributes)
    }

    private func updateAccessibilityLabel() {
        setAccessibilityLabel("\(max(0, count)) sessions need attention")
    }
}
