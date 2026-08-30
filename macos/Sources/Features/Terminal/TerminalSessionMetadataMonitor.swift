import Combine
import Foundation
import GhosttyKit

/// `CachedValue` protects its fetch/cache state with an `NSLock`, and the
/// underlying Ghostty text API protects renderer state with its own mutex.
/// This narrow wrapper also keeps the AppKit view (and therefore libghostty's
/// unretained userdata) alive until the read is handed back to the main actor.
private final class TerminalSessionVisibleContentsSource: @unchecked Sendable {
    private let owner: Ghostty.SurfaceView
    private let value: CachedValue<String>

    init(_ owner: Ghostty.SurfaceView) {
        self.owner = owner
        self.value = owner.cachedActiveScreenContents
    }

    func read() -> String {
        withExtendedLifetime(owner) {
            value.get()
        }
    }
}

/// Lets a surface/tool generation invalidate a queued read before it reaches
/// the renderer lock. A cancellation that races after `isCancelled` is checked
/// can still enter `read`; the result is rejected again on the main actor.
private final class TerminalSessionVisibleContentsReadTicket: @unchecked Sendable {
    let requestID: UInt
    private let lock = NSLock()
    private var cancelled = false

    init(requestID: UInt) {
        self.requestID = requestID
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
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
    /// Renderer-backed active-screen reads and their string scans are deliberately
    /// serialized away from the main actor. Serializing also prevents one
    /// scheduler tick from making every session contend for renderer locks at
    /// the same time.
    private static let visibleContentsQueue = DispatchQueue(
        label: "com.flashghostty.session-metadata.visible-contents",
        qos: .utility
    )

    private weak var surface: Ghostty.SurfaceView?
    private var surfaceCancellables: Set<AnyCancellable> = []
    private var progressReport: Ghostty.Action.ProgressReport?
    private var lastInstructions = SessionInstructionStore()
    private var instructionCaptureGeneration: UInt = 0
    private var processLookupGeneration: UInt = 0
    private var processLookupIsInFlight = false
    private var processLookupThrottle = SessionProcessLookupThrottle()
    private var claudeVisibleContentsAnalysis: TerminalSessionVisibleContentsAnalysis?
    private var lastClaudeVisibleContentsRefreshUptime: TimeInterval?
    private var visibleContentsReadGeneration: UInt = 0
    private var claudeRequestState = SessionContentsRequestState()
    private var codexRequestState = SessionContentsRequestState()
    private var claudeReadTicket: TerminalSessionVisibleContentsReadTicket?
    private var codexReadTicket: TerminalSessionVisibleContentsReadTicket?
    private var visibleContentsTrailingRefresh: DispatchWorkItem?
    private var deferredInstructionCapture = DeferredInstructionCaptureState()
    private var refreshThrottle = SessionMetadataRefreshThrottle()

    var boundSurface: Ghostty.SurfaceView? { surface }
    var requiresPeriodicRefresh: Bool {
        refreshThrottle.mode != .suspended
    }

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
        processLookupThrottle.reset()
        progressReport = nil
        activityStatus = .ready
        tool = .terminal
        lastInstruction = nil
        foregroundProcessName = nil
        invalidateVisibleContentsReads()
        deferredInstructionCapture.reset()

        nextSurface.$title
            .removeDuplicates()
            .combineLatest(nextSurface.$bell.removeDuplicates())
            .sink { [weak self] title, bell in
                guard let self else { return }
                if dynamicTitle != title {
                    dynamicTitle = title
                    refreshActivityStatus()
                }
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
            .removeDuplicates()
            .map { path -> URL? in
                guard let path, !path.isEmpty else { return nil }
                return URL(fileURLWithPath: path)
            }
            .removeDuplicates()
            .sink { [weak self] in self?.workingDirectory = $0 }
            .store(in: &surfaceCancellables)

        refresh()
    }

    /// Refresh screen-derived state immediately and schedule process ancestry
    /// resolution off the main thread. Repeated timer ticks coalesce while a
    /// lookup is already in flight.
    func refresh() {
        refresh(allowClaudeSnapshotReuse: false)
    }

    func updateRefreshContext(
        sidebarIsVisible: Bool,
        sessionIsSelected: Bool
    ) {
        let nextMode = SessionMetadataPollingMode.resolve(
            sidebarIsVisible: sidebarIsVisible,
            sessionIsSelected: sessionIsSelected
        )
        guard nextMode != refreshThrottle.mode else { return }

        let wasSuspended = refreshThrottle.mode == .suspended
        let shouldRefreshImmediately = refreshThrottle.update(mode: nextMode)
        TerminalSessionMetadataRefreshScheduler.shared.refreshContextDidChange()
        if nextMode == .suspended {
            // A hidden sidebar has no consumer for renderer-backed metadata.
            // Cancel queued reads before they enter the renderer lock and reject
            // a read that is already running. Reopening starts from a fresh
            // snapshot because invalidation also clears its refresh timestamp.
            invalidateVisibleContentsReads()
            return
        }
        guard shouldRefreshImmediately else { return }
        if wasSuspended {
            // Reopening the sidebar must not reuse a snapshot retained while
            // reads were suspended; the immediate refresh below fetches fresh
            // terminal contents instead.
            lastClaudeVisibleContentsRefreshUptime = nil
        }
        refreshPeriodicMetadata()
    }

    /// Invalidate every asynchronous result owned by the monitoring lifecycle.
    /// Window close can leave a controller alive briefly for AppKit teardown, so
    /// unregistering it from the scheduler alone is not sufficient cancellation.
    func stopMonitoring() {
        instructionCaptureGeneration &+= 1
        processLookupGeneration &+= 1
        processLookupIsInFlight = false
        processLookupThrottle.reset()
        _ = refreshThrottle.update(mode: .suspended)
        invalidateVisibleContentsReads()
        deferredInstructionCapture.reset()
    }

    func refreshWhenRegistered() {
        guard refreshThrottle.mode != .suspended else { return }
        refreshPeriodicMetadata()
    }

    func refreshPeriodically() {
        guard refreshThrottle.consumeTick() else { return }
        refreshPeriodicMetadata()
    }

    private func refreshPeriodicMetadata() {
        let defersVisibleContentsRefresh = hasRecentScrollInput(
            now: ProcessInfo.processInfo.systemUptime
        )
        refresh(
            allowClaudeSnapshotReuse: true,
            defersVisibleContentsRefresh: defersVisibleContentsRefresh
        )
        retryPendingInstructionCapture(
            defersVisibleContentsRefresh: defersVisibleContentsRefresh
        )
    }

    private func refresh(
        allowClaudeSnapshotReuse: Bool,
        defersVisibleContentsRefresh: Bool = false
    ) {
        refreshActivityStatus(
            allowClaudeSnapshotReuse: allowClaudeSnapshotReuse,
            defersVisibleContentsRefresh: defersVisibleContentsRefresh
        )

        guard !processLookupIsInFlight,
              let surface,
              let pid = surface.surfaceModel?.foregroundPID,
              let processID = Int32(exactly: pid) else { return }

        let lookupUptime = ProcessInfo.processInfo.systemUptime
        guard processLookupThrottle.shouldLookup(
            processID: processID,
            now: lookupUptime
        ) else { return }

        processLookupIsInFlight = true
        let request = SessionProcessLookupRequest(
            generation: processLookupGeneration,
            surfaceID: surface.id,
            processID: processID
        )

        Self.processLookupQueue.async { [weak self] in
            let processName = TerminalSessionProcessResolver.foregroundProcessName(
                startingAt: request.processID
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let currentProcessID = self.surface?.surfaceModel?.foregroundPID
                    .flatMap { Int32(exactly: $0) }

                switch request.disposition(
                    currentGeneration: processLookupGeneration,
                    currentSurfaceID: self.surface?.id,
                    currentProcessID: currentProcessID
                ) {
                case .discard:
                    return
                case .retryCurrentProcess:
                    processLookupIsInFlight = false
                    // The surface stayed bound while its foreground process
                    // changed. Reject the old ancestry result and immediately
                    // start resolving the current PID instead of waiting for
                    // the next scheduler tick.
                    refresh()
                    return
                case .accept:
                    processLookupIsInFlight = false
                }

                // A transient proc_pidinfo failure must not erase otherwise
                // stable provider identity. A real exit yields the parent shell
                // on a later successful poll.
                if let processName {
                    processLookupThrottle.accept(
                        processID: request.processID,
                        now: ProcessInfo.processInfo.systemUptime
                    )
                    if foregroundProcessName != processName {
                        foregroundProcessName = processName
                        refreshActivityStatus(allowClaudeSnapshotReuse: false)
                    }
                }
            }
        }
    }

    private func clear(
        titleDidChange: (_ title: String, _ bell: Bool) -> Void
    ) {
        instructionCaptureGeneration &+= 1
        processLookupGeneration &+= 1
        processLookupIsInFlight = false
        processLookupThrottle.reset()
        surfaceCancellables = []
        surface = nil
        dynamicTitle = ""
        foregroundProcessName = nil
        progressReport = nil
        tool = .terminal
        activityStatus = .ready
        lastInstruction = nil
        workingDirectory = nil
        invalidateVisibleContentsReads()
        deferredInstructionCapture.reset()
        titleDidChange("👻", false)
    }

    private func invalidateVisibleContentsReads() {
        visibleContentsReadGeneration &+= 1
        visibleContentsTrailingRefresh?.cancel()
        visibleContentsTrailingRefresh = nil
        claudeReadTicket?.cancel()
        codexReadTicket?.cancel()
        claudeReadTicket = nil
        codexReadTicket = nil
        claudeRequestState.reset()
        codexRequestState.reset()
        claudeVisibleContentsAnalysis = nil
        lastClaudeVisibleContentsRefreshUptime = nil
    }

    func hasRecentScrollInput(now: TimeInterval) -> Bool {
        guard let lastScrollInput = surface?.lastScrollInputUptime else { return false }
        return now - lastScrollInput < SessionContentsRefreshPolicy.scrollCooldown
    }

    private func claudeAnalysis(
        allowSnapshotReuse: Bool,
        defersSnapshotRefresh: Bool
    ) -> TerminalSessionVisibleContentsAnalysis? {
        guard let surface else {
            return TerminalSessionVisibleContentsAnalysis(
                requiresUserInput: false,
                lastInstruction: nil
            )
        }

        let now = ProcessInfo.processInfo.systemUptime
        let decision = SessionContentsRefreshPolicy.decision(
            now: now,
            lastScrollInput: surface.lastScrollInputUptime,
            lastRefresh: lastClaudeVisibleContentsRefreshUptime,
            allowsSnapshotReuse: allowSnapshotReuse,
            defersSnapshotRefresh: defersSnapshotRefresh
        )

        switch decision {
        case .deferUntilScrollingStops:
            return nil
        case .reuseSnapshot:
            if let claudeVisibleContentsAnalysis {
                return claudeVisibleContentsAnalysis
            }
            scheduleClaudeAnalysisRead(from: surface, purpose: .status)
            return nil
        case .refreshSnapshot:
            scheduleClaudeAnalysisRead(
                from: surface,
                purpose: .status,
                requiresFreshResultIfBusy: true
            )
            return nil
        }
    }

    private func scheduleClaudeAnalysisRead(
        from surface: Ghostty.SurfaceView,
        purpose: SessionContentsRequestState.Purpose,
        requiresFreshResultIfBusy: Bool = false
    ) {
        guard refreshThrottle.mode.allowsVisibleContentsReads else { return }
        let action = claudeRequestState.request(
            purpose,
            now: ProcessInfo.processInfo.systemUptime,
            requiresFreshResultIfBusy: requiresFreshResultIfBusy
        )
        switch action {
        case .start(let request):
            visibleContentsTrailingRefresh?.cancel()
            visibleContentsTrailingRefresh = nil
            enqueueClaudeAnalysisRead(from: surface, request: request)
        case .scheduleTrailing(let trailingRefresh):
            replaceClaudeTrailingRefresh(trailingRefresh)
        case .coalesced:
            break
        }
    }

    private func replaceClaudeTrailingRefresh(
        _ trailingRefresh: SessionContentsRequestState.TrailingRefresh
    ) {
        visibleContentsTrailingRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      let request = self.claudeRequestState.beginTrailingRefresh(
                        id: trailingRefresh.id
                      ) else { return }
                self.visibleContentsTrailingRefresh = nil
                guard self.refreshThrottle.mode.allowsVisibleContentsReads,
                      let surface = self.surface,
                      TerminalSessionTool.detect(
                        fromDynamicTitle: self.dynamicTitle,
                        foregroundProcessName: self.foregroundProcessName
                      ) == .claudeCode else {
                    self.claudeRequestState.reset()
                    return
                }
                self.enqueueClaudeAnalysisRead(from: surface, request: request)
            }
        }
        visibleContentsTrailingRefresh = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + trailingRefresh.delay,
            execute: workItem
        )
    }

    private func enqueueClaudeAnalysisRead(
        from surface: Ghostty.SurfaceView,
        request: SessionContentsRequestState.Request
    ) {
        let source = TerminalSessionVisibleContentsSource(surface)
        let surfaceID = surface.id
        let generation = visibleContentsReadGeneration
        let ticket = TerminalSessionVisibleContentsReadTicket(requestID: request.id)
        claudeReadTicket = ticket

        Self.visibleContentsQueue.async {
            // Coalesced requests never enqueue a job. Generation invalidation
            // cancels queued jobs before this last pre-lock check. Cancellation
            // can still race immediately after the check; the main-actor
            // generation/request validation rejects that result.
            let analysis: TerminalSessionVisibleContentsAnalysis?
            if ticket.isCancelled {
                analysis = nil
            } else {
                let candidate = TerminalSessionVisibleContentsAnalyzer.analyze(
                    tool: .claudeCode,
                    visibleContents: source.read()
                )
                analysis = ticket.isCancelled ? nil : candidate
            }

            DispatchQueue.main.async { [weak self, source] in
                // Ensure a surface removed while the queue was reading is
                // released on AppKit's actor, never on the utility queue.
                defer { withExtendedLifetime(source) {} }
                guard let self,
                      let analysis,
                      visibleContentsReadGeneration == generation,
                      self.surface?.id == surfaceID else { return }

                let completionUptime = ProcessInfo.processInfo.systemUptime
                let completion = claudeRequestState.complete(
                    requestID: request.id,
                    now: completionUptime
                )
                guard completion.acceptsResult else { return }
                if claudeReadTicket?.requestID == request.id {
                    claudeReadTicket = nil
                }

                // A superseded request must not briefly apply stale permission
                // or title facts. Keep only the follow-up requirement and let
                // the next read produce the state that reaches the sidebar.
                if let followUpPurpose = completion.followUpPurpose {
                    let defersVisibleContentsRefresh = hasRecentScrollInput(
                        now: ProcessInfo.processInfo.systemUptime
                    )
                    switch followUpPurpose {
                    case .status:
                        lastClaudeVisibleContentsRefreshUptime = nil
                        if !defersVisibleContentsRefresh,
                           let currentSurface = self.surface,
                           currentSurface.id == surfaceID,
                           TerminalSessionTool.detect(
                            fromDynamicTitle: dynamicTitle,
                            foregroundProcessName: foregroundProcessName
                           ) == .claudeCode {
                            scheduleClaudeAnalysisRead(
                                from: currentSurface,
                                purpose: .status
                            )
                        }
                    case .instructionCapture:
                        retryPendingInstructionCapture(
                            defersVisibleContentsRefresh:
                                defersVisibleContentsRefresh
                        )
                    }
                    return
                }

                claudeVisibleContentsAnalysis = analysis
                lastClaudeVisibleContentsRefreshUptime = completionUptime
                if let captureID = completion.fulfilledCaptureID,
                   deferredInstructionCapture.consume(id: captureID) {
                    storeLastInstruction(analysis.lastInstruction)
                }
                refreshActivityStatus(
                    allowClaudeSnapshotReuse: true,
                    providedClaudeAnalysis: analysis
                )
                if deferredInstructionCapture.isPending {
                    retryPendingInstructionCapture(
                        defersVisibleContentsRefresh: hasRecentScrollInput(
                            now: ProcessInfo.processInfo.systemUptime
                        )
                    )
                }
            }
        }
    }

    private func captureLastInstruction() {
        let detectedTool = TerminalSessionTool.detect(
            fromDynamicTitle: dynamicTitle,
            foregroundProcessName: foregroundProcessName
        )
        guard detectedTool != .terminal, surface != nil else { return }

        deferredInstructionCapture.markDeferred()
        retryPendingInstructionCapture(
            defersVisibleContentsRefresh: hasRecentScrollInput(
                now: ProcessInfo.processInfo.systemUptime
            )
        )
    }

    private func retryPendingInstructionCapture(
        defersVisibleContentsRefresh: Bool
    ) {
        guard refreshThrottle.mode.allowsVisibleContentsReads else { return }
        guard InstructionCaptureRetryPolicy.shouldRetry(
            hasPendingCapture: deferredInstructionCapture.isPending,
            defersVisibleContentsRefresh: defersVisibleContentsRefresh
        ) else { return }
        guard let captureID = deferredInstructionCapture.pendingID,
              let surface else { return }

        let detectedTool = TerminalSessionTool.detect(
            fromDynamicTitle: dynamicTitle,
            foregroundProcessName: foregroundProcessName
        )
        let purpose = SessionContentsRequestState.Purpose
            .instructionCapture(captureID)
        switch detectedTool {
        case .claudeCode:
            scheduleClaudeAnalysisRead(from: surface, purpose: purpose)
        case .codex:
            scheduleCodexInstructionRead(from: surface, purpose: purpose)
        case .terminal:
            deferredInstructionCapture.reset()
        }
    }

    private func scheduleCodexInstructionRead(
        from surface: Ghostty.SurfaceView,
        purpose: SessionContentsRequestState.Purpose
    ) {
        guard refreshThrottle.mode.allowsVisibleContentsReads else { return }
        let action = codexRequestState.request(
            purpose,
            now: ProcessInfo.processInfo.systemUptime
        )
        switch action {
        case .start(let request):
            visibleContentsTrailingRefresh?.cancel()
            visibleContentsTrailingRefresh = nil
            enqueueCodexInstructionRead(from: surface, request: request)
        case .scheduleTrailing(let trailingRefresh):
            replaceCodexTrailingRefresh(trailingRefresh)
        case .coalesced:
            break
        }
    }

    private func replaceCodexTrailingRefresh(
        _ trailingRefresh: SessionContentsRequestState.TrailingRefresh
    ) {
        visibleContentsTrailingRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      let request = self.codexRequestState.beginTrailingRefresh(
                        id: trailingRefresh.id
                      ) else { return }
                self.visibleContentsTrailingRefresh = nil
                guard self.refreshThrottle.mode.allowsVisibleContentsReads,
                      let surface = self.surface,
                      TerminalSessionTool.detect(
                        fromDynamicTitle: self.dynamicTitle,
                        foregroundProcessName: self.foregroundProcessName
                      ) == .codex else {
                    self.codexRequestState.reset()
                    return
                }
                self.enqueueCodexInstructionRead(from: surface, request: request)
            }
        }
        visibleContentsTrailingRefresh = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + trailingRefresh.delay,
            execute: workItem
        )
    }

    private func enqueueCodexInstructionRead(
        from surface: Ghostty.SurfaceView,
        request: SessionContentsRequestState.Request
    ) {
        let source = TerminalSessionVisibleContentsSource(surface)
        let surfaceID = surface.id
        let sourceGeneration = visibleContentsReadGeneration
        let ticket = TerminalSessionVisibleContentsReadTicket(requestID: request.id)
        codexReadTicket = ticket

        Self.visibleContentsQueue.async {
            let analysis: TerminalSessionVisibleContentsAnalysis?
            if ticket.isCancelled {
                analysis = nil
            } else {
                let candidate = TerminalSessionVisibleContentsAnalyzer.analyze(
                    tool: .codex,
                    visibleContents: source.read()
                )
                analysis = ticket.isCancelled ? nil : candidate
            }

            DispatchQueue.main.async { [weak self, source] in
                defer { withExtendedLifetime(source) {} }
                guard let self,
                      let analysis,
                      visibleContentsReadGeneration == sourceGeneration,
                      self.surface?.id == surfaceID,
                      TerminalSessionTool.detect(
                        fromDynamicTitle: dynamicTitle,
                        foregroundProcessName: foregroundProcessName
                      ) == .codex else { return }

                let completion = codexRequestState.complete(
                    requestID: request.id,
                    now: ProcessInfo.processInfo.systemUptime
                )
                guard completion.acceptsResult else { return }
                if codexReadTicket?.requestID == request.id {
                    codexReadTicket = nil
                }
                if let captureID = completion.fulfilledCaptureID,
                   deferredInstructionCapture.consume(id: captureID) {
                    storeLastInstruction(analysis.lastInstruction)
                }
                if completion.requiresFollowUp || deferredInstructionCapture.isPending {
                    retryPendingInstructionCapture(
                        defersVisibleContentsRefresh: hasRecentScrollInput(
                            now: ProcessInfo.processInfo.systemUptime
                        )
                    )
                }
            }
        }
    }

    private func storeLastInstruction(_ instruction: String?) {
        guard let instruction,
              let surfaceID = surface?.id,
              tool != .terminal else { return }

        lastInstructions.store(instruction, surfaceID: surfaceID, tool: tool)
        if lastInstruction != instruction {
            lastInstruction = instruction
        }
    }

    private func scheduleLastInstructionCapture() {
        instructionCaptureGeneration &+= 1
        deferredInstructionCapture.reset()
        let generation = instructionCaptureGeneration
        let surfaceID = surface?.id

        // Agent TUIs update their title and active screen in neighboring render
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

    private func refreshActivityStatus(
        allowClaudeSnapshotReuse: Bool = false,
        defersVisibleContentsRefresh: Bool = false,
        providedClaudeAnalysis: TerminalSessionVisibleContentsAnalysis? = nil
    ) {
        let detectedTool = TerminalSessionTool.detect(
            fromDynamicTitle: dynamicTitle,
            foregroundProcessName: foregroundProcessName
        )
        if tool != detectedTool {
            // Structured reports are scoped to the provider process that
            // emitted them. Do not carry a crashed/exited agent's last report
            // into the shell or a subsequently launched provider.
            instructionCaptureGeneration &+= 1
            progressReport = nil
            activityStatus = .ready
            invalidateVisibleContentsReads()
            deferredInstructionCapture.reset()
            tool = detectedTool
            if let surfaceID = surface?.id {
                lastInstruction = lastInstructions.instruction(
                    surfaceID: surfaceID,
                    tool: detectedTool
                )
            } else {
                lastInstruction = nil
            }
        }

        var currentProgressReport = progressReport
        var currentAnalysis = providedClaudeAnalysis
        let contentIndependentStatus =
            TerminalSessionActivityClassifier.statusWithoutVisibleContentsIfDefinitive(
                tool: detectedTool,
                dynamicTitle: dynamicTitle,
                progressReport: currentProgressReport,
                previous: activityStatus
            )
        let requiresVisibleContents =
            TerminalSessionActivityClassifier.requiresVisibleContentsFallback(
                tool: detectedTool,
                progressReport: currentProgressReport
            )
        let requiresSnapshot = SessionContentsRefreshPolicy.requiresSnapshot(
            forStatusFallback: requiresVisibleContents,
            contentIndependentStatus: contentIndependentStatus
        )

        if requiresSnapshot {
            if currentAnalysis == nil {
                currentAnalysis = claudeAnalysis(
                    allowSnapshotReuse: allowClaudeSnapshotReuse,
                    defersSnapshotRefresh: defersVisibleContentsRefresh
                )
            }
            if currentAnalysis == nil {
                // A deferred event-driven refresh must not let the next timer
                // reuse the snapshot that predates the scroll gesture.
                lastClaudeVisibleContentsRefreshUptime = nil
                // Structured progress and active spinner titles remain
                // authoritative even while active-screen reads are deferred.
                guard contentIndependentStatus != nil else { return }
            }
        }

        let analysis = currentAnalysis ?? TerminalSessionVisibleContentsAnalysis(
            requiresUserInput: false,
            lastInstruction: nil
        )

        // Completed and failed are latched structured events. A later explicit
        // provider signal starts a new turn even if the surface still retains
        // its previous remove/error report during display cleanup.
        if let report = currentProgressReport,
           report.state == .remove || report.state == .error {
            let providerStatus = TerminalSessionActivityClassifier.status(
                tool: detectedTool,
                dynamicTitle: dynamicTitle,
                progressReport: nil,
                visibleContentsAnalysis: analysis,
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
            visibleContentsAnalysis: analysis,
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
