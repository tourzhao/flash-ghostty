@testable import Ghostty
import GhosttyKit
import Testing

struct SurfaceViewAppKitTests {
    @Test func sessionMetadataSelectionIsPinnedToTheActiveScreen() {
        let selection = Ghostty.SurfaceView.sessionMetadataTextSelection

        #expect(selection.top_left.tag == GHOSTTY_POINT_ACTIVE)
        #expect(selection.top_left.coord == GHOSTTY_POINT_COORD_TOP_LEFT)
        #expect(selection.bottom_right.tag == GHOSTTY_POINT_ACTIVE)
        #expect(selection.bottom_right.coord == GHOSTTY_POINT_COORD_BOTTOM_RIGHT)
        #expect(!selection.rectangle)
    }

    @MainActor
    @Test func sessionRestorationKeepsTheLastNonEmptyWorkingDirectory() {
        let view = Ghostty.OSSurfaceView(
            id: nil,
            frame: .zero,
            initialWorkingDirectory: "/initial"
        )

        #expect(view.pwd == "/initial")
        #expect(view.lastKnownWorkingDirectory == "/initial")

        view.pwd = "/latest"
        #expect(view.lastKnownWorkingDirectory == "/latest")

        // OSC 7 uses an empty value to reset the current-directory UI. That
        // must not replace the stable directory written to the restore archive.
        view.pwd = ""
        #expect(view.pwd == "")
        #expect(view.lastKnownWorkingDirectory == "/latest")
    }

    @MainActor
    @Test func sessionRestorationDoesNotInventAWorkingDirectory() {
        let view = Ghostty.OSSurfaceView(id: nil, frame: .zero)
        let emptyView = Ghostty.OSSurfaceView(
            id: nil,
            frame: .zero,
            initialWorkingDirectory: ""
        )

        #expect(view.pwd == nil)
        #expect(view.lastKnownWorkingDirectory == nil)
        #expect(emptyView.pwd == nil)
        #expect(emptyView.lastKnownWorkingDirectory == nil)
    }

    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }
}
