import Foundation

enum SessionRestorationDecision: Equatable {
    case restore
    case startFresh
}

/// Holds restoration work until one launch-wide user decision is available.
/// Actions are returned to the caller so executing one can safely enqueue more
/// work without overlapping a mutation of this value.
struct StartupRestorationGate {
    typealias Decision = SessionRestorationDecision

    private struct Request {
        let restore: () -> Void
        let discard: () -> Void

        func action(for decision: Decision) -> () -> Void {
            decision == .restore ? restore : discard
        }
    }

    private var requests: [Request] = []
    private(set) var decision: Decision?

    var hasPendingRequests: Bool { !requests.isEmpty }

    mutating func enqueue(
        restore: @escaping () -> Void,
        discard: @escaping () -> Void
    ) -> (() -> Void)? {
        let request = Request(restore: restore, discard: discard)
        guard let decision else {
            requests.append(request)
            return nil
        }

        return request.action(for: decision)
    }

    mutating func resolve(_ decision: Decision) -> [() -> Void] {
        guard self.decision == nil else { return [] }

        self.decision = decision
        let actions = requests.map { $0.action(for: decision) }
        requests.removeAll()
        return actions
    }
}

/// Pure launch policy. In particular, a one-shot `-e` process skips restored
/// windows for this launch while leaving the previous interactive archive
/// untouched for the next normal launch.
enum StartupRestorationPolicy {
    enum Plan: Equatable {
        case awaitUserDecision
        case startFreshPreservingArchive
        case startFreshDiscardingArchive
    }

    static func plan(
        launchedWithExecuteCommand: Bool,
        restorationEnabled: Bool,
        archiveMarker: SessionRestorationArchiveMarker
    ) -> Plan {
        if launchedWithExecuteCommand {
            return .startFreshPreservingArchive
        }

        guard restorationEnabled else {
            return .startFreshDiscardingArchive
        }

        switch archiveMarker {
        case .discarded:
            return .startFreshDiscardingArchive
        case .legacy, .available:
            return .awaitUserDecision
        }
    }
}

/// Decides whether AppKit termination may proceed before the normal quit flow.
/// A system shutdown, restart, or logout must never be vetoed by a pending
/// restoration prompt; ordinary user-initiated Quit remains gated until the
/// user has made an explicit restore decision.
enum SessionRestorationTerminationPolicy {
    enum Disposition: Equatable {
        case terminateNow
        case cancel
        case continueNormalFlow
    }

    static func disposition(
        isSystemTermination: Bool,
        isAwaitingUserDecision: Bool
    ) -> Disposition {
        if isSystemTermination { return .terminateNow }
        if isAwaitingUserDecision { return .cancel }
        return .continueNormalFlow
    }
}

/// Defensive launch fallback for AppKit's restoration milestone. AppKit
/// documents that a no-window notification is posted before did-finish-launching;
/// if an observer missed it, a launch with no deferred restoration requests is
/// already complete and may safely create its initial window. A copied window
/// completion handler is represented by a pending request and must keep waiting.
enum SessionRestorationLaunchMilestonePolicy {
    static func mayInferCompletionAtDidFinishLaunching(
        notificationWasObserved: Bool,
        hasPendingRequests: Bool
    ) -> Bool {
        !notificationWasObserved && !hasPendingRequests
    }
}

/// Owns the launch-wide restoration decision and all persistence side effects.
/// AppKit adapters only enqueue passive materialization requests here.
@MainActor
final class SessionRestorationCoordinator {
    private let archiveStore: any SessionRestorationArchiveStoring
    private let promptPresenter: any SessionRestorationPromptPresenting
    private let didResolveFromPrompt: (SessionRestorationDecision) -> Void

    private var gate = StartupRestorationGate()
    private var promptIsActive = false
    private var didPrepareLaunch = false

    private(set) var preservesArchiveForLaunch = false
    private(set) var shouldInvalidateSavedState = false

    var decision: SessionRestorationDecision? { gate.decision }
    var hasPendingRequests: Bool { gate.hasPendingRequests }
    var isPromptActive: Bool { promptIsActive }

    /// True while AppKit restoration data belongs to the previous launch and
    /// the user has not decided what to do with it. The current workspace is
    /// intentionally still empty in this state, so it must not be treated as
    /// evidence that the previous archive was discarded.
    var isAwaitingUserDecision: Bool {
        didPrepareLaunch && decision == nil
    }

    /// Whether lifecycle callbacks must leave the previous archive untouched.
    /// This covers both one-shot `-e` launches and the interval between AppKit
    /// delivering restoration payloads and the user's explicit choice.
    var preservesExistingArchive: Bool {
        preservesArchiveForLaunch || isAwaitingUserDecision
    }

    /// AppKit has no API for allowing an empty, gated restoration graph to
    /// terminate while atomically retaining its previous saved-state archive.
    /// Cancel quit until the visible prompt supplies an explicit decision.
    var shouldCancelTermination: Bool {
        isAwaitingUserDecision
    }

    init(
        archiveStore: any SessionRestorationArchiveStoring,
        promptPresenter: any SessionRestorationPromptPresenting,
        didResolveFromPrompt: @escaping (SessionRestorationDecision) -> Void = { _ in }
    ) {
        self.archiveStore = archiveStore
        self.promptPresenter = promptPresenter
        self.didResolveFromPrompt = didResolveFromPrompt
    }

    func prepareLaunch(
        launchedWithExecuteCommand: Bool,
        restorationEnabled: Bool
    ) {
        guard !didPrepareLaunch else { return }
        didPrepareLaunch = true

        let plan = StartupRestorationPolicy.plan(
            launchedWithExecuteCommand: launchedWithExecuteCommand,
            restorationEnabled: restorationEnabled,
            archiveMarker: archiveStore.marker
        )

        switch plan {
        case .awaitUserDecision:
            return

        case .startFreshPreservingArchive:
            preservesArchiveForLaunch = true
            resolve(.startFresh, discardArchive: false, invalidateSavedState: false)

        case .startFreshDiscardingArchive:
            resolve(.startFresh, discardArchive: true, invalidateSavedState: true)
        }
    }

    func enqueue(
        restore: @escaping () -> Void,
        discard: @escaping () -> Void
    ) {
        if let action = gate.enqueue(restore: restore, discard: discard) {
            action()
            return
        }

        presentPromptIfNeeded()
    }

    /// Resolve a launch that had no actual AppKit restoration payload. Returns
    /// false while a real payload is still waiting for user input.
    func resolveNoPayloadIfPossible() -> Bool {
        if decision != nil { return true }
        guard !promptIsActive, !hasPendingRequests else { return false }

        resolve(.startFresh, discardArchive: true, invalidateSavedState: false)
        return true
    }

    /// Record whether the current interactive workspace has restorable state.
    /// One-shot and decision-pending launches deliberately ignore this so an
    /// empty, not-yet-materialized workspace cannot replace the prior marker.
    func recordArchiveAvailability(_ isAvailable: Bool) {
        guard !preservesExistingArchive else { return }
        archiveStore.store(isAvailable ? .available : .discarded)
    }

    /// Restoration was disabled by configuration. This is still a no-op for a
    /// launch that is already preserving a previous workspace. The initial
    /// disabled-restoration launch plan resolves before reaching this method.
    func discardArchiveBecauseRestorationIsDisabled() {
        guard !preservesExistingArchive else { return }
        archiveStore.store(.discarded)
    }

    private func presentPromptIfNeeded() {
        guard decision == nil,
              hasPendingRequests,
              !promptIsActive else { return }

        promptIsActive = true
        promptPresenter.present { [weak self] decision in
            guard let self else { return }
            self.promptIsActive = false

            let discardArchive = decision == .startFresh
            self.resolve(
                decision,
                discardArchive: discardArchive,
                invalidateSavedState: discardArchive
            )
            self.didResolveFromPrompt(decision)
        }
    }

    private func resolve(
        _ decision: SessionRestorationDecision,
        discardArchive: Bool,
        invalidateSavedState: Bool
    ) {
        guard gate.decision == nil else { return }

        if discardArchive && !preservesArchiveForLaunch {
            archiveStore.store(.discarded)
        }
        shouldInvalidateSavedState = invalidateSavedState && !preservesArchiveForLaunch

        let actions = gate.resolve(decision)
        actions.forEach { $0() }
    }
}
