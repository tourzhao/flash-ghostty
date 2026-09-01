import Combine
import Foundation

/// Narrow, session-owned state consumed by the file-browser sidebar.
///
/// Keeping this separate from `TerminalController` prevents terminal title,
/// process, and activity updates from invalidating a potentially large file
/// list. It also gives reveal requests an explicit directory lifecycle: a
/// reveal keeps its originating working directory until a later terminal CWD
/// update, even if split focus changed before the menu action completed.
@MainActor
final class FlashFileBrowserSessionState: ObservableObject {
    let sessionID: SessionWorkspace.SessionID

    @Published private(set) var workingDirectoryURL: URL?
    @Published private(set) var revealRequest: FlashFileBrowserRevealRequest?
    @Published private(set) var selectedFileTypes: Set<FlashFileBrowserFileType>
    @Published private(set) var isSelectedSession: Bool

    private var terminalWorkingDirectoryURL: URL?

    init(
        sessionID: SessionWorkspace.SessionID,
        workingDirectoryURL: URL? = nil,
        selectedFileTypes: Set<FlashFileBrowserFileType> = [],
        isSelectedSession: Bool = true
    ) {
        self.sessionID = sessionID
        self.terminalWorkingDirectoryURL = Self.normalized(workingDirectoryURL)
        self.workingDirectoryURL = Self.normalized(workingDirectoryURL)
        self.selectedFileTypes = selectedFileTypes
        self.isSelectedSession = isSelectedSession
    }

    func synchronizeTerminalWorkingDirectory(_ directory: URL?) {
        let directory = Self.normalized(directory)
        guard terminalWorkingDirectoryURL != directory else { return }
        terminalWorkingDirectoryURL = directory

        // A reveal explicitly owns the browser directory until it is handled.
        // Once acknowledged, the revealed directory remains stable until a
        // genuinely newer terminal CWD/focus update arrives.
        guard revealRequest == nil else { return }
        workingDirectoryURL = directory
    }

    func synchronizeSelection(_ isSelected: Bool) {
        guard isSelectedSession != isSelected else { return }
        isSelectedSession = isSelected
    }

    func synchronizeSelectedFileTypes(
        _ selectedTypes: Set<FlashFileBrowserFileType>
    ) -> Bool {
        guard selectedFileTypes != selectedTypes else { return false }
        selectedFileTypes = selectedTypes
        return true
    }

    func requestReveal(
        _ lexicalURL: URL,
        workingDirectoryURL: URL?
    ) {
        let request = FlashFileBrowserRevealRequest(
            lexicalURL: lexicalURL,
            workingDirectoryURL: workingDirectoryURL
        )
        revealRequest = request
        self.workingDirectoryURL = request.workingDirectoryURL
            ?? terminalWorkingDirectoryURL
    }

    func acknowledgeRevealRequest(_ requestID: UUID) {
        guard revealRequest?.id == requestID else { return }
        revealRequest = nil
    }

    private static func normalized(_ directory: URL?) -> URL? {
        directory.map(FlashFileBrowserPathPolicy.standardized)
    }
}
