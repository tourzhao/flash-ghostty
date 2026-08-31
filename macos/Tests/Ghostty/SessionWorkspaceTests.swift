import AppKit
import Testing
@testable import Ghostty

@Suite @MainActor
struct SessionWorkspaceTests {
    typealias SessionID = SessionWorkspace.SessionID

    @Test func sessionRootMinimumWidthPreservesTerminalAndVisibleSidebars() {
        #expect(
            TerminalSessionRootView.minimumContentWidth(
                isSidebarVisible: true,
                isFileBrowserVisible: true,
                sidebarWidth: 260,
                fileBrowserWidth: 300
            ) == 814
        )
        #expect(
            TerminalSessionRootView.minimumContentWidth(
                isSidebarVisible: false,
                isFileBrowserVisible: true,
                sidebarWidth: 260,
                fileBrowserWidth: 300
            ) == 547
        )
        #expect(
            TerminalSessionRootView.minimumContentWidth(
                isSidebarVisible: false,
                isFileBrowserVisible: false,
                sidebarWidth: 260,
                fileBrowserWidth: 300
            ) == TerminalSessionRootView.minimumTerminalContentWidth
        )

        #expect(
            TerminalSessionRootView.constrainedMinimumContentWidth(
                814,
                visibleFrameWidth: 1_440
            ) == 720
        )
        #expect(
            TerminalSessionRootView.constrainedMinimumContentWidth(
                814,
                visibleFrameWidth: 2_000
            ) == 814
        )
    }

    @Test func newTabsInheritImmutableParentWindowPresentation() {
        let sidebar = TerminalWindowPresentation(
            windowDecorations: true,
            titlebarStyle: .sidebar
        )
        let hidden = TerminalWindowPresentation(
            windowDecorations: true,
            titlebarStyle: .hidden
        )

        #expect(sidebar.usesSessionSidebar)
        #expect(!sidebar.usesHiddenTitlebar)
        #expect(hidden.usesHiddenTitlebar)
        #expect(
            TerminalWindowPresentation.inheritedForNewTab(from: sidebar) == sidebar
        )
        #expect(
            TerminalWindowPresentation.inheritedForNewTab(from: hidden) == hidden
        )
        #expect(sidebar.canShareNativeTabGroup(with: sidebar))
        #expect(!sidebar.canShareNativeTabGroup(with: hidden))
    }

    @Test func initializationNormalizesMembershipAndSelection() {
        let first = SessionID()
        let second = SessionID()
        let unknown = SessionID()
        let workspace = SessionWorkspace(
            sessionIDs: [first, second, first],
            selectedSessionID: unknown,
            isSidebarVisible: false
        )

        #expect(workspace.orderedSessionIDs == [first, second])
        #expect(workspace.selectedSessionID == first)
        #expect(!workspace.isSidebarVisible)
    }

    @Test func snapshotInitializationPreservesTransientPresentationState() {
        let first = SessionID()
        let second = SessionID()
        let workspace = SessionWorkspace(snapshot: .init(
            orderedSessionIDs: [first, second, first],
            selectedSessionID: second,
            isSidebarVisible: false,
            isFileBrowserVisible: false
        ))

        #expect(workspace.orderedSessionIDs == [first, second])
        #expect(workspace.selectedSessionID == second)
        #expect(!workspace.isSidebarVisible)
        #expect(!workspace.isFileBrowserVisible)
    }

    @Test func registrationIsIdempotentAndKeepsStableOrder() {
        let first = SessionID()
        let second = SessionID()
        let workspace = SessionWorkspace(sessionIDs: [first])

        #expect(!workspace.addSession(first, at: 1))
        #expect(workspace.addSession(second, at: 0, select: true))
        #expect(workspace.orderedSessionIDs == [second, first])
        #expect(workspace.selectedSessionID == second)
    }

    @Test func removingSelectionChoosesNearestRemainingSession() {
        let first = SessionID()
        let second = SessionID()
        let third = SessionID()
        let workspace = SessionWorkspace(
            sessionIDs: [first, second, third],
            selectedSessionID: second
        )

        #expect(workspace.removeSession(second))
        #expect(workspace.orderedSessionIDs == [first, third])
        #expect(workspace.selectedSessionID == third)

        #expect(workspace.removeSession(third))
        #expect(workspace.selectedSessionID == first)

        #expect(workspace.removeSession(first))
        #expect(workspace.orderedSessionIDs.isEmpty)
        #expect(workspace.selectedSessionID == nil)
    }

    @Test func movePreservesSelectionAndClampsFinalIndex() {
        let first = SessionID()
        let second = SessionID()
        let third = SessionID()
        let workspace = SessionWorkspace(
            sessionIDs: [first, second, third],
            selectedSessionID: first
        )

        #expect(workspace.moveSession(first, to: 99))
        #expect(workspace.orderedSessionIDs == [second, third, first])
        #expect(workspace.selectedSessionID == first)

        #expect(workspace.moveSession(first, to: -1))
        #expect(workspace.orderedSessionIDs == [first, second, third])
    }

    @Test func partialReconciliationIsRejectedAtomically() {
        let first = SessionID()
        let second = SessionID()
        let workspace = SessionWorkspace(
            sessionIDs: [first, second],
            selectedSessionID: first
        )
        let before = workspace.snapshot

        #expect(!workspace.reconcileOrder([second], selectedSessionID: second))
        #expect(workspace.snapshot == before)

        #expect(workspace.reconcileOrder([second, first], selectedSessionID: second))
        #expect(workspace.orderedSessionIDs == [second, first])
        #expect(workspace.selectedSessionID == second)
    }

    @Test func sidebarVisibilityIsWorkspaceState() {
        let workspace = SessionWorkspace(sessionIDs: [SessionID()])

        workspace.setSidebarVisible(false)
        #expect(!workspace.isSidebarVisible)

        workspace.toggleSidebarVisibility()
        #expect(workspace.isSidebarVisible)
    }

    @Test func fileBrowserVisibilityDefaultsToVisible() {
        let workspace = SessionWorkspace(sessionIDs: [SessionID()])

        #expect(workspace.isFileBrowserVisible)
        #expect(workspace.snapshot.isFileBrowserVisible)
    }

    @Test func sidebarAndFileBrowserVisibilityToggleIndependently() {
        let workspace = SessionWorkspace(sessionIDs: [SessionID()])

        workspace.setSidebarVisible(false)
        #expect(!workspace.isSidebarVisible)
        #expect(workspace.isFileBrowserVisible)

        workspace.setFileBrowserVisible(false)
        #expect(!workspace.isSidebarVisible)
        #expect(!workspace.isFileBrowserVisible)

        workspace.toggleFileBrowserVisibility()
        #expect(!workspace.isSidebarVisible)
        #expect(workspace.isFileBrowserVisible)

        workspace.toggleSidebarVisibility()
        #expect(workspace.isSidebarVisible)
        #expect(workspace.isFileBrowserVisible)
    }

    @Test func completeMergeSampleUsesSelectedSessionPresentation() throws {
        let first = SessionID()
        let selected = SessionID()
        let candidates = [
            SessionWorkspacePresentationMergePolicy.Candidate(
                sessionID: first,
                isSidebarVisible: true,
                isFileBrowserVisible: false
            ),
            SessionWorkspacePresentationMergePolicy.Candidate(
                sessionID: selected,
                isSidebarVisible: false,
                isFileBrowserVisible: true
            ),
        ]

        let resolved = try #require(
            SessionWorkspacePresentationMergePolicy.resolve(
                selectedSessionID: selected,
                candidates: candidates
            )
        )
        let reordered = try #require(
            SessionWorkspacePresentationMergePolicy.resolve(
                selectedSessionID: selected,
                candidates: Array(candidates.reversed())
            )
        )

        #expect(resolved == candidates[1])
        #expect(reordered == resolved)
    }

    @Test func invalidPresentationMergeCandidatesAreRejected() {
        let sessionID = SessionID()
        let candidate = SessionWorkspacePresentationMergePolicy.Candidate(
            sessionID: sessionID,
            isSidebarVisible: true,
            isFileBrowserVisible: true
        )

        #expect(SessionWorkspacePresentationMergePolicy.resolve(
            selectedSessionID: SessionID(),
            candidates: [candidate]
        ) == nil)
        #expect(SessionWorkspacePresentationMergePolicy.resolve(
            selectedSessionID: sessionID,
            candidates: [candidate, candidate]
        ) == nil)
    }

    @Test func adapterIgnoresTransientPartialNativeState() {
        let first = SessionID()
        let second = SessionID()
        let workspace = SessionWorkspace(
            sessionIDs: [first, second],
            selectedSessionID: second,
            isSidebarVisible: false
        )
        let adapter = NativeTabGroupAdapter(workspace: workspace)
        let before = workspace.snapshot

        let result = adapter.reconcile(
            .init(
                orderedSessionIDs: [first],
                selectedSessionID: first,
                reportedWindowCount: 1
            )
        )

        #expect(result == .ignoredIncomplete)
        #expect(workspace.snapshot == before)
    }

    @Test func adapterSynchronizesOnlyCompleteNativeState() {
        let first = SessionID()
        let second = SessionID()
        let workspace = SessionWorkspace(
            sessionIDs: [first, second],
            selectedSessionID: first
        )
        let adapter = NativeTabGroupAdapter(workspace: workspace)

        let result = adapter.reconcile(
            .init(
                orderedSessionIDs: [second, first],
                selectedSessionID: second
            )
        )

        #expect(result == .synchronized(changed: true))
        #expect(workspace.orderedSessionIDs == [second, first])
        #expect(workspace.selectedSessionID == second)
    }

    @Test func adapterPublishesBindingCreatedAfterWorkspaceMembership() {
        let sessionID = SessionID()
        let workspace = SessionWorkspace(sessionIDs: [sessionID])
        let adapter = NativeTabGroupAdapter(workspace: workspace)
        let window = NSWindow()
        let workspaceSnapshot = workspace.snapshot

        #expect(adapter.window(for: sessionID) == nil)
        #expect(adapter.bindingRevision == 0)

        #expect(adapter.register(window, as: sessionID))
        #expect(adapter.window(for: sessionID) === window)
        #expect(adapter.bindingRevision == 1)
        #expect(workspace.snapshot == workspaceSnapshot)
    }

    @Test func unloadedSessionTransfersBeforeItsNativeWindowBinds() {
        let sessionID = SessionID()
        let source = NativeTabGroupAdapter(
            workspace: SessionWorkspace(sessionIDs: [sessionID])
        )
        let destination = NativeTabGroupAdapter(
            workspace: SessionWorkspace()
        )

        #expect(source.transferSession(
            sessionID,
            window: nil,
            to: destination,
            select: true
        ))
        #expect(source.workspace.orderedSessionIDs.isEmpty)
        #expect(destination.workspace.orderedSessionIDs == [sessionID])
        #expect(destination.workspace.selectedSessionID == sessionID)
        #expect(destination.window(for: sessionID) == nil)

        let loadedWindow = NSWindow()
        #expect(destination.register(loadedWindow, as: sessionID))
        #expect(destination.window(for: sessionID) === loadedWindow)
        #expect(destination.workspace.orderedSessionIDs == [sessionID])
    }

    @Test func adapterRejectsDuplicateOrMissingNativeSelection() {
        let first = SessionID()
        let second = SessionID()
        let workspace = SessionWorkspace(sessionIDs: [first, second])
        let adapter = NativeTabGroupAdapter(workspace: workspace)
        let before = workspace.snapshot

        #expect(adapter.reconcile(
            .init(
                orderedSessionIDs: [first, first],
                selectedSessionID: first
            )
        ) == .ignoredIncomplete)
        #expect(adapter.reconcile(
            .init(
                orderedSessionIDs: [first, second],
                selectedSessionID: nil
            )
        ) == .ignoredInvalid)
        #expect(workspace.snapshot == before)
    }

    @Test func closingSessionCannotBeTransferredOrResurrected() {
        let closing = SessionID()
        let survivor = SessionID()
        let sourceWorkspace = SessionWorkspace(
            sessionIDs: [closing, survivor],
            selectedSessionID: closing
        )
        let source = NativeTabGroupAdapter(workspace: sourceWorkspace)
        let destination = NativeTabGroupAdapter(
            workspace: SessionWorkspace(sessionIDs: [survivor])
        )
        let closingWindow = NSWindow()
        #expect(source.register(closingWindow, as: closing))

        #expect(!source.transferSession(
            closing,
            window: closingWindow,
            to: destination,
            isClosing: true
        ))
        #expect(source.workspace.orderedSessionIDs == [closing, survivor])
        #expect(source.window(for: closing) === closingWindow)
        #expect(!destination.workspace.contains(closing))
    }

    @Test func rejectedTransferLeavesBothAdaptersUnchanged() {
        let sessionID = SessionID()
        let sourceWindow = NSWindow()
        let source = NativeTabGroupAdapter(
            workspace: SessionWorkspace(sessionIDs: [sessionID])
        )
        let destination = NativeTabGroupAdapter(
            workspace: SessionWorkspace(sessionIDs: [sessionID])
        )
        #expect(source.register(sourceWindow, as: sessionID))
        let sourceBefore = source.workspace.snapshot
        let destinationBefore = destination.workspace.snapshot

        #expect(!source.transferSession(
            sessionID,
            window: sourceWindow,
            to: destination
        ))
        #expect(source.workspace.snapshot == sourceBefore)
        #expect(destination.workspace.snapshot == destinationBefore)
        #expect(source.window(for: sessionID) === sourceWindow)
        #expect(destination.window(for: sessionID) == nil)
    }

    @Test func ascendingRollbackRestoresOrderAfterPartialMultiTransfer() {
        let first = SessionID()
        let second = SessionID()
        let third = SessionID()
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()
        let source = NativeTabGroupAdapter(
            workspace: SessionWorkspace(sessionIDs: [first, second, third])
        )
        let destination = NativeTabGroupAdapter(workspace: SessionWorkspace())
        #expect(source.register(firstWindow, as: first))
        #expect(source.register(secondWindow, as: second))

        #expect(destination.workspace.orderedSessionIDs.isEmpty)
        #expect(source.transferSession(first, window: firstWindow, to: destination))
        #expect(source.transferSession(second, window: secondWindow, to: destination))
        #expect(source.workspace.orderedSessionIDs == [third])

        // This is the rollback order used by TerminalController: lower original
        // positions must be restored first while an untransferred tail remains.
        #expect(destination.transferSession(first, window: firstWindow, to: source, at: 0))
        #expect(destination.transferSession(second, window: secondWindow, to: source, at: 1))
        #expect(source.workspace.orderedSessionIDs == [first, second, third])
        #expect(destination.workspace.orderedSessionIDs.isEmpty)
    }

    @Test func completePermanentDetachProducesIndependentSnapshots() {
        let first = SessionID()
        let second = SessionID()
        let third = SessionID()
        let adapter = NativeTabGroupAdapter(
            workspace: SessionWorkspace(
                sessionIDs: [first, second, third],
                selectedSessionID: second,
                isSidebarVisible: false,
                isFileBrowserVisible: false
            )
        )
        let topology = NativeTabGroupAdapter.NativeTopology(groups: [
            .init(
                orderedSessionIDs: [first],
                selectedSessionID: first
            ),
            .init(
                orderedSessionIDs: [second, third],
                selectedSessionID: third
            ),
        ])

        let snapshots = adapter.partitionSnapshots(for: topology)
        #expect(snapshots?.count == 2)
        #expect(snapshots?[0].orderedSessionIDs == [first])
        #expect(snapshots?[0].selectedSessionID == first)
        #expect(snapshots?[1].orderedSessionIDs == [second, third])
        #expect(snapshots?[1].selectedSessionID == third)
        #expect(snapshots?.allSatisfy { !$0.isSidebarVisible } == true)
        #expect(snapshots?.allSatisfy { !$0.isFileBrowserVisible } == true)
    }

    @Test func partialOrOverlappingDetachTopologyIsRejected() {
        let first = SessionID()
        let second = SessionID()
        let adapter = NativeTabGroupAdapter(
            workspace: SessionWorkspace(sessionIDs: [first, second])
        )

        #expect(adapter.partitionSnapshots(for: .init(groups: [
            .init(orderedSessionIDs: [first], selectedSessionID: first),
        ])) == nil)
        #expect(adapter.partitionSnapshots(for: .init(groups: [
            .init(orderedSessionIDs: [first], selectedSessionID: first),
            .init(orderedSessionIDs: [first, second], selectedSessionID: second),
        ])) == nil)
    }

    @Test func nativeAttachmentTransactionReportsRecoverySemantics() {
        var rollbackCount = 0
        let rolledBack = NativeTabAttachmentTransaction.perform(
            attach: { false },
            rollback: {
                rollbackCount += 1
                return true
            }
        )
        #expect(rolledBack == .rolledBack)
        #expect(rollbackCount == 1)

        let detached = NativeTabAttachmentTransaction.perform(
            attach: { false },
            rollback: { false }
        )
        #expect(detached == .detached)

        let attached = NativeTabAttachmentTransaction.perform(
            attach: { true },
            rollback: {
                Issue.record("rollback must not run after a successful attach")
                return false
            }
        )
        #expect(attached == .attached)
    }

    @Test func sidebarNativeMembersAreNeverFocusedAsStandaloneWindows() {
        #expect(
            NativeTabFocusPolicy.strategy(
                usesSessionSidebar: true,
                logicalSessionCount: 3,
                nativeWindowCount: 3,
                containsTarget: true
            ) == .selectNativeTab
        )
        #expect(
            NativeTabFocusPolicy.strategy(
                usesSessionSidebar: true,
                logicalSessionCount: 1,
                nativeWindowCount: 1,
                containsTarget: true
            ) == .orderWindow
        )
        #expect(
            NativeTabFocusPolicy.strategy(
                usesSessionSidebar: false,
                logicalSessionCount: 3,
                nativeWindowCount: 3,
                containsTarget: true
            ) == .orderWindow
        )
        #expect(
            NativeTabFocusPolicy.strategy(
                usesSessionSidebar: true,
                logicalSessionCount: 3,
                nativeWindowCount: 3,
                containsTarget: false
            ) == .reject
        )
        #expect(
            NativeTabFocusPolicy.strategy(
                usesSessionSidebar: true,
                logicalSessionCount: 3,
                nativeWindowCount: 1,
                containsTarget: true
            ) == .reject
        )
        #expect(
            NativeTabFocusPolicy.strategy(
                usesSessionSidebar: true,
                logicalSessionCount: 3,
                nativeWindowCount: 0,
                containsTarget: false
            ) == .reject
        )
    }

    @Test func groupedUndoRedoTracksNativeAndStandaloneRestorations() {
        final class RestoredController {}

        let nativeGroupRestore = RestoredController()
        let standaloneRestore = RestoredController()
        let restorations = SessionUndoRestorationSet<RestoredController>()

        restorations.insert(nativeGroupRestore)
        restorations.insert(standaloneRestore)
        restorations.insert(nativeGroupRestore)

        #expect(restorations.liveValues.count == 2)
        #expect(restorations.liveValues[0] === nativeGroupRestore)
        #expect(restorations.liveValues[1] === standaloneRestore)
    }

    @Test func permanentDetachRequiresStableCompleteResample() async {
        let first = SessionID()
        let second = SessionID()
        let adapter = NativeTabGroupAdapter(
            workspace: SessionWorkspace(sessionIDs: [first, second])
        )
        let detached = NativeTabGroupAdapter.NativeTopology(groups: [
            .init(orderedSessionIDs: [first], selectedSessionID: first),
            .init(orderedSessionIDs: [second], selectedSessionID: second),
        ])
        let stillGrouped = NativeTabGroupAdapter.NativeTopology(groups: [
            .init(
                orderedSessionIDs: [first, second],
                selectedSessionID: first
            ),
        ])
        var appliedTopologies: [NativeTabGroupAdapter.NativeTopology] = []

        adapter.schedulePartitionReconciliation(
            detached,
            resample: { stillGrouped },
            apply: { appliedTopologies.append($0) }
        )
        await nextMainQueueTurn()
        #expect(appliedTopologies.isEmpty)

        adapter.schedulePartitionReconciliation(
            detached,
            resample: { detached },
            apply: { appliedTopologies.append($0) }
        )
        await nextMainQueueTurn()
        #expect(appliedTopologies == [detached])
    }

    @Test func bindingMutationCancelsPendingPermanentDetach() async {
        let first = SessionID()
        let second = SessionID()
        let adapter = NativeTabGroupAdapter(
            workspace: SessionWorkspace(sessionIDs: [first, second])
        )
        let detached = NativeTabGroupAdapter.NativeTopology(groups: [
            .init(orderedSessionIDs: [first], selectedSessionID: first),
            .init(orderedSessionIDs: [second], selectedSessionID: second),
        ])
        var appliedTopologies: [NativeTabGroupAdapter.NativeTopology] = []

        adapter.schedulePartitionReconciliation(
            detached,
            resample: { detached },
            apply: { appliedTopologies.append($0) }
        )

        // A newly materialized native binding invalidates the topology sample
        // before its next-main-queue confirmation can partition the workspace.
        #expect(adapter.register(NSWindow(), as: first))
        await nextMainQueueTurn()

        #expect(appliedTopologies.isEmpty)
        #expect(adapter.workspace.orderedSessionIDs == [first, second])
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
