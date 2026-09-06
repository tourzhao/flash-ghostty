import Testing
@testable import Ghostty

struct SessionAttentionSidebarTests {
    @Test func sessionsWithoutAttentionHaveNoProminentLabel() {
        #expect(TerminalSessionAttentionPresentation(summary: .init()) == nil)
    }

    @Test func unreadCompletionHasAnExplicitTextAndIconCue() throws {
        let presentation = try #require(TerminalSessionAttentionPresentation(
            summary: .init(hasUnreadCompletion: true)
        ))
        #expect(presentation == .unreadCompletion)
        #expect(presentation.label == "Unread")
        #expect(presentation.systemImage == "checkmark.circle.fill")
        #expect(presentation.accessibilityDescription.contains("completed pane"))
    }

    @Test(arguments: [false, true])
    func inputTakesPriorityWithoutDependingOnCompletion(hasUnreadCompletion: Bool) throws {
        let presentation = try #require(TerminalSessionAttentionPresentation(
            summary: .init(hasUnreadCompletion: hasUnreadCompletion, needsInput: true)
        ))
        #expect(presentation == .needsInput)
        #expect(presentation.label == "Needs input")
        #expect(presentation.systemImage == "exclamationmark.circle.fill")
        #expect(presentation.accessibilityDescription.contains("does not clear"))
    }
}
