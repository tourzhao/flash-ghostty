import Foundation

/// Preserves the latest round while process ancestry is unresolved. Each
/// supported provider has a constant-size reduction, so spinner updates cannot
/// evict the evidence that a completed round actually started.
struct SessionPendingProcessActivity {
    let processID: Int32

    private var codex: Candidate
    private var claude: Candidate

    init(
        processID: Int32,
        previousTool: TerminalSessionTool,
        previousStatus: TerminalSessionActivityStatus
    ) {
        self.processID = processID
        self.codex = Candidate(previous: previousTool == .codex ? previousStatus : .ready)
        self.claude = Candidate(previous: previousTool == .claudeCode ? previousStatus : .ready)
    }

    /// A non-nil report is a fresh structured event. Title-only observations
    /// pass nil; a surface's nil display-expiry callback is not an observation.
    mutating func observe(
        title: String,
        progressReport: Ghostty.Action.ProgressReport?,
        observedAt: TimeInterval
    ) {
        codex.observe(tool: .codex, title: title, report: progressReport, observedAt: observedAt)
        claude.observe(tool: .claudeCode, title: title, report: progressReport, observedAt: observedAt)
    }

    func replay(for tool: TerminalSessionTool) -> [TerminalSessionActivitySnapshot] {
        switch tool {
        case .codex: codex.replay(tool: tool)
        case .claudeCode: claude.replay(tool: tool)
        case .terminal: []
        }
    }

    func retainedProgress(for tool: TerminalSessionTool) -> Ghostty.Action.ProgressReport? {
        switch tool {
        case .codex: codex.progressReport
        case .claudeCode: claude.progressReport
        case .terminal: nil
        }
    }

    private struct Observation {
        let status: TerminalSessionActivityStatus
        let observedAt: TimeInterval?

        func snapshot(tool: TerminalSessionTool) -> TerminalSessionActivitySnapshot {
            .init(tool: tool, status: status, observedAt: observedAt)
        }
    }

    private struct Candidate {
        var progressReport: Ghostty.Action.ProgressReport?
        private var previous: TerminalSessionActivityStatus
        private var latest: Observation?
        private var activeWitness: Observation?
        private var disarmingWitness: Observation?

        init(previous: TerminalSessionActivityStatus) {
            self.previous = previous
            if previous == .active || previous == .paused {
                activeWitness = Observation(status: .active, observedAt: nil)
            }
        }

        mutating func observe(
            tool: TerminalSessionTool,
            title: String,
            report: Ghostty.Action.ProgressReport?,
            observedAt: TimeInterval
        ) {
            if let report {
                progressReport = report
            } else if let retained = progressReport,
                      retained.state == .remove || retained.state == .error {
                // Only a later title observation can supersede a latched
                // report. The title accompanying a fresh remove may still be
                // the spinner from the round that has just finished.
                let providerStatus = TerminalSessionActivityClassifier.status(
                    tool: tool,
                    dynamicTitle: title,
                    progressReport: nil,
                    visibleContents: "",
                    previous: previous
                )
                if providerStatus == .active || providerStatus == .paused {
                    progressReport = nil
                }
            }

            let definitive = TerminalSessionActivityClassifier.statusWithoutVisibleContentsIfDefinitive(
                tool: tool,
                dynamicTitle: title,
                progressReport: progressReport,
                previous: previous
            )
            let status: TerminalSessionActivityStatus
            if let definitive {
                status = definitive
            } else if tool == .codex {
                // Codex's idle and approval titles never require a screen
                // read. Claude's idle title still needs its prompt analysis.
                status = TerminalSessionActivityClassifier.status(
                    tool: tool,
                    dynamicTitle: title,
                    progressReport: nil,
                    visibleContents: "",
                    previous: previous
                )
            } else {
                return
            }

            if latest?.status != status {
                latest = Observation(status: status, observedAt: observedAt)
            }
            switch status {
            case .active, .paused:
                disarmingWitness = nil
                if previous != .active && previous != .paused || activeWitness == nil {
                    activeWitness = Observation(status: .active, observedAt: observedAt)
                }
            case .ready, .failed:
                activeWitness = nil
                disarmingWitness = latest
            case .completed:
                break
            }
            previous = status
        }

        func replay(tool: TerminalSessionTool) -> [TerminalSessionActivitySnapshot] {
            guard let latest else { return [] }
            if latest.status == .completed, let activeWitness {
                return [activeWitness.snapshot(tool: tool), latest.snapshot(tool: tool)]
            }
            if latest.status == .completed, let disarmingWitness {
                // A consumer may still hold an armed or unread prior round.
                // Preserve the reset that prevents this completion inheriting it.
                return [disarmingWitness.snapshot(tool: tool), latest.snapshot(tool: tool)]
            }
            return [latest.snapshot(tool: tool)]
        }
    }
}
