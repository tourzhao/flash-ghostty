import Combine
import Foundation

/// A temporary bookmark for an absolute row in a terminal surface's
/// scrollback. These bookmarks intentionally live only for the lifetime of
/// the surface and are not part of session restoration.
struct FlashSurfacePin: Equatable, Identifiable {
    let number: Int
    let row: UInt64
    let contentGeneration: UInt64
    let screenIdentity: UInt64

    init(
        number: Int,
        row: UInt64,
        contentGeneration: UInt64 = 0,
        screenIdentity: UInt64 = 0
    ) {
        self.number = number
        self.row = row
        self.contentGeneration = contentGeneration
        self.screenIdentity = screenIdentity
    }

    var id: Int { number }
}

enum FlashSurfacePinAddResult: Equatable {
    case added(FlashSurfacePin)
    case duplicate(FlashSurfacePin)
    case full
    case unavailable
}

enum FlashSurfaceNavigationAction: Equatable {
    case scrollToBottom
    case scrollToRow(UInt64)

    var bindingAction: String {
        switch self {
        case .scrollToBottom:
            return "scroll_to_bottom"
        case .scrollToRow(let row):
            return "scroll_to_row:\(row)"
        }
    }
}

/// Pure state for the five fixed pin slots exposed by the navigation overlay.
/// Existing pins never change numbers; removing a pin frees the lowest slot
/// for the next bookmark.
struct FlashSurfacePinState: Equatable {
    static let maximumCount = 5

    private(set) var pins: [FlashSurfacePin] = []

    var canAddPin: Bool {
        pins.count < Self.maximumCount
    }

    mutating func add(
        row: UInt64,
        within history: FlashSurfaceHistoryShape
    ) -> FlashSurfacePinAddResult {
        guard history.containsHistoryOffset(row) else { return .unavailable }

        if let existing = pins.first(where: {
            $0.row == row &&
                $0.contentGeneration == history.contentGeneration &&
                $0.screenIdentity == history.screenIdentity
        }) {
            return .duplicate(existing)
        }

        guard canAddPin else { return .full }
        guard let number = (1...Self.maximumCount).first(where: { candidate in
            !pins.contains(where: { $0.number == candidate })
        }) else {
            return .full
        }

        let pin = FlashSurfacePin(
            number: number,
            row: row,
            contentGeneration: history.contentGeneration,
            screenIdentity: history.screenIdentity
        )
        pins.append(pin)
        pins.sort { $0.number < $1.number }
        return .added(pin)
    }

    @discardableResult
    mutating func remove(number: Int) -> Bool {
        guard let index = pins.firstIndex(where: { $0.number == number }) else {
            return false
        }

        pins.remove(at: index)
        return true
    }

    mutating func removeAll() {
        pins.removeAll(keepingCapacity: true)
    }

    func targetRow(
        for number: Int,
        within history: FlashSurfaceHistoryShape
    ) -> UInt64? {
        guard let pin = pins.first(where: { $0.number == number }) else {
            return nil
        }
        guard pin.contentGeneration == history.contentGeneration else {
            return nil
        }
        guard pin.screenIdentity == history.screenIdentity else { return nil }
        guard history.containsHistoryOffset(pin.row) else { return nil }
        return pin.row
    }
}

struct FlashSurfaceGridSize: Equatable {
    let columns: UInt16
    let rows: UInt16
}

struct FlashSurfaceHistoryShape: Equatable {
    let total: UInt64
    let length: UInt64
    let contentGeneration: UInt64
    let screenIdentity: UInt64

    init(
        total: UInt64,
        length: UInt64,
        contentGeneration: UInt64 = 0,
        screenIdentity: UInt64 = 0
    ) {
        self.total = total
        self.length = length
        self.contentGeneration = contentGeneration
        self.screenIdentity = screenIdentity
    }

    var hasScrollableHistory: Bool {
        length > 0 && total > length
    }

    func containsHistoryOffset(_ offset: UInt64) -> Bool {
        guard let bottomOffset else { return false }
        // The viewport at bottomOffset begins in the active screen. Pins are
        // history bookmarks, so that boundary is deliberately excluded.
        return offset < bottomOffset
    }

    var bottomOffset: UInt64? {
        guard length > 0, total >= length else { return nil }
        return total - length
    }

    static func shouldInvalidatePins(
        previous: Self,
        current: Self
    ) -> Bool {
        current.screenIdentity != previous.screenIdentity ||
            current.contentGeneration != previous.contentGeneration ||
            current.length != previous.length ||
            current.total < previous.total
    }
}

/// One coherent terminal-scrollback sample. Presentation and button actions
/// must use the same sample; reading a second observer-owned cache when the
/// user clicks can otherwise target a different viewport than the one shown.
struct FlashSurfaceNavigationSnapshot: Equatable {
    static let empty = Self(
        history: FlashSurfaceHistoryShape(total: 0, length: 0),
        offset: 0
    )

    let history: FlashSurfaceHistoryShape
    let offset: UInt64

    var presentation: FlashSurfaceNavigationPresentation {
        FlashSurfaceNavigationPresentation(
            history: history,
            offset: offset
        )
    }

    func replacingOffset(_ offset: UInt64) -> Self {
        Self(history: history, offset: offset)
    }
}

/// Pure visibility policy shared by the production presentation state and its
/// boundary tests.
enum FlashSurfaceNavigationPolicy {
    static func isScrollToBottomVisible(
        total: UInt64,
        offset: UInt64,
        length: UInt64
    ) -> Bool {
        guard length > 0, total > length else { return false }
        return offset < total - length
    }
}

struct FlashSurfaceNavigationPresentation: Equatable {
    let isScrollToBottomVisible: Bool
    let isPinningAvailable: Bool

    init(history: FlashSurfaceHistoryShape, offset: UInt64) {
        isScrollToBottomVisible =
            FlashSurfaceNavigationPolicy.isScrollToBottomVisible(
                total: history.total,
                offset: offset,
                length: history.length
            )
        isPinningAvailable = history.containsHistoryOffset(offset)
    }
}

/// A reduced scrollbar update consumed by the navigation overlay. Keeping the
/// presentation and pin invalidation decision together lets the overlay use a
/// single notification subscription for its high-frequency scroll updates.
struct FlashSurfaceNavigationUpdate: Equatable {
    let snapshot: FlashSurfaceNavigationSnapshot
    let invalidatesPins: Bool

    var presentation: FlashSurfaceNavigationPresentation {
        snapshot.presentation
    }
}

struct FlashSurfaceNavigationSample: Equatable {
    let history: FlashSurfaceHistoryShape
    let offset: UInt64

    var snapshot: FlashSurfaceNavigationSnapshot {
        FlashSurfaceNavigationSnapshot(history: history, offset: offset)
    }
}

/// Geometry already sampled by the renderer and carried in the stable
/// `ghostty_action_scrollbar_s` application-action payload.
struct FlashSurfaceScrollbarGeometry: Equatable {
    let total: UInt64
    let offset: UInt64
    let length: UInt64

    func sample(
        preservingIdentityFrom cachedHistory: FlashSurfaceHistoryShape
    ) -> FlashSurfaceNavigationSample {
        FlashSurfaceNavigationSample(
            history: FlashSurfaceHistoryShape(
                total: total,
                length: length,
                contentGeneration: cachedHistory.contentGeneration,
                screenIdentity: cachedHistory.screenIdentity
            ),
            offset: offset
        )
    }
}

enum FlashSurfaceHistoryIdentitySource: Equatable {
    /// No Pin exists, so renderer-supplied geometry is sufficient.
    case cached

    /// A coherent core snapshot refreshed the identity for active Pins.
    case authoritative

    /// An active Pin could not be revalidated; consumers must fail closed.
    case unavailable
}

struct FlashSurfaceNavigationResolvedSample: Equatable {
    let sample: FlashSurfaceNavigationSample
    let identitySource: FlashSurfaceHistoryIdentitySource
}

/// Keeps the renderer-locked snapshot API out of the pinless scrolling path.
/// The closure is deliberately lazy so a unit test can guard this performance
/// invariant without relying on timing measurements.
enum FlashSurfaceNavigationSampleResolver {
    static func resolve(
        geometry: FlashSurfaceScrollbarGeometry,
        cachedHistory: FlashSurfaceHistoryShape,
        requiresHistoryIdentity: Bool,
        fetchSnapshot: () -> FlashSurfaceNavigationSnapshot?
    ) -> FlashSurfaceNavigationResolvedSample {
        let geometrySample = geometry.sample(
            preservingIdentityFrom: cachedHistory
        )
        guard requiresHistoryIdentity else {
            return FlashSurfaceNavigationResolvedSample(
                sample: geometrySample,
                identitySource: .cached
            )
        }
        guard let snapshot = fetchSnapshot() else {
            return FlashSurfaceNavigationResolvedSample(
                sample: geometrySample,
                identitySource: .unavailable
            )
        }
        return FlashSurfaceNavigationResolvedSample(
            sample: FlashSurfaceNavigationSample(
                history: snapshot.history,
                offset: snapshot.offset
            ),
            identitySource: .authoritative
        )
    }
}

struct FlashSurfaceNavigationUpdateAccumulator {
    private var previousHistory: FlashSurfaceHistoryShape?

    init(initialHistory: FlashSurfaceHistoryShape?) {
        previousHistory = initialHistory
    }

    mutating func update(
        history: FlashSurfaceHistoryShape,
        offset: UInt64
    ) -> FlashSurfaceNavigationUpdate {
        let invalidatesPins = previousHistory.map { previous in
            FlashSurfaceHistoryShape.shouldInvalidatePins(
                previous: previous,
                current: history
            )
        } ?? false
        previousHistory = history

        return FlashSurfaceNavigationUpdate(
            snapshot: FlashSurfaceNavigationSnapshot(
                history: history,
                offset: offset
            ),
            invalidatesPins: invalidatesPins
        )
    }

    /// Reduce one frame's scrollbar samples to the newest snapshot while
    /// retaining any identity invalidation observed earlier in the frame.
    /// This matters when pruning and subsequent growth are coalesced before
    /// SwiftUI sees either intermediate geometry.
    mutating func coalescing(
        _ samples: [FlashSurfaceNavigationSample]
    ) -> FlashSurfaceNavigationUpdate? {
        var latest: FlashSurfaceNavigationUpdate?
        var invalidatesPins = false

        for sample in samples {
            let update = update(
                history: sample.history,
                offset: sample.offset
            )
            invalidatesPins = invalidatesPins || update.invalidatesPins
            latest = update
        }

        guard let latest else { return nil }
        return FlashSurfaceNavigationUpdate(
            snapshot: latest.snapshot,
            invalidatesPins: invalidatesPins
        )
    }
}

@MainActor
final class FlashSurfaceNavigationModel: ObservableObject {
    typealias FrameDrain = @MainActor @Sendable () -> Void
    typealias FrameScheduler = (@escaping FrameDrain) -> Void

    @Published private(set) var pinState = FlashSurfacePinState()
    @Published private(set) var presentation =
        FlashSurfaceNavigationSnapshot.empty.presentation

    private let scheduleFrame: FrameScheduler
    private var gridSize: FlashSurfaceGridSize?
    private var updateAccumulator = FlashSurfaceNavigationUpdateAccumulator(
        initialHistory: nil
    )
    private var pendingUpdate: FlashSurfaceNavigationUpdate?
    private var isFrameDrainScheduled = false
    private(set) var latestSnapshot = FlashSurfaceNavigationSnapshot.empty

    var pins: [FlashSurfacePin] { pinState.pins }
    var canAddPin: Bool { pinState.canAddPin }

    init(
        scheduleFrame: @escaping FrameScheduler = { drain in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) {
                MainActor.assumeIsolated {
                    drain()
                }
            }
        }
    ) {
        self.scheduleFrame = scheduleFrame
    }

    /// Retain the newest sample and every invalidation seen during a burst,
    /// then publish them together on a single, event-triggered frame drain.
    /// No timer or delayed work exists while there are no scrollbar events.
    func enqueue(_ sample: FlashSurfaceNavigationSample) {
        let update = updateAccumulator.update(
            history: sample.history,
            offset: sample.offset
        )
        pendingUpdate = FlashSurfaceNavigationUpdate(
            snapshot: update.snapshot,
            invalidatesPins:
                pendingUpdate?.invalidatesPins == true || update.invalidatesPins
        )

        guard !isFrameDrainScheduled else { return }
        isFrameDrainScheduled = true
        scheduleFrame { [weak self] in
            self?.drainFrame()
        }
    }

    /// An unavailable identity must discard active Pins immediately. Geometry
    /// remains useful for the down-button and native scrollbar presentation.
    func enqueue(_ resolvedSample: FlashSurfaceNavigationResolvedSample) {
        if resolvedSample.identitySource == .unavailable {
            removeAllPins()
        }
        enqueue(resolvedSample.sample)
    }

    private func drainFrame() {
        isFrameDrainScheduled = false
        guard let update = pendingUpdate else { return }
        pendingUpdate = nil
        apply(update)
    }

    /// Store every scrollbar sample, but publish only presentation changes.
    /// Button actions therefore use the newest offset without making normal
    /// scrolling rebuild the SwiftUI overlay for every row.
    func apply(_ update: FlashSurfaceNavigationUpdate) {
        let snapshotInvalidatedPins = commitSnapshot(update.snapshot)
        updateAccumulator = FlashSurfaceNavigationUpdateAccumulator(
            initialHistory: update.snapshot.history
        )
        if update.invalidatesPins && !snapshotInvalidatedPins {
            removeAllPins()
        }
    }

    @discardableResult
    func setSnapshot(_ snapshot: FlashSurfaceNavigationSnapshot) -> Bool {
        // Direct refreshes and successful button actions are newer authorities
        // than a not-yet-published notification burst. Leave its one-shot
        // callback scheduled, but make that callback a harmless no-op.
        pendingUpdate = nil
        updateAccumulator = FlashSurfaceNavigationUpdateAccumulator(
            initialHistory: snapshot.history
        )
        return commitSnapshot(snapshot)
    }

    @discardableResult
    private func commitSnapshot(
        _ snapshot: FlashSurfaceNavigationSnapshot
    ) -> Bool {
        let invalidatesPins = FlashSurfaceHistoryShape.shouldInvalidatePins(
            previous: latestSnapshot.history,
            current: snapshot.history
        )
        latestSnapshot = snapshot
        if invalidatesPins {
            removeAllPins()
        }
        let nextPresentation = snapshot.presentation
        if presentation != nextPresentation {
            presentation = nextPresentation
        }
        return invalidatesPins
    }

    func updateCurrentOffset(_ offset: UInt64) {
        setSnapshot(latestSnapshot.replacingOffset(offset))
    }

    @discardableResult
    func addPin(
        row: UInt64,
        within history: FlashSurfaceHistoryShape
    ) -> FlashSurfacePinAddResult {
        var nextState = pinState
        let result = nextState.add(row: row, within: history)
        if nextState != pinState {
            pinState = nextState
        }
        return result
    }

    /// Pin creation uses an immediate core snapshot rather than the newest
    /// display-frame sample, which may still be waiting in the coalescer.
    @discardableResult
    func addPin(
        at snapshot: FlashSurfaceNavigationSnapshot
    ) -> FlashSurfacePinAddResult {
        setSnapshot(snapshot)
        return addPin(row: snapshot.offset, within: snapshot.history)
    }

    func removePin(number: Int) {
        var nextState = pinState
        guard nextState.remove(number: number) else { return }
        pinState = nextState
    }

    func removeAllPins() {
        guard !pinState.pins.isEmpty else { return }
        pinState = FlashSurfacePinState()
    }

    func targetRow(
        for number: Int,
        within history: FlashSurfaceHistoryShape? = nil
    ) -> UInt64? {
        pinState.targetRow(
            for: number,
            within: history ?? latestSnapshot.history
        )
    }

    /// Absolute row bookmarks cannot survive terminal reflow. Clear them when
    /// either grid dimension changes instead of silently navigating elsewhere.
    func updateGridSize(_ nextSize: FlashSurfaceGridSize) {
        defer { gridSize = nextSize }
        guard let gridSize, gridSize != nextSize else { return }
        removeAllPins()
    }
}

/// Keeps navigation state alive with its surface while allowing the surface to
/// deallocate normally. This avoids putting FLASH-specific state in mainline's
/// `Ghostty.SurfaceView` and survives SwiftUI split-tree reconstruction.
@MainActor
final class FlashSurfaceNavigationRegistry {
    static let shared = FlashSurfaceNavigationRegistry()

    private let models = NSMapTable<Ghostty.SurfaceView, FlashSurfaceNavigationModel>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    private init() {}

    func model(for surfaceView: Ghostty.SurfaceView) -> FlashSurfaceNavigationModel {
        if let existing = models.object(forKey: surfaceView) {
            return existing
        }

        let model = FlashSurfaceNavigationModel()
        models.setObject(model, forKey: surfaceView)
        return model
    }
}
