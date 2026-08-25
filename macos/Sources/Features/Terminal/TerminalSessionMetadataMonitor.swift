import Combine
import Foundation
import GhosttyKit

/// One app-wide clock refreshes weakly held session monitors. This avoids a
/// separate run-loop timer for every native tab while preserving one-second
/// prompt/activity responsiveness.
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

    func register(_ monitor: TerminalSessionMetadataMonitor) {
        monitors.add(monitor)
        startTimerIfNeeded()
        monitor.refresh()
    }

    func unregister(_ monitor: TerminalSessionMetadataMonitor) {
        monitors.remove(monitor)
        stopTimerIfIdle()
    }

    private func refreshRegisteredMonitors() {
        let registeredMonitors = monitors.allObjects
        guard !registeredMonitors.isEmpty else {
            stopTimerIfIdle()
            return
        }

        registeredMonitors.forEach { $0.refresh() }
    }

    private func stopTimerIfIdle() {
        guard monitors.allObjects.isEmpty else { return }
        timer?.cancel()
        timer = nil
    }
}

/// Owns the live metadata for one terminal session independently of window and
/// sidebar presentation. AppKit controllers bind a logical surface and relay
/// title changes; provider detection and process discovery stay in this model.
@MainActor
final class TerminalSessionMetadataMonitor: ObservableObject {
    @Published private(set) var dynamicTitle = ""
    @Published private(set) var foregroundProcessName: String?
    @Published private(set) var tool: TerminalSessionTool = .terminal
    @Published private(set) var activityStatus: TerminalSessionActivityStatus = .ready
    @Published private(set) var lastInstruction: String?
    @Published private(set) var workingDirectory: URL?

    private static let processLookupQueue = DispatchQueue(
        label: "com.flashghostty.session-metadata.process-lookup",
        qos: .utility,
        attributes: .concurrent
    )

    private weak var surface: Ghostty.SurfaceView?
    private var surfaceCancellables: Set<AnyCancellable> = []
    private var progressReport: Ghostty.Action.ProgressReport?
    private var lastInstructions: [UUID: String] = [:]
    private var instructionCaptureGeneration: UInt = 0
    private var processLookupGeneration: UInt = 0
    private var processLookupIsInFlight = false

    var boundSurface: Ghostty.SurfaceView? { surface }

    /// Bind to the best live surface from the controller's logical split tree.
    /// Transient focus loss preserves the previous valid source; removal from
    /// the tree clears it immediately.
    func bind(
        to requestedSurface: Ghostty.SurfaceView?,
        preserving previousSurface: Ghostty.SurfaceView?,
        contains: (Ghostty.SurfaceView) -> Bool,
        titleDidChange: @escaping (_ title: String, _ bell: Bool) -> Void
    ) {
        let candidates = [requestedSurface, surface, previousSurface]
        guard let nextSurface = candidates.compactMap({ $0 }).first(where: contains) else {
            clear(titleDidChange: titleDidChange)
            return
        }

        guard nextSurface !== surface || surfaceCancellables.isEmpty else { return }

        surfaceCancellables = []
        surface = nextSurface
        instructionCaptureGeneration &+= 1
        processLookupGeneration &+= 1
        processLookupIsInFlight = false
        progressReport = nil
        activityStatus = .ready
        lastInstruction = lastInstructions[nextSurface.id]
        foregroundProcessName = nil

        nextSurface.$title
            .combineLatest(nextSurface.$bell)
            .sink { [weak self] title, bell in
                guard let self else { return }
                dynamicTitle = title
                refreshActivityStatus()
                titleDidChange(title, bell)
            }
            .store(in: &surfaceCancellables)

        nextSurface.$progressReport
            .sink { [weak self] incomingReport in
                guard let self else { return }

                // Surface progress reports expire for display cleanup. A nil
                // value is not a protocol-level completion event.
                progressReport = TerminalSessionActivityClassifier.retainedProgressReport(
                    current: progressReport,
                    incoming: incomingReport
                )
                guard incomingReport != nil else { return }
                refreshActivityStatus()
            }
            .store(in: &surfaceCancellables)

        nextSurface.$pwd
            .map { path -> URL? in
                guard let path, !path.isEmpty else { return nil }
                return URL(fileURLWithPath: path)
            }
            .sink { [weak self] in self?.workingDirectory = $0 }
            .store(in: &surfaceCancellables)

        refresh()
    }

    /// Refresh screen-derived state immediately and schedule process ancestry
    /// resolution off the main thread. Repeated timer ticks coalesce while a
    /// lookup is already in flight.
    func refresh() {
        refreshActivityStatus()

        guard !processLookupIsInFlight,
              let surface,
              let pid = surface.surfaceModel?.foregroundPID,
              let processID = Int32(exactly: pid) else { return }

        processLookupIsInFlight = true
        let generation = processLookupGeneration
        let surfaceID = surface.id

        Self.processLookupQueue.async { [weak self] in
            let processName = TerminalSessionProcessResolver.foregroundProcessName(
                startingAt: processID
            )

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      processLookupGeneration == generation,
                      self.surface?.id == surfaceID else { return }

                processLookupIsInFlight = false

                // A transient proc_pidinfo failure must not erase otherwise
                // stable provider identity. A real exit yields the parent shell
                // on a later successful poll.
                if let processName, foregroundProcessName != processName {
                    foregroundProcessName = processName
                }
                refreshActivityStatus()
            }
        }
    }

    private func clear(
        titleDidChange: (_ title: String, _ bell: Bool) -> Void
    ) {
        instructionCaptureGeneration &+= 1
        processLookupGeneration &+= 1
        processLookupIsInFlight = false
        surfaceCancellables = []
        surface = nil
        dynamicTitle = ""
        foregroundProcessName = nil
        progressReport = nil
        tool = .terminal
        activityStatus = .ready
        lastInstruction = nil
        workingDirectory = nil
        titleDidChange("👻", false)
    }

    private func captureLastInstruction() {
        let tool = TerminalSessionTool.detect(
            fromDynamicTitle: dynamicTitle,
            foregroundProcessName: foregroundProcessName
        )
        guard tool != .terminal else { return }

        let visibleContents = surface?.cachedVisibleContents.get() ?? ""
        guard let instruction = TerminalSessionInstructionExtractor.lastInstruction(
            tool: tool,
            visibleContents: visibleContents
        ) else { return }

        if let surfaceID = surface?.id {
            lastInstructions[surfaceID] = instruction
        }
        if lastInstruction != instruction {
            lastInstruction = instruction
        }
    }

    private func scheduleLastInstructionCapture() {
        instructionCaptureGeneration &+= 1
        let generation = instructionCaptureGeneration
        let surfaceID = surface?.id

        // Agent TUIs update their title and viewport in neighboring render
        // passes. Bounded retries cross the visible-content cache interval.
        for delay in [0.0, 0.6, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      instructionCaptureGeneration == generation,
                      surface?.id == surfaceID else { return }
                captureLastInstruction()
            }
        }
    }

    private func refreshActivityStatus() {
        let detectedTool = TerminalSessionTool.detect(
            fromDynamicTitle: dynamicTitle,
            foregroundProcessName: foregroundProcessName
        )
        if tool != detectedTool {
            // Structured reports are scoped to the provider process that
            // emitted them. Do not carry a crashed/exited agent's last report
            // into the shell or a subsequently launched provider.
            progressReport = nil
            activityStatus = .ready
            tool = detectedTool
        }

        let visibleContents = detectedTool == .claudeCode ?
            surface?.cachedVisibleContents.get() ?? "" : ""
        var currentProgressReport = progressReport

        // Completed and failed are latched structured events. A later explicit
        // provider signal starts a new turn even if the surface still retains
        // its previous remove/error report during display cleanup.
        if let report = currentProgressReport,
           report.state == .remove || report.state == .error {
            let providerStatus = TerminalSessionActivityClassifier.status(
                tool: detectedTool,
                dynamicTitle: dynamicTitle,
                progressReport: nil,
                visibleContents: visibleContents,
                previous: activityStatus
            )
            if providerStatus == .active || providerStatus == .paused {
                progressReport = nil
                currentProgressReport = nil
            }
        }

        let nextStatus = TerminalSessionActivityClassifier.status(
            tool: detectedTool,
            dynamicTitle: dynamicTitle,
            progressReport: currentProgressReport,
            visibleContents: visibleContents,
            previous: activityStatus
        )
        let previousStatus = activityStatus
        if previousStatus != nextStatus {
            activityStatus = nextStatus
        }

        if (previousStatus != .active && nextStatus == .active) ||
            (previousStatus == .active && nextStatus != .active) {
            scheduleLastInstructionCapture()
        }
    }
}
