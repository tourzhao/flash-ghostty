import Foundation
import Testing
@testable import Ghostty

@Suite @MainActor
struct FlashFileBrowserSessionStateTests {
    @Test
    func revealKeepsOriginatingDirectoryAcrossEarlierSplitFocusChange() throws {
        let state = FlashFileBrowserSessionState(
            sessionID: .init(),
            workingDirectoryURL: directory("A")
        )

        // Split B focused before the asynchronous menu action from A finishes.
        state.synchronizeTerminalWorkingDirectory(directory("B"))
        state.requestReveal(
            directory("A").appendingPathComponent("target.swift"),
            workingDirectoryURL: directory("A")
        )
        let request = try #require(state.revealRequest)
        #expect(state.workingDirectoryURL == normalizedDirectory("A"))

        state.acknowledgeRevealRequest(request.id)
        #expect(state.revealRequest == nil)
        #expect(state.workingDirectoryURL == normalizedDirectory("A"))

        // Only a genuinely later terminal update may take ownership again.
        state.synchronizeTerminalWorkingDirectory(directory("C"))
        #expect(state.workingDirectoryURL == normalizedDirectory("C"))
    }

    @Test
    func revealNeverMutatesPersistentTypeSelection() throws {
        let swift = FlashFileBrowserFileType(fileExtension: "swift")
        let state = FlashFileBrowserSessionState(
            sessionID: .init(),
            workingDirectoryURL: directory("A"),
            selectedFileTypes: [swift]
        )

        state.requestReveal(
            directory("A").appendingPathComponent("README"),
            workingDirectoryURL: directory("A")
        )
        let request = try #require(state.revealRequest)
        state.acknowledgeRevealRequest(request.id)

        #expect(state.selectedFileTypes == [swift])
    }

    @Test
    func staleAcknowledgementCannotConsumeNewerRequest() throws {
        let state = FlashFileBrowserSessionState(sessionID: .init())
        state.requestReveal(directory("A"), workingDirectoryURL: directory("A"))
        let firstID = try #require(state.revealRequest?.id)
        state.requestReveal(directory("B"), workingDirectoryURL: directory("B"))
        let secondID = try #require(state.revealRequest?.id)

        state.acknowledgeRevealRequest(firstID)
        #expect(state.revealRequest?.id == secondID)
    }

    private func directory(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/FlashFileBrowserSessionStateTests/\(name)")
    }

    private func normalizedDirectory(_ name: String) -> URL {
        FlashFileBrowserPathPolicy.standardized(directory(name))
    }
}
