import Foundation
import Testing
@testable import Ghostty

@Suite
struct FlashFileBrowserRevealRequestTests {
    @Test
    func repeatedPathCreatesDistinctRequests() {
        let url = URL(fileURLWithPath: "/tmp/example.swift")
        let workingDirectory = URL(fileURLWithPath: "/tmp")

        let first = FlashFileBrowserRevealRequest(
            lexicalURL: url,
            workingDirectoryURL: workingDirectory
        )
        let second = FlashFileBrowserRevealRequest(
            lexicalURL: url,
            workingDirectoryURL: workingDirectory
        )

        #expect(first.id != second.id)
        #expect(first.lexicalURL == second.lexicalURL)
        #expect(first.workingDirectoryURL == workingDirectory.standardizedFileURL)
    }
}
