import AppKit
import Testing
@testable import Ghostty

@Suite
struct FlashFileBrowserCommandRoutingTests {
    @Test
    func routesFinderShortcutsOnlyWhileListHasFocus() throws {
        let copy = try #require(keyEvent(characters: "c", keyCode: 8))
        let paste = try #require(keyEvent(characters: "v", keyCode: 9))
        let delete = try #require(keyEvent(characters: "\u{7f}", keyCode: 51))

        #expect(command(for: copy) == .copy)
        #expect(command(for: paste) == .paste)
        #expect(command(for: delete) == .moveToTrash)
        #expect(command(for: copy, listHasFocus: false) == nil)
    }

    @Test
    func leavesDisabledAndModifiedShortcutsForOtherResponders() throws {
        let copy = try #require(keyEvent(characters: "c", keyCode: 8))
        let paste = try #require(keyEvent(characters: "v", keyCode: 9))
        let shiftedCopy = try #require(
            keyEvent(
                characters: "C",
                keyCode: 8,
                modifiers: [.command, .shift]
            )
        )

        #expect(command(for: copy, canCopy: false) == nil)
        #expect(command(for: paste, canPaste: false) == nil)
        #expect(command(for: shiftedCopy) == nil)
    }

    @Test
    func monitorsOnlyTheSelectedSessionInTheKeyWindow() throws {
        let copy = try #require(keyEvent(characters: "c", keyCode: 8))

        #expect(FlashFileBrowserCommandRouting.shouldMonitorEvents(
            sessionIsSelected: true,
            windowIsKey: true
        ))
        #expect(!FlashFileBrowserCommandRouting.shouldMonitorEvents(
            sessionIsSelected: false,
            windowIsKey: true
        ))
        #expect(!FlashFileBrowserCommandRouting.shouldMonitorEvents(
            sessionIsSelected: true,
            windowIsKey: false
        ))
        #expect(command(for: copy, sessionIsSelected: false) == nil)
        #expect(command(for: copy, windowIsKey: false) == nil)
    }

    private func command(
        for event: NSEvent,
        sessionIsSelected: Bool = true,
        windowIsKey: Bool = true,
        listHasFocus: Bool = true,
        canCopy: Bool = true,
        canPaste: Bool = true,
        canMoveToTrash: Bool = true
    ) -> FlashFileBrowserCommand? {
        FlashFileBrowserCommandRouting.command(
            for: event,
            sessionIsSelected: sessionIsSelected,
            windowIsKey: windowIsKey,
            listHasFocus: listHasFocus,
            canCopy: canCopy,
            canPaste: canPaste,
            canMoveToTrash: canMoveToTrash
        )
    }

    private func keyEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
