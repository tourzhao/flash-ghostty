import Foundation

enum SessionRestorationDecision: Equatable {
    case restore
    case startFresh
}

/// Launch-wide authority for the shared restoration archive. Preservation is
/// deliberately independent from the user's restore decision and carries proof
/// that AppKit's outer archive was isolated before AppKit startup.
enum SessionRestorationArchiveWritePolicy: Equatable {
    case unresolved
    case preserveExisting(AppKitOuterArchiveIsolation)
    case ownCurrent
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

/// Pure policy for an ordinary interactive launch. Pre-isolated one-shot and
/// test-host launches are resolved by the coordinator before consulting this.
enum StartupRestorationPolicy {
    enum Plan: Equatable {
        case awaitUserDecision
        case startFreshDiscardingArchive
    }

    static func plan(
        restorationEnabled: Bool,
        archiveMarker: SessionRestorationArchiveMarker
    ) -> Plan {
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

/// Keeps an XCTest host from presenting production startup UI or replacing a
/// developer's saved workspace before the test bundle has begun executing.
/// UI-tested applications are separate processes and do not load XCTest, so
/// their restoration flows remain available to XCUIApplication tests.
enum SessionRestorationProcessRole {
    static func isUnitTestHost(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loadedBundlePaths: [String] = Bundle.allBundles.map(\.bundlePath)
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil ||
            loadedBundlePaths.contains { $0.hasSuffix(".xctest") }
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
    private var deferredTerminalLaunches: [() -> Void] = []
    private var promptIsActive = false
    private var didPrepareLaunch = false
    private var applicationLaunchIsReady = false

    private(set) var archiveWritePolicy:
        SessionRestorationArchiveWritePolicy = .unresolved
    private(set) var shouldInvalidateSavedState = false

    var decision: SessionRestorationDecision? { gate.decision }
    var hasPendingRequests: Bool { gate.hasPendingRequests }
    var isPromptActive: Bool { promptIsActive }
    var hasDeferredTerminalLaunches: Bool {
        !deferredTerminalLaunches.isEmpty
    }
    var isTerminalLaunchDeferred: Bool {
        decision == nil || !applicationLaunchIsReady
    }

    var preservesArchiveForLaunch: Bool {
        if case .preserveExisting = archiveWritePolicy { return true }
        return false
    }

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
        archiveWritePolicy != .ownCurrent
    }

    /// Restored windows may participate in the archive as soon as the user has
    /// accepted them. An outer-archive-isolated process must keep every window
    /// non-restorable for its entire launch.
    var allowsRestorableWindowCreation: Bool {
        if case .preserveExisting = archiveWritePolicy { return false }
        return archiveWritePolicy == .ownCurrent || decision == .restore
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
        outerArchiveIsolation: AppKitOuterArchiveIsolation? = nil,
        restorationEnabled: Bool
    ) {
        guard !didPrepareLaunch else { return }
        didPrepareLaunch = true

        // This token can only be minted after ApplePersistenceIgnoreState has
        // been installed before NSApplicationMain. Carry it in the state so a
        // future caller cannot request preservation from a process snapshot or
        // another late, unverified observation.
        if let outerArchiveIsolation {
            archiveWritePolicy = .preserveExisting(outerArchiveIsolation)
            resolve(
                .startFresh,
                discardArchive: false,
                invalidateSavedState: false
            )
            return
        }

        let plan = StartupRestorationPolicy.plan(
            restorationEnabled: restorationEnabled,
            archiveMarker: archiveStore.marker
        )

        switch plan {
        case .awaitUserDecision:
            // An explicit marker is reliable enough to put the decision window
            // on screen before AppKit disables the application while waiting on
            // asynchronous window-restoration completion handlers. Legacy
            // installs still wait until a real payload is observed.
            if archiveStore.marker == .available {
                presentPromptIfNeeded()
            }
            return

        case .startFreshDiscardingArchive:
            archiveWritePolicy = .ownCurrent
            resolve(
                .startFresh,
                discardArchive: true,
                invalidateSavedState: true
            )
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

    /// Queue terminal-producing external work until the restoration decision
    /// has materialized or discarded every saved window. Returns true when the
    /// action was deferred; ready launches execute their action at the caller so
    /// synchronous APIs can retain their normal return value.
    func deferTerminalLaunchIfNeeded(_ action: @escaping () -> Void) -> Bool {
        guard isTerminalLaunchDeferred else { return false }
        deferredTerminalLaunches.append(action)
        return true
    }

    /// AppDelegate calls this only after configuration, menus, notifications,
    /// and signal handlers have been initialized. A launch request that arrived
    /// early must not construct a controller from partially initialized app
    /// state even if restoration policy resolved synchronously.
    func applicationLaunchCompleted() {
        applicationLaunchIsReady = true
        drainDeferredTerminalLaunchesIfReady()
    }

    /// Resolve a launch that had no actual AppKit restoration payload. Returns
    /// false while a real payload is still waiting for user input. An isolated
    /// launch already resolved during preparation; no late process observation
    /// may turn an ordinary launch into an archive-preserving launch.
    func resolveNoPayloadIfPossible() -> Bool {
        if decision != nil { return true }
        guard !promptIsActive, !hasPendingRequests else { return false }

        archiveWritePolicy = .ownCurrent
        resolve(
            .startFresh,
            discardArchive: true,
            invalidateSavedState: true
        )
        return true
    }

    /// AppKit has delivered every restoration completion handler. A restored
    /// workspace becomes the current process's archive only at this milestone,
    /// never while individual windows are still being decoded.
    func restorationMilestoneCompleted() {
        guard decision == .restore else { return }
        archiveWritePolicy = .ownCurrent
    }

    /// `willEncodeRestorableState` is the only normal lifecycle callback that
    /// grants permission to publish current-workspace availability.
    func mayEncodeCurrentArchive() -> Bool {
        archiveWritePolicy == .ownCurrent
    }

    /// Record whether the current interactive workspace has restorable state.
    /// One-shot and decision-pending launches deliberately ignore this so an
    /// empty, not-yet-materialized workspace cannot replace the prior marker.
    func recordArchiveAvailability(_ isAvailable: Bool) {
        guard archiveWritePolicy == .ownCurrent else { return }
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
              !promptIsActive else { return }

        promptIsActive = true
        promptPresenter.present { [weak self] decision in
            guard let self else { return }
            self.promptIsActive = false

            let discardArchive = decision == .startFresh
            if discardArchive {
                self.archiveWritePolicy = .ownCurrent
            }
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

        if discardArchive && archiveWritePolicy == .ownCurrent {
            archiveStore.store(.discarded)
        }
        shouldInvalidateSavedState = invalidateSavedState && !preservesArchiveForLaunch

        let actions = gate.resolve(decision)
        actions.forEach { $0() }

        drainDeferredTerminalLaunchesIfReady()
    }

    private func drainDeferredTerminalLaunchesIfReady() {
        guard !isTerminalLaunchDeferred else { return }
        let actions = deferredTerminalLaunches
        deferredTerminalLaunches.removeAll()
        actions.forEach { $0() }
    }
}
