import Foundation

/// A transient request to reveal one terminal-linked filesystem entry in the
/// file browser belonging to the same session.
///
/// The UUID intentionally changes for every click so selecting the same path
/// twice still produces a new navigation request.
struct FlashFileBrowserRevealRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let lexicalURL: URL
    let workingDirectoryURL: URL?

    init(
        id: UUID = UUID(),
        lexicalURL: URL,
        workingDirectoryURL: URL? = nil
    ) {
        self.id = id
        self.lexicalURL = lexicalURL.standardizedFileURL
        self.workingDirectoryURL = workingDirectoryURL?.standardizedFileURL
    }
}
