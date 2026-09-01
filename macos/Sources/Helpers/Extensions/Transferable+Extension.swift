import AppKit
import CoreTransferable
import UniformTypeIdentifiers

extension Transferable {
    /// Converts this Transferable to an NSPasteboardItem with lazy data loading.
    /// Data is only fetched when the pasteboard consumer requests it. This allows
    /// bridging a Transferable to NSDraggingSource.
    func pasteboardItem() -> NSPasteboardItem? {
        let itemProvider = NSItemProvider()
        itemProvider.register(self)

        let types = itemProvider.registeredTypeIdentifiers.compactMap { UTType($0) }
        guard !types.isEmpty else { return nil }

        let item = NSPasteboardItem()
        let dataProvider = TransferableDataProvider(itemProvider: itemProvider)
        let pasteboardTypes = types.map { NSPasteboard.PasteboardType($0.identifier) }
        item.setDataProvider(dataProvider, forTypes: pasteboardTypes)

        return item
    }
}

final class TransferableDataProvider: NSObject, NSPasteboardItemDataProvider {
    typealias DataLoader = (
        _ typeIdentifier: String,
        _ completion: @escaping (Data?) -> Void
    ) -> Void

    private let loadingQueue: DispatchQueue
    private let loadData: DataLoader

    init(itemProvider: NSItemProvider) {
        self.loadingQueue = DispatchQueue(
            label: "com.mitchellh.ghostty.transferable-data-provider",
            qos: .userInitiated
        )
        self.loadData = { typeIdentifier, completion in
            itemProvider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                completion(data)
            }
        }
        super.init()
    }

    init(loadingQueue: DispatchQueue, loadData: @escaping DataLoader) {
        self.loadingQueue = loadingQueue
        self.loadData = loadData
        super.init()
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        // NSPasteboardItemDataProvider requires synchronous fulfillment while
        // NSItemProvider loads asynchronously. Starting the load from this
        // callback and then blocking it can deadlock when CoreTransferable
        // schedules its work or completion on the same executor. Start each
        // load on a dedicated serial queue instead. The queue is free again as
        // soon as loadDataRepresentation returns, so a completion delivered to
        // that queue can always run while this callback waits.
        let result = TransferableDataLoadResult()
        let loadData = self.loadData
        loadingQueue.async {
            loadData(type.rawValue) { data in
                result.complete(with: data)
            }
        }

        if let data = result.wait() {
            item.setData(data, forType: type)
        }
    }
}

private final class TransferableDataLoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var data: Data?

    func complete(with data: Data?) {
        lock.withLock {
            self.data = data
        }
        completed.signal()
    }

    func wait() -> Data? {
        completed.wait()
        return lock.withLock { data }
    }
}
