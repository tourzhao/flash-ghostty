import Combine
import Foundation

/// Stable, application-owned state for one logical group of terminal sessions.
///
/// `NSWindowTabGroup` is a presentation adapter for this state. AppKit may
/// temporarily report an empty, single-window, or replacement tab group while
/// selecting and restoring tabs, so views should observe this model instead of
/// deriving their identity or membership from AppKit objects.
@MainActor
final class SessionWorkspace: ObservableObject {
    struct SessionID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
        let rawValue: UUID

        init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }

        var description: String {
            rawValue.uuidString
        }
    }

    /// A single atomic value keeps observers from seeing an order, selection,
    /// and sidebar-visibility combination that violates workspace invariants.
    ///
    /// This is deliberately an in-memory projection, not a saved-state schema.
    /// AppKit restoration is versioned by `TerminalRestorableState`, which owns
    /// the compatibility defaults for session and file-browser presentation.
    struct Snapshot: Equatable, Sendable {
        var orderedSessionIDs: [SessionID]
        var selectedSessionID: SessionID?
        var isSidebarVisible: Bool
        var isFileBrowserVisible: Bool

        init(
            orderedSessionIDs: [SessionID] = [],
            selectedSessionID: SessionID? = nil,
            isSidebarVisible: Bool = true,
            isFileBrowserVisible: Bool = true
        ) {
            self.orderedSessionIDs = orderedSessionIDs
            self.selectedSessionID = selectedSessionID
            self.isSidebarVisible = isSidebarVisible
            self.isFileBrowserVisible = isFileBrowserVisible
        }
    }

    @Published private(set) var snapshot: Snapshot

    var orderedSessionIDs: [SessionID] { snapshot.orderedSessionIDs }
    var selectedSessionID: SessionID? { snapshot.selectedSessionID }
    var isSidebarVisible: Bool { snapshot.isSidebarVisible }
    var isFileBrowserVisible: Bool { snapshot.isFileBrowserVisible }
    var sessionCount: Int { snapshot.orderedSessionIDs.count }

    init(
        sessionIDs: [SessionID] = [],
        selectedSessionID: SessionID? = nil,
        isSidebarVisible: Bool = true,
        isFileBrowserVisible: Bool = true
    ) {
        self.snapshot = Self.normalized(
            Snapshot(
                orderedSessionIDs: sessionIDs,
                selectedSessionID: selectedSessionID,
                isSidebarVisible: isSidebarVisible,
                isFileBrowserVisible: isFileBrowserVisible
            )
        )
    }

    convenience init(snapshot: Snapshot) {
        self.init(
            sessionIDs: snapshot.orderedSessionIDs,
            selectedSessionID: snapshot.selectedSessionID,
            isSidebarVisible: snapshot.isSidebarVisible,
            isFileBrowserVisible: snapshot.isFileBrowserVisible
        )
    }

    func contains(_ sessionID: SessionID) -> Bool {
        snapshot.orderedSessionIDs.contains(sessionID)
    }

    /// Inserts a new stable identity. Re-registering an existing identity is
    /// idempotent and never changes its position.
    @discardableResult
    func addSession(
        _ sessionID: SessionID,
        at requestedIndex: Int? = nil,
        select: Bool = false
    ) -> Bool {
        guard !contains(sessionID) else {
            if select {
                _ = selectSession(sessionID)
            }

            return false
        }

        var next = snapshot
        let index = min(max(requestedIndex ?? next.orderedSessionIDs.count, 0),
                        next.orderedSessionIDs.count)
        next.orderedSessionIDs.insert(sessionID, at: index)

        if next.selectedSessionID == nil || select {
            next.selectedSessionID = sessionID
        }

        publish(next)
        return true
    }

    /// Removes a session and deterministically selects its right-hand neighbor,
    /// or the last remaining session when the removed item was last.
    @discardableResult
    func removeSession(_ sessionID: SessionID) -> Bool {
        guard let removedIndex = snapshot.orderedSessionIDs.firstIndex(of: sessionID) else {
            return false
        }

        var next = snapshot
        next.orderedSessionIDs.remove(at: removedIndex)

        if next.selectedSessionID == sessionID {
            guard !next.orderedSessionIDs.isEmpty else {
                next.selectedSessionID = nil
                publish(next)
                return true
            }

            let replacementIndex = min(removedIndex, next.orderedSessionIDs.count - 1)
            next.selectedSessionID = next.orderedSessionIDs[replacementIndex]
        }

        publish(next)
        return true
    }

    @discardableResult
    func selectSession(_ sessionID: SessionID) -> Bool {
        guard contains(sessionID) else { return false }
        guard snapshot.selectedSessionID != sessionID else { return true }

        var next = snapshot
        next.selectedSessionID = sessionID
        publish(next)
        return true
    }

    /// Moves a session to its final index in the resulting order.
    @discardableResult
    func moveSession(_ sessionID: SessionID, to requestedIndex: Int) -> Bool {
        guard let currentIndex = snapshot.orderedSessionIDs.firstIndex(of: sessionID) else {
            return false
        }

        let finalIndex = min(max(requestedIndex, 0), snapshot.orderedSessionIDs.count - 1)
        guard currentIndex != finalIndex else { return true }

        var next = snapshot
        next.orderedSessionIDs.remove(at: currentIndex)
        next.orderedSessionIDs.insert(sessionID, at: finalIndex)
        publish(next)
        return true
    }

    /// Atomically accepts a complete ordering/selection reconciliation.
    /// Membership must be an exact permutation of the existing workspace.
    /// Partial native tab snapshots are deliberately rejected.
    @discardableResult
    func reconcileOrder(
        _ orderedSessionIDs: [SessionID],
        selectedSessionID: SessionID?
    ) -> Bool {
        let currentIDs = snapshot.orderedSessionIDs
        guard orderedSessionIDs.count == currentIDs.count,
              Set(orderedSessionIDs).count == orderedSessionIDs.count,
              Set(orderedSessionIDs) == Set(currentIDs) else { return false }

        if orderedSessionIDs.isEmpty {
            guard selectedSessionID == nil else { return false }
        } else {
            guard let selectedSessionID,
                  orderedSessionIDs.contains(selectedSessionID) else { return false }
        }

        var next = snapshot
        next.orderedSessionIDs = orderedSessionIDs
        next.selectedSessionID = selectedSessionID
        publish(next)
        return true
    }

    func setSidebarVisible(_ isVisible: Bool) {
        guard snapshot.isSidebarVisible != isVisible else { return }

        var next = snapshot
        next.isSidebarVisible = isVisible
        publish(next)
    }

    func toggleSidebarVisibility() {
        setSidebarVisible(!snapshot.isSidebarVisible)
    }

    func setFileBrowserVisible(_ isVisible: Bool) {
        guard snapshot.isFileBrowserVisible != isVisible else { return }

        var next = snapshot
        next.isFileBrowserVisible = isVisible
        publish(next)
    }

    func toggleFileBrowserVisibility() {
        setFileBrowserVisible(!snapshot.isFileBrowserVisible)
    }

    private func publish(_ next: Snapshot) {
        let next = Self.normalized(next)
        guard next != snapshot else { return }
        snapshot = next
    }

    /// Invariants:
    /// - identities are unique and preserve first-seen order;
    /// - an empty workspace has no selection;
    /// - a non-empty workspace always selects one of its members.
    private static func normalized(_ candidate: Snapshot) -> Snapshot {
        var seen = Set<SessionID>()
        let orderedSessionIDs = candidate.orderedSessionIDs.filter {
            seen.insert($0).inserted
        }

        let selectedSessionID: SessionID?
        if orderedSessionIDs.isEmpty {
            selectedSessionID = nil
        } else if let candidateSelection = candidate.selectedSessionID,
                  orderedSessionIDs.contains(candidateSelection) {
            selectedSessionID = candidateSelection
        } else {
            selectedSessionID = orderedSessionIDs.first
        }

        return Snapshot(
            orderedSessionIDs: orderedSessionIDs,
            selectedSessionID: selectedSessionID,
            isSidebarVisible: candidate.isSidebarVisible,
            isFileBrowserVisible: candidate.isFileBrowserVisible
        )
    }
}
