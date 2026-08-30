import Testing
import AppKit
import CoreTransferable
import UniformTypeIdentifiers
@testable import Ghostty

struct TransferablePasteboardTests {
    // MARK: - Test Helpers

    /// A simple Transferable type for testing pasteboard conversion.
    private struct DummyTransferable: Transferable, Equatable {
        let payload: String

        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(contentType: .utf8PlainText) { value in
                value.payload.data(using: .utf8)!
            } importing: { data in
                let string = String(data: data, encoding: .utf8)!
                return DummyTransferable(payload: string)
            }
        }
    }

    /// A Transferable type that registers multiple content types.
    private struct MultiTypeTransferable: Transferable {
        let text: String

        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(contentType: .utf8PlainText) { value in
                value.text.data(using: .utf8)!
            } importing: { data in
                MultiTypeTransferable(text: String(data: data, encoding: .utf8)!)
            }
            DataRepresentation(contentType: .plainText) { value in
                value.text.data(using: .utf8)!
            } importing: { data in
                MultiTypeTransferable(text: String(data: data, encoding: .utf8)!)
            }
        }
    }

    // MARK: - Basic Functionality

    @Test func pasteboardItemIsCreated() {
        let transferable = DummyTransferable(payload: "hello")
        let item = transferable.pasteboardItem()
        #expect(item != nil)
    }

    @Test func pasteboardItemContainsExpectedType() {
        let transferable = DummyTransferable(payload: "hello")
        guard let item = transferable.pasteboardItem() else {
            Issue.record("Expected pasteboard item to be created")
            return
        }

        let expectedType = NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)
        #expect(item.types.contains(expectedType))
    }

    @Test func pasteboardItemProvidesCorrectData() {
        let transferable = DummyTransferable(payload: "test data")
        guard let item = transferable.pasteboardItem() else {
            Issue.record("Expected pasteboard item to be created")
            return
        }

        let pasteboardType = NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)

        // Write to a pasteboard to trigger data provider
        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        // Read back the data
        guard let data = pasteboard.data(forType: pasteboardType) else {
            Issue.record("Expected data to be available on pasteboard")
            return
        }

        let string = String(data: data, encoding: .utf8)
        #expect(string == "test data")
    }

    // MARK: - Multiple Content Types

    @Test func multipleTypesAreRegistered() {
        let transferable = MultiTypeTransferable(text: "multi")
        guard let item = transferable.pasteboardItem() else {
            Issue.record("Expected pasteboard item to be created")
            return
        }

        let utf8Type = NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)
        let plainType = NSPasteboard.PasteboardType(UTType.plainText.identifier)

        #expect(item.types.contains(utf8Type))
        #expect(item.types.contains(plainType))
    }

    @Test func multipleTypesProvideCorrectData() {
        let transferable = MultiTypeTransferable(text: "shared content")
        guard let item = transferable.pasteboardItem() else {
            Issue.record("Expected pasteboard item to be created")
            return
        }

        let pasteboard = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        // Both types should provide the same content
        let utf8Type = NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)
        let plainType = NSPasteboard.PasteboardType(UTType.plainText.identifier)

        if let utf8Data = pasteboard.data(forType: utf8Type) {
            #expect(String(data: utf8Data, encoding: .utf8) == "shared content")
        }

        if let plainData = pasteboard.data(forType: plainType) {
            #expect(String(data: plainData, encoding: .utf8) == "shared content")
        }
    }

    @Test func multipleCompletionsCanReturnAsynchronouslyOnTheLoadingQueue() {
        let loadingQueue = DispatchQueue(
            label: "com.mitchellh.ghostty.tests.transferable-data-provider"
        )
        let loadingQueueKey = DispatchSpecificKey<Void>()
        loadingQueue.setSpecific(key: loadingQueueKey, value: ())

        let dataType = NSPasteboard.PasteboardType(UTType.data.identifier)
        let textType = NSPasteboard.PasteboardType(UTType.plainText.identifier)
        let expectedData = [
            dataType.rawValue: Data("deferred data".utf8),
            textType.rawValue: Data("deferred text".utf8),
        ]
        let provider = TransferableDataProvider(loadingQueue: loadingQueue) { type, completion in
            #expect(DispatchQueue.getSpecific(key: loadingQueueKey) != nil)

            // CoreTransferable may deliver asynchronously on the executor that
            // initiated the load. The loading queue must be free before the
            // synchronous pasteboard callback starts waiting for this block.
            loadingQueue.async {
                completion(expectedData[type])
            }
        }
        let item = NSPasteboardItem()
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            provider.pasteboard(nil, item: item, provideDataForType: dataType)
            provider.pasteboard(nil, item: item, provideDataForType: textType)
            finished.signal()
        }

        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(item.data(forType: dataType) == expectedData[dataType.rawValue])
        #expect(item.data(forType: textType) == expectedData[textType.rawValue])
    }
}
