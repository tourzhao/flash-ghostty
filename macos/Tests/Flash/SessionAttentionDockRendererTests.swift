import AppKit
import Testing
@testable import Ghostty

@Suite @MainActor
struct SessionAttentionDockRendererTests {
    @Test(arguments: [Int.min, -1, 0])
    func nonpositiveCountsHaveNoBadge(count: Int) {
        #expect(SessionAttentionDockBadge.label(for: count) == nil)
    }

    @Test(arguments: [1, 9, 10, 99, 100, Int.max])
    func positiveCountsUseBoundedLabels(count: Int) {
        #expect(SessionAttentionDockBadge.label(for: count) == (count > 99 ? "99+" : String(count)))
    }

    @Test(arguments: [16.0, 32.0, 64.0, 128.0, 256.0])
    func badgeIsRoundAndRemainsInsideUpperLeftCorner(size: Double) {
        let bounds = NSRect(x: 7, y: 11, width: size, height: size)
        let badge = SessionAttentionDockBadge.frame(in: bounds)

        #expect(badge.width == badge.height)
        #expect(bounds.contains(badge))
        #expect(badge.maxX < bounds.midX)
        #expect(badge.minY > bounds.midY)
    }

    @Test
    func accessibilityDescribesInitialAndUpdatedAttentionCounts() {
        let view = SessionAttentionDockView(
            frame: NSRect(x: 0, y: 0, width: 128, height: 128),
            icon: nil,
            count: 1
        )
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .image)
        #expect(view.accessibilityLabel() == "1 sessions need attention")

        view.count = 100
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .image)
        #expect(view.accessibilityLabel() == "100 sessions need attention")

        view.count = 0
        #expect(view.accessibilityLabel() == "0 sessions need attention")
        view.count = -1
        #expect(view.accessibilityLabel() == "0 sessions need attention")
    }

    @Test
    func installsTransientViewAndRestoresDefaultWithoutTouchingBellBadge() throws {
        let tile = RecordingDockTile()
        let icon = NSImage(size: NSSize(width: 128, height: 128))
        let renderer = SessionAttentionDockRenderer(dockTile: tile, iconProvider: { icon })

        renderer.update(count: 0)
        #expect(tile.contentView == nil)
        #expect(tile.displayCount == 0)

        renderer.update(count: 3)
        let view = try #require(tile.contentView as? SessionAttentionDockView)
        #expect(view.count == 3)
        #expect(view.icon === icon)
        #expect(view.autoresizingMask.contains([.width, .height]))
        #expect(tile.badgeLabel == "7")

        renderer.update(count: 3)
        #expect(tile.displayCount == 1)

        renderer.update(count: 0)
        #expect(tile.contentView == nil)
        #expect(tile.badgeLabel == "7")
        #expect(tile.displayCount == 2)

        renderer.stop()
        #expect(tile.displayCount == 2)
    }

    @Test
    func stopRestoresPreviouslyInstalledContentView() {
        let previous = NSView()
        let tile = RecordingDockTile()
        tile.contentView = previous
        let renderer = SessionAttentionDockRenderer(dockTile: tile, iconProvider: { nil })

        renderer.update(count: 1)
        #expect(tile.contentView !== previous)
        renderer.stop()
        #expect(tile.contentView === previous)
    }

    @Test
    func clearingOrRefreshingDoesNotOverwriteAnotherOwnersView() {
        let tile = RecordingDockTile()
        var iconRequests = 0
        let renderer = SessionAttentionDockRenderer(dockTile: tile, iconProvider: {
            iconRequests += 1
            return nil
        })
        renderer.update(count: 1)
        let replacement = NSView()
        tile.contentView = replacement

        renderer.refreshIcon()
        renderer.stop()

        #expect(tile.contentView === replacement)
        #expect(tile.displayCount == 1)
        #expect(iconRequests == 1)
    }

    @Test
    func reacquiringTheTileRestoresItsMostRecentOwner() {
        let tile = RecordingDockTile()
        let renderer = SessionAttentionDockRenderer(dockTile: tile, iconProvider: { nil })
        renderer.update(count: 1)
        let replacement = NSView()
        tile.contentView = replacement

        renderer.update(count: 2)
        renderer.stop()

        #expect(tile.contentView === replacement)
    }

    @Test
    func refreshingIconPreservesCountAndDoesNotReviveStoppedBadge() throws {
        let tile = RecordingDockTile()
        var icon = NSImage(size: NSSize(width: 128, height: 128))
        var iconRequests = 0
        let renderer = SessionAttentionDockRenderer(dockTile: tile, iconProvider: {
            iconRequests += 1
            return icon
        })
        renderer.update(count: 2)
        let view = try #require(tile.contentView as? SessionAttentionDockView)
        let firstIcon = view.icon
        icon = NSImage(size: NSSize(width: 128, height: 128))

        renderer.refreshIcon()

        #expect(view.icon === icon)
        #expect(view.icon !== firstIcon)
        #expect(view.count == 2)
        #expect(tile.badgeLabel == "7")
        #expect(tile.displayCount == 2)

        renderer.stop()
        renderer.refreshIcon()
        #expect(tile.contentView == nil)
        #expect(iconRequests == 2)
    }

    @Test(arguments: [1, 12, 100])
    func rendersRedCircleAndWhiteTextWithoutChangingRestOfIcon(count: Int) throws {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size, flipped: false) { bounds in
            NSColor.blue.setFill()
            bounds.fill()
            return true
        }
        let view = SessionAttentionDockView(
            frame: NSRect(origin: .zero, size: size),
            icon: image,
            count: count
        )
        let bitmap = try render(view)
        var redPixels = 0
        var whitePixels = 0
        var otherChangedPixels = 0

        // NSBitmapImageRep rows start at the top. All changed pixels must be
        // inside the upper-left quadrant; the remaining icon stays blue.
        for y in 0..<128 {
            for x in 0..<128 {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let isBlue = color.blueComponent > 0.95 && color.redComponent < 0.05
                if x >= 64 || y >= 64 {
                    if !isBlue { otherChangedPixels += 1 }
                } else if color.redComponent > 0.7 && color.greenComponent < 0.3 {
                    redPixels += 1
                } else if color.redComponent > 0.95 && color.greenComponent > 0.95 && color.blueComponent > 0.95 {
                    whitePixels += 1
                }
            }
        }

        #expect(redPixels > 500)
        #expect(whitePixels > 10)
        #expect(otherChangedPixels == 0)
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        view.draw(view.bounds)
        context.flushGraphics()
        return bitmap
    }

    private final class RecordingDockTile: SessionAttentionDockTile {
        let size = NSSize(width: 128, height: 128)
        var contentView: NSView?
        var badgeLabel: String? = "7"
        private(set) var displayCount = 0

        func display() {
            displayCount += 1
        }
    }
}
