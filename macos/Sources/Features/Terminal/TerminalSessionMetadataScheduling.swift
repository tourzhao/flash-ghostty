import Combine
import Foundation

enum SessionMetadataPollingMode: Equatable, Sendable {
    case selected
    case background
    case suspended

    static func resolve(
        sidebarIsVisible: Bool,
        sessionIsSelected: Bool
    ) -> Self {
        guard sidebarIsVisible else { return .suspended }
        return sessionIsSelected ? .selected : .background
    }

    var allowsVisibleContentsReads: Bool {
        self != .suspended
    }
}

/// Keeps the selected row responsive while reducing polling for rows whose
/// event-driven title/progress updates remain active in the background.
struct SessionMetadataRefreshThrottle {
    static let backgroundIntervalTicks: UInt = 3

    private(set) var mode: SessionMetadataPollingMode
    private var ticksSinceRefresh: UInt = 0

    init(mode: SessionMetadataPollingMode = .selected) {
        self.mode = mode
    }

    /// Returns true when a newly important session should refresh immediately.
    mutating func update(mode nextMode: SessionMetadataPollingMode) -> Bool {
        guard mode != nextMode else { return false }

        let previousMode = mode
        mode = nextMode
        ticksSinceRefresh = 0
        return nextMode != .suspended &&
            (previousMode == .suspended || nextMode == .selected)
    }

    mutating func consumeTick() -> Bool {
        switch mode {
        case .selected:
            return true
        case .suspended:
            return false
        case .background:
            ticksSinceRefresh += 1
            guard ticksSinceRefresh >= Self.backgroundIntervalTicks else {
                return false
            }
            ticksSinceRefresh = 0
            return true
        }
    }
}

struct SessionProcessLookupRequest: Equatable, Sendable {
    enum ResultDisposition: Equatable, Sendable {
        case discard
        case accept
        case retryCurrentProcess
    }

    let generation: UInt
    let surfaceID: UUID
    let processID: Int32

    func matchesBinding(generation: UInt, surfaceID: UUID?) -> Bool {
        self.generation == generation && self.surfaceID == surfaceID
    }

    func matchesProcess(_ processID: Int32?) -> Bool {
        self.processID == processID
    }

    func disposition(
        currentGeneration: UInt,
        currentSurfaceID: UUID?,
        currentProcessID: Int32?
    ) -> ResultDisposition {
        guard matchesBinding(
            generation: currentGeneration,
            surfaceID: currentSurfaceID
        ) else { return .discard }
        guard matchesProcess(currentProcessID) else {
            return .retryCurrentProcess
        }
        return .accept
    }
}

/// Process ancestry is substantially more expensive than reading the foreground
/// PID that Ghostty already publishes. A stable PID/name pair needs only an
/// occasional revalidation; a PID change or failed lookup remains immediately
/// eligible so provider transitions and transient `proc_*` failures stay prompt.
struct SessionProcessLookupThrottle {
    static let stableInterval: TimeInterval = 3

    private var lastAcceptedProcessID: Int32?
    private var lastAcceptedUptime: TimeInterval?

    func shouldLookup(processID: Int32, now: TimeInterval) -> Bool {
        guard lastAcceptedProcessID == processID,
              let lastAcceptedUptime else { return true }
        return now - lastAcceptedUptime >= Self.stableInterval
    }

    mutating func accept(processID: Int32, now: TimeInterval) {
        lastAcceptedProcessID = processID
        lastAcceptedUptime = now
    }

    mutating func reset() {
        lastAcceptedProcessID = nil
        lastAcceptedUptime = nil
    }
}

struct SessionInstructionStore {
    static let capacity = 32

    private struct Key: Hashable {
        let surfaceID: UUID
        let tool: TerminalSessionTool
    }

    private var values: [Key: String] = [:]
    private var keysByRecency: [Key] = []

    var count: Int { values.count }

    mutating func store(
        _ instruction: String,
        surfaceID: UUID,
        tool: TerminalSessionTool
    ) {
        guard tool != .terminal else { return }
        let key = Key(surfaceID: surfaceID, tool: tool)
        if let existingIndex = keysByRecency.firstIndex(of: key) {
            keysByRecency.remove(at: existingIndex)
        }
        keysByRecency.append(key)
        values[key] = instruction

        if keysByRecency.count > Self.capacity {
            let evicted = keysByRecency.removeFirst()
            values.removeValue(forKey: evicted)
        }
    }

    func instruction(
        surfaceID: UUID,
        tool: TerminalSessionTool
    ) -> String? {
        values[Key(surfaceID: surfaceID, tool: tool)]
    }
}

/// One app-wide clock refreshes weakly held session monitors. This avoids a
/// separate run-loop timer for every native tab. The selected row refreshes
/// every second, background rows apply their own throttling, and the clock is
/// stopped entirely while every registered sidebar is hidden.
@MainActor
final class TerminalSessionMetadataRefreshScheduler {
    static let shared = TerminalSessionMetadataRefreshScheduler()

    private let monitors = NSHashTable<TerminalSessionMetadataMonitor>.weakObjects()
    private var timer: AnyCancellable?

    private init() {}

    private func startTimerIfNeeded() {
        guard timer == nil else { return }

        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshRegisteredMonitors()
            }
    }

    private func updateTimerState() {
        if monitors.allObjects.contains(where: \.requiresPeriodicRefresh) {
            startTimerIfNeeded()
        } else {
            timer?.cancel()
            timer = nil
        }
    }

    func register(_ monitor: TerminalSessionMetadataMonitor) {
        monitors.add(monitor)
        updateTimerState()
        monitor.refreshWhenRegistered()
    }

    func unregister(_ monitor: TerminalSessionMetadataMonitor) {
        monitors.remove(monitor)
        updateTimerState()
    }

    /// Visibility can change while the monitor remains registered. Stop the
    /// app-wide clock when every sidebar is hidden, and restart it as soon as
    /// any monitor becomes visible again.
    func refreshContextDidChange() {
        updateTimerState()
    }

    private func refreshRegisteredMonitors() {
        let registeredMonitors = monitors.allObjects
        guard !registeredMonitors.isEmpty else {
            stopTimerIfIdle()
            return
        }

        registeredMonitors.forEach { $0.refreshPeriodically() }
    }

    private func stopTimerIfIdle() {
        guard monitors.allObjects.isEmpty else { return }
        timer?.cancel()
        timer = nil
    }
}
