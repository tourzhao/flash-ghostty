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

    @Test @MainActor func pasteboardItemProvidesCorrectData() throws {
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

        // Reading lazy pasteboard data is synchronous and can wait for an
        // asynchronous CoreTransferable completion. Keep that wait on AppKit's
        // main thread instead of a cooperative Swift executor worker.
        let providedData = pasteboard.data(forType: pasteboardType)
        let data = try #require(
            providedData,
            "Expected data to be available on pasteboard"
        )

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

    @Test @MainActor func multipleTypesProvideCorrectData() throws {
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

        let providedData = TransferablePasteboardProvidedData(
            first: pasteboard.data(forType: utf8Type),
            second: pasteboard.data(forType: plainType)
        )
        let utf8Data = try #require(
            providedData.first,
            "Expected UTF-8 pasteboard data"
        )
        let plainData = try #require(
            providedData.second,
            "Expected plain-text pasteboard data"
        )

        #expect(String(data: utf8Data, encoding: .utf8) == "shared content")
        #expect(String(data: plainData, encoding: .utf8) == "shared content")
    }

    @Test func multipleCompletionsCanReturnAsynchronouslyOnTheLoadingQueue() async throws {
        let loadingQueue = DispatchQueue(
            label: "com.mitchellh.ghostty.tests.transferable-data-provider",
            qos: .userInitiated
        )
        let loadingQueueKey = DispatchSpecificKey<Void>()
        loadingQueue.setSpecific(key: loadingQueueKey, value: ())
        let loadingQueueProbe = TransferablePasteboardQueueProbe()

        let dataType = NSPasteboard.PasteboardType(UTType.data.identifier)
        let textType = NSPasteboard.PasteboardType(UTType.plainText.identifier)
        let expectedData = [
            dataType.rawValue: Data("deferred data".utf8),
            textType.rawValue: Data("deferred text".utf8),
        ]
        let provider = TransferableDataProvider(loadingQueue: loadingQueue) { type, completion in
            loadingQueueProbe.record(
                DispatchQueue.getSpecific(key: loadingQueueKey) != nil
            )

            // CoreTransferable may deliver asynchronously on the executor that
            // initiated the load. The loading queue must be free before the
            // synchronous pasteboard callback starts waiting for this block.
            let deferredCompletion = TransferablePasteboardDataCompletion(
                completion
            )
            loadingQueue.async {
                deferredCompletion(expectedData[type])
            }
        }
        let item = NSPasteboardItem()
        let providedData = try await runTransferablePasteboardInvocation(
            TransferablePasteboardInvocation {
                provider.pasteboard(
                    nil,
                    item: item,
                    provideDataForType: dataType
                )
                provider.pasteboard(
                    nil,
                    item: item,
                    provideDataForType: textType
                )
                return TransferablePasteboardProvidedData(
                    first: item.data(forType: dataType),
                    second: item.data(forType: textType)
                )
            }
        )

        #expect(loadingQueueProbe.observations == [true, true])
        #expect(providedData.first == expectedData[dataType.rawValue])
        #expect(providedData.second == expectedData[textType.rawValue])
    }
}

private final class TransferablePasteboardInvocation<Value: Sendable>:
    @unchecked Sendable {
    private let body: () -> Value

    init(_ body: @escaping () -> Value) {
        self.body = body
    }

    func run() -> Value {
        body()
    }
}

private struct TransferablePasteboardProvidedData: Sendable {
    let first: Data?
    let second: Data?
}

private final class TransferablePasteboardDataCompletion:
    @unchecked Sendable {
    private let body: (Data?) -> Void

    init(_ body: @escaping (Data?) -> Void) {
        self.body = body
    }

    func callAsFunction(_ data: Data?) {
        body(data)
    }
}

private final class TransferablePasteboardQueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedObservations: [Bool] = []

    func record(_ observation: Bool) {
        lock.withLock {
            recordedObservations.append(observation)
        }
    }

    var observations: [Bool] {
        lock.withLock { recordedObservations }
    }
}

private enum TransferablePasteboardThreadOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

private struct TransferablePasteboardTimeoutError: Error {}

private final class TransferablePasteboardCompletion<Value: Sendable>:
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        TransferablePasteboardThreadOutcome<Value>,
        Never
    >?

    init(
        _ continuation: CheckedContinuation<
            TransferablePasteboardThreadOutcome<Value>,
            Never
        >
    ) {
        self.continuation = continuation
    }

    func resume(
        returning result: TransferablePasteboardThreadOutcome<Value>
    ) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

private func runTransferablePasteboardInvocation<Value: Sendable>(
    _ invocation: TransferablePasteboardInvocation<Value>
) async throws -> Value {
    let outcome: TransferablePasteboardThreadOutcome<Value> =
        await withCheckedContinuation { continuation in
            let completion = TransferablePasteboardCompletion(continuation)
            let thread = Thread {
                let value = autoreleasepool {
                    invocation.run()
                }
                completion.resume(returning: .value(value))
            }
            thread.name = "TransferablePasteboardTests.Invocation"
            thread.qualityOfService = .userInitiated
            thread.start()

            DispatchQueue(
                label: "com.mitchellh.ghostty.tests.transferable-timeout",
                qos: .userInitiated
            ).asyncAfter(deadline: .now() + 10) {
                completion.resume(returning: .timedOut)
            }
        }

    switch outcome {
    case let .value(value):
        return value
    case .timedOut:
        throw TransferablePasteboardTimeoutError()
    }
}
