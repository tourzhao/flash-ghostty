import AppKit
import Combine

/// Bridges AppKit's native tab presentation to a `SessionWorkspace`.
///
/// Membership changes are explicit (`register`/`unregister`). A native tab
/// snapshot may synchronize order and selection only when it accounts for the
/// complete workspace, so transient AppKit state can never delete or collapse
/// the application-owned session list.
@MainActor
final class NativeTabGroupAdapter: ObservableObject {
    typealias SessionID = SessionWorkspace.SessionID

    struct NativeState: Equatable {
        let orderedSessionIDs: [SessionID]
        let selectedSessionID: SessionID?
        let reportedWindowCount: Int

        init(
            orderedSessionIDs: [SessionID],
            selectedSessionID: SessionID?,
            reportedWindowCount: Int? = nil
        ) {
            self.orderedSessionIDs = orderedSessionIDs
            self.selectedSessionID = selectedSessionID
            self.reportedWindowCount = reportedWindowCount ?? orderedSessionIDs.count
        }
    }

    /// A complete, reciprocal projection of every session in this workspace
    /// onto one or more native tab groups. A topology is intentionally broader
    /// than ``NativeState``: the latter describes one group and therefore
    /// cannot distinguish a transient partial AppKit snapshot from a permanent
    /// tab detachment.
    struct NativeTopology: Equatable {
        struct Group: Equatable {
            let orderedSessionIDs: [SessionID]
            let selectedSessionID: SessionID
        }

        let groups: [Group]
    }

    enum ReconciliationResult: Equatable {
        case synchronized(changed: Bool)
        case ignoredIncomplete
        case ignoredInvalid
    }

    let workspace: SessionWorkspace

    /// Changes whenever the stable identity-to-window projection changes. The
    /// workspace can publish membership before a new NSWindow is loaded, so UI
    /// consumers observe this independently from the workspace snapshot.
    @Published private(set) var bindingRevision: UInt = 0

    /// The last native group that produced a complete state. This is only a
    /// presentation handle; membership continues to live in `workspace`.
    private(set) weak var lastCompleteTabGroup: NSWindowTabGroup?

    private final class WindowBinding {
        weak var window: NSWindow?
        let identity: ObjectIdentifier

        init(_ window: NSWindow) {
            self.window = window
            self.identity = ObjectIdentifier(window)
        }
    }

    private var windowsBySessionID: [SessionID: WindowBinding] = [:]
    private var sessionIDsByWindowIdentity: [ObjectIdentifier: SessionID] = [:]
    private var partitionReconciliationGeneration: UInt = 0

    init(workspace: SessionWorkspace) {
        self.workspace = workspace
    }

    /// Permanently associates a native window with an application identity.
    /// A window or live identity cannot be rebound to a different counterpart.
    @discardableResult
    func register(
        _ window: NSWindow,
        as sessionID: SessionID,
        at index: Int? = nil,
        select: Bool = false
    ) -> Bool {
        pruneReleasedWindows()

        let identity = ObjectIdentifier(window)
        if let existingSessionID = sessionIDsByWindowIdentity[identity] {
            guard existingSessionID == sessionID else { return false }
            _ = workspace.addSession(sessionID, at: index, select: select)
            return true
        }

        if let existingWindow = windowsBySessionID[sessionID]?.window,
           existingWindow !== window {
            return false
        }

        let binding = WindowBinding(window)
        windowsBySessionID[sessionID] = binding
        sessionIDsByWindowIdentity[identity] = sessionID
        cancelPendingPartitionReconciliation()
        bindingRevision &+= 1
        _ = workspace.addSession(sessionID, at: index, select: select)
        return true
    }

    /// Removes a permanently closed window. Temporary AppKit detachment must
    /// not call this method; reconciliation alone never removes membership.
    @discardableResult
    func unregister(_ window: NSWindow) -> SessionID? {
        pruneReleasedWindows()

        let identity = ObjectIdentifier(window)
        guard let sessionID = sessionIDsByWindowIdentity[identity],
              let binding = windowsBySessionID[sessionID],
              binding.identity == identity,
              binding.window === window else {
            return nil
        }

        unregisterSession(sessionID)
        return sessionID
    }

    /// Removes a stable identity even if its native window has already been
    /// released. This is also the transfer primitive when a controller adopts
    /// an existing logical workspace.
    @discardableResult
    func unregisterSession(_ sessionID: SessionID) -> Bool {
        if let binding = windowsBySessionID.removeValue(forKey: sessionID) {
            sessionIDsByWindowIdentity.removeValue(forKey: binding.identity)
            cancelPendingPartitionReconciliation()
            bindingRevision &+= 1
        }

        return workspace.removeSession(sessionID)
    }

    /// Atomically transfers one session between logical workspaces. The
    /// destination is prepared first; if either side rejects the transfer, all
    /// destination changes are rolled back and the source remains authoritative.
    /// Closing controllers are never transferable, which prevents a late native
    /// tab KVO callback from recreating a row removed by `windowWillClose`.
    @discardableResult
    func transferSession(
        _ sessionID: SessionID,
        window: NSWindow?,
        to destination: NativeTabGroupAdapter,
        at index: Int? = nil,
        select: Bool = false,
        isClosing: Bool = false
    ) -> Bool {
        guard !isClosing else { return false }

        if self === destination {
            guard workspace.contains(sessionID) else { return false }
            if let window {
                return register(
                    window,
                    as: sessionID,
                    at: index,
                    select: select
                )
            }

            if select {
                _ = workspace.selectSession(sessionID)
            }
            return true
        }

        guard workspace.contains(sessionID),
              !destination.workspace.contains(sessionID) else { return false }

        let destinationPrepared: Bool
        if let window {
            destinationPrepared = destination.register(
                window,
                as: sessionID,
                at: index,
                select: select
            )
        } else {
            destinationPrepared = destination.workspace.addSession(
                sessionID,
                at: index,
                select: select
            )
        }
        guard destinationPrepared else { return false }

        guard unregisterSession(sessionID) else {
            _ = destination.unregisterSession(sessionID)
            return false
        }

        return true
    }

    func sessionID(for window: NSWindow) -> SessionID? {
        sessionIDsByWindowIdentity[ObjectIdentifier(window)]
    }

    func window(for sessionID: SessionID) -> NSWindow? {
        windowsBySessionID[sessionID]?.window
    }

    /// Reads a native group as a consistency event, not as persistent storage.
    @discardableResult
    func reconcile(_ tabGroup: NSWindowTabGroup) -> ReconciliationResult {
        pruneReleasedWindows()

        let windows = tabGroup.windows
        let orderedSessionIDs = windows.compactMap { sessionID(for: $0) }
        let selectedSessionID = tabGroup.selectedWindow.flatMap { sessionID(for: $0) }
        let result = reconcile(
            NativeState(
                orderedSessionIDs: orderedSessionIDs,
                selectedSessionID: selectedSessionID,
                reportedWindowCount: windows.count
            )
        )

        if case .synchronized = result {
            lastCompleteTabGroup = tabGroup
        }

        return result
    }

    /// Internal state-based entry point keeps the transient-state policy
    /// independently testable without constructing AppKit tab groups.
    @discardableResult
    func reconcile(_ nativeState: NativeState) -> ReconciliationResult {
        let nativeIDs = nativeState.orderedSessionIDs
        let workspaceIDs = workspace.orderedSessionIDs

        guard nativeState.reportedWindowCount >= 0,
              nativeState.reportedWindowCount == nativeIDs.count,
              nativeIDs.count == workspaceIDs.count,
              Set(nativeIDs) == Set(workspaceIDs) else {
            return .ignoredIncomplete
        }

        guard Set(nativeIDs).count == nativeIDs.count else {
            return .ignoredInvalid
        }

        if nativeIDs.isEmpty {
            guard nativeState.selectedSessionID == nil else {
                return .ignoredInvalid
            }
        } else {
            guard let selection = nativeState.selectedSessionID,
                  nativeIDs.contains(selection) else {
                return .ignoredInvalid
            }
        }

        let previous = workspace.snapshot
        guard workspace.reconcileOrder(
            nativeIDs,
            selectedSessionID: nativeState.selectedSessionID
        ) else {
            return .ignoredInvalid
        }

        return .synchronized(changed: workspace.snapshot != previous)
    }

    /// Converts a complete native partition into normalized workspace
    /// snapshots. Returning nil is the critical safety behavior: a partial or
    /// duplicated topology can never remove a session from the source model.
    func partitionSnapshots(
        for topology: NativeTopology
    ) -> [SessionWorkspace.Snapshot]? {
        let workspaceIDs = workspace.orderedSessionIDs
        let flattenedIDs = topology.groups.flatMap(\.orderedSessionIDs)

        guard !topology.groups.isEmpty,
              flattenedIDs.count == workspaceIDs.count,
              Set(flattenedIDs).count == flattenedIDs.count,
              Set(flattenedIDs) == Set(workspaceIDs),
              topology.groups.allSatisfy({ group in
                  !group.orderedSessionIDs.isEmpty &&
                      group.orderedSessionIDs.contains(group.selectedSessionID)
              }) else { return nil }

        return topology.groups.map { group in
            SessionWorkspace.Snapshot(
                orderedSessionIDs: group.orderedSessionIDs,
                selectedSessionID: group.selectedSessionID,
                isSidebarVisible: workspace.isSidebarVisible,
                isFileBrowserVisible: workspace.isFileBrowserVisible
            )
        }
    }

    /// A native subset is eligible to split the application model only after
    /// the complete topology is unchanged across an event-loop boundary. This
    /// coalesces related AppKit KVO notifications without retry timers and keeps
    /// a one-frame tab-selection snapshot from deleting sidebar rows.
    func schedulePartitionReconciliation(
        _ candidate: NativeTopology,
        resample: @escaping @MainActor () -> NativeTopology?,
        apply: @escaping @MainActor (NativeTopology) -> Void
    ) {
        guard let snapshots = partitionSnapshots(for: candidate),
              snapshots.count > 1 else {
            cancelPendingPartitionReconciliation()
            return
        }

        partitionReconciliationGeneration &+= 1
        let generation = partitionReconciliationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.partitionReconciliationGeneration == generation,
                  let confirmed = resample(),
                  confirmed == candidate,
                  let snapshots = self.partitionSnapshots(for: confirmed),
                  snapshots.count > 1 else { return }

            // Mark this validation consumed before application transfers
            // bindings and consequently advances the generation.
            self.partitionReconciliationGeneration &+= 1
            apply(confirmed)
        }
    }

    func cancelPendingPartitionReconciliation() {
        partitionReconciliationGeneration &+= 1
    }

    /// Performs a user-requested selection as one adapter operation. Returning
    /// true means AppKit accepted the request or already exposes the target; it
    /// does not imply that a deferred native transition has completed. The
    /// workspace changes only after a complete native snapshot confirms it.
    @discardableResult
    func selectSession(_ sessionID: SessionID, in tabGroup: NSWindowTabGroup) -> Bool {
        guard workspace.contains(sessionID),
              let targetWindow = window(for: sessionID),
              tabGroup.windows.contains(where: { $0 === targetWindow }) else {
            return false
        }

        if tabGroup.selectedWindow !== targetWindow,
           !tabGroup.selectWindowSafely(targetWindow) {
            return false
        }

        // The Objective-C boundary reports that the setter was accepted, not
        // that AppKit has completed its physical tab transition. Reconcile
        // only a confirmed, complete native snapshot; KVO will retry this once
        // a deferred getter exposes the target. Until then the root currently
        // on screen retains ownership of the live sidebars.
        if tabGroup.selectedWindow === targetWindow {
            _ = reconcile(tabGroup)
        }
        return true
    }

    private func pruneReleasedWindows() {
        let releasedSessionIDs = windowsBySessionID.compactMap { sessionID, binding in
            binding.window == nil ? sessionID : nil
        }

        for sessionID in releasedSessionIDs {
            guard let binding = windowsBySessionID.removeValue(forKey: sessionID) else {
                continue
            }

            sessionIDsByWindowIdentity.removeValue(forKey: binding.identity)
        }

        if !releasedSessionIDs.isEmpty {
            cancelPendingPartitionReconciliation()
            bindingRevision &+= 1
        }
    }
}

/// Executes an AppKit native-tab mutation with an explicit recovery path.
/// Callers use `.detached` to split logical workspace membership when neither
/// the requested attachment nor its physical rollback succeeds.
enum NativeTabAttachmentTransaction {
    enum Outcome: Equatable {
        case attached
        case rolledBack
        case detached
    }

    static func perform(
        attach: () -> Bool,
        rollback: () -> Bool
    ) -> Outcome {
        if attach() { return .attached }
        if rollback() { return .rolledBack }
        return .detached
    }
}

/// Chooses how a restored window may be focused without accidentally
/// detaching it from AppKit's native tab stack. A sidebar member must be
/// selected through its group; ordering an individual member is reserved for
/// standalone windows and the existing non-sidebar presentation path.
enum NativeTabFocusPolicy {
    enum Strategy: Equatable {
        case selectNativeTab
        case orderWindow
        case reject
    }

    static func strategy(
        usesSessionSidebar: Bool,
        logicalSessionCount: Int,
        nativeWindowCount: Int,
        containsTarget: Bool
    ) -> Strategy {
        guard usesSessionSidebar else { return .orderWindow }

        // A logical multi-session workspace observed as nil/singleton is an
        // AppKit transition, not proof that the target became standalone.
        // Ordering in this interval is precisely what can detach the window.
        if logicalSessionCount > 1 {
            guard nativeWindowCount == logicalSessionCount,
                  containsTarget else { return .reject }
            return .selectNativeTab
        }

        if nativeWindowCount > 1 {
            return containsTarget ? .selectNativeTab : .reject
        }

        return .orderWindow
    }
}

/// Weakly tracks the concrete controllers materialized by a grouped undo.
/// Redo must target this restored set rather than infer membership from a
/// native tab group, because an attachment failure can leave some restored
/// sessions as valid standalone windows.
@MainActor
final class SessionUndoRestorationSet<Element: AnyObject> {
    private final class Entry {
        weak var value: Element?
        let identity: ObjectIdentifier

        init(_ value: Element) {
            self.value = value
            self.identity = ObjectIdentifier(value)
        }
    }

    private var entries: [Entry] = []

    func insert(_ value: Element) {
        removeReleasedEntries()

        let identity = ObjectIdentifier(value)
        guard !entries.contains(where: { $0.identity == identity }) else { return }
        entries.append(Entry(value))
    }

    var liveValues: [Element] {
        removeReleasedEntries()
        return entries.compactMap(\.value)
    }

    private func removeReleasedEntries() {
        entries.removeAll { $0.value == nil }
    }
}
