import Cocoa
import Combine

/// Resolves one complete native-group sample independently of controller
/// iteration order: the selected session owns shared presentation state.
/// Candidate history across incremental AppKit group assembly is a separate
/// lifecycle concern and must already be intact when this policy is called.
enum SessionWorkspacePresentationMergePolicy {
    /// The workspace-level presentation redundantly archived by each native-tab
    /// controller. A complete native group can contain conflicting values after
    /// an interrupted write or when migrating a development build.
    struct Candidate: Equatable, Sendable {
        let sessionID: SessionWorkspace.SessionID
        let isSidebarVisible: Bool
        let isFileBrowserVisible: Bool
    }

    static func resolve(
        selectedSessionID: SessionWorkspace.SessionID,
        candidates: [Candidate]
    ) -> Candidate? {
        guard Set(candidates.map(\.sessionID)).count == candidates.count else {
            return nil
        }

        return candidates.first { $0.sessionID == selectedSessionID }
    }
}

/// Owns FLASH-Ghostty's application-level session workspace and keeps it in
/// sync with AppKit's native tab presentation.
///
/// `TerminalController` remains the AppKit lifecycle boundary. This object is
/// the single composition point for sidebar visibility, workspace adoption,
/// native-tab reconciliation, KVO, focus policy, and sidebar actions.
@MainActor
final class FlashSessionTabCoordinator {
    typealias SessionID = SessionWorkspace.SessionID

    private weak var owner: TerminalController?
    let usesSidebar: Bool
    let sessionID: SessionID
    private(set) var adapter: NativeTabGroupAdapter

    var workspace: SessionWorkspace { adapter.workspace }
    var isSidebarVisible: Bool { workspace.isSidebarVisible }
    var fileBrowserIsVisible: Bool { workspace.isFileBrowserVisible }
    private(set) var isClosing = false

    private weak var observedTabGroup: NSWindowTabGroup?
    private var windowsObservation: NSKeyValueObservation?
    private var selectedWindowObservation: NSKeyValueObservation?
    private var workspaceObservation: AnyCancellable?
    private var adapterObservation: AnyCancellable?
    private var lastSidebarVisibility: Bool?
    private var lastFileBrowserVisibility: Bool?

    init(sessionID: SessionID, usesSidebar: Bool) {
        self.sessionID = sessionID
        self.usesSidebar = usesSidebar
        self.adapter = NativeTabGroupAdapter(
            workspace: SessionWorkspace(
                sessionIDs: [sessionID],
                selectedSessionID: sessionID
            )
        )
    }

    func attach(to owner: TerminalController) {
        precondition(self.owner == nil || self.owner === owner)
        self.owner = owner
        bindWorkspaceObservation()
    }

    /// Terminal controllers in stable workspace order. Missing native bindings
    /// are ignored without removing their identities from the workspace.
    var controllers: [TerminalController] {
        guard let owner else { return [] }
        let resolved = workspace.orderedSessionIDs.compactMap {
            adapter.window(for: $0)?.windowController as? TerminalController
        }
        return resolved.isEmpty ? [owner] : resolved
    }

    /// AppKit can briefly report a nil or single-window group while moving its
    /// native tab accessory. Retain a known-complete group for that transient.
    func resolvedTabGroup(for window: NSWindow) -> NSWindowTabGroup? {
        let liveTabGroup = window.tabGroup
        if let liveTabGroup, liveTabGroup.windows.count > 1 {
            return liveTabGroup
        }

        let cachedGroups = [adapter.lastCompleteTabGroup, observedTabGroup]
            .compactMap { $0 }
        if let completeGroup = cachedGroups.first(where: {
            $0.windows.count == workspace.sessionCount &&
                $0.windows.contains(where: { $0 === window })
        }) {
            return completeGroup
        }

        return liveTabGroup
    }

    private func bindWorkspaceObservation() {
        workspaceObservation = workspace.$snapshot
            .sink { [weak self] snapshot in
                guard let self, let owner else { return }

                let visibilityChanged = lastSidebarVisibility != nil &&
                    lastSidebarVisibility != snapshot.isSidebarVisible
                let fileBrowserVisibilityChanged = lastFileBrowserVisibility != nil &&
                    lastFileBrowserVisibility != snapshot.isFileBrowserVisible
                lastSidebarVisibility = snapshot.isSidebarVisible
                lastFileBrowserVisibility = snapshot.isFileBrowserVisible
                owner.flashSessionWorkspaceDidPublish(snapshot)

                guard visibilityChanged || fileBrowserVisibilityChanged else { return }
                guard owner.isWindowLoaded else { return }
                updateInitialContentSize(for: snapshot)
                if visibilityChanged {
                    (owner.window as? TerminalWindow)?
                        .sessionSidebarVisibilityDidChange(
                            isVisible: snapshot.isSidebarVisible
                        )
                }
            }

        adapterObservation = adapter.$bindingRevision
            .sink { [weak self] _ in
                self?.owner?.flashSessionSidebarRevisionDidChange()
            }
    }

    private struct WorkspaceMembership {
        let controller: TerminalController
        let adapter: NativeTabGroupAdapter
        let index: Int
        let selectedSessionID: SessionID?
    }

    /// Transfers the owner into an existing logical workspace. The adapter
    /// performs destination-first mutation so a rejected transfer is atomic.
    @discardableResult
    func adoptWorkspace(
        _ destination: NativeTabGroupAdapter,
        at index: Int? = nil,
        select: Bool = false
    ) -> Bool {
        guard let owner, !isClosing else { return false }

        let previousVisibility = isSidebarVisible
        let previousFileBrowserVisibility = fileBrowserIsVisible
        let source = adapter
        // NSWindowController.window is lazy. New tabs and undo restorations
        // intentionally adopt their logical workspace before loading the
        // SwiftUI root; forcing the window here briefly materializes a
        // singleton sidebar and can leave that stale list on screen.
        let loadedWindow = owner.isWindowLoaded ? owner.window : nil
        guard source.transferSession(
            sessionID,
            window: loadedWindow,
            to: destination,
            at: index,
            select: select,
            isClosing: isClosing
        ) else { return false }

        guard source !== destination else { return true }

        adapter = destination
        lastSidebarVisibility = previousVisibility
        lastFileBrowserVisibility = previousFileBrowserVisibility
        bindWorkspaceObservation()
        return true
    }

    @discardableResult
    func becomeIndependent(
        isSidebarVisible: Bool,
        isFileBrowserVisible: Bool
    ) -> Bool {
        adoptWorkspace(
            NativeTabGroupAdapter(
                workspace: SessionWorkspace(
                    isSidebarVisible: isSidebarVisible,
                    isFileBrowserVisible: isFileBrowserVisible
                )
            ),
            select: true
        )
    }

    private static func restoreMemberships(_ memberships: [WorkspaceMembership]) {
        for membership in memberships.sorted(by: { $0.index < $1.index })
        where membership.controller.flashSessionTabCoordinator.adapter !== membership.adapter {
            _ = membership.controller.flashSessionTabCoordinator.adoptWorkspace(
                membership.adapter,
                at: membership.index
            )
        }

        var restoredAdapters = Set<ObjectIdentifier>()
        for membership in memberships {
            let adapterID = ObjectIdentifier(membership.adapter)
            guard restoredAdapters.insert(adapterID).inserted,
                  let selectedSessionID = membership.selectedSessionID else { continue }
            _ = membership.adapter.workspace.selectSession(selectedSessionID)
        }
    }

    /// Joins independently-created controllers into one workspace only when
    /// the native group completely covers all participating workspaces.
    @discardableResult
    private func mergeWorkspaces(in tabGroup: NSWindowTabGroup) -> Bool {
        let windows = tabGroup.windows
        let controllers = windows.compactMap {
            $0.windowController as? TerminalController
        }
        guard controllers.count == windows.count,
              !controllers.isEmpty,
              controllers.allSatisfy({
                  let coordinator = $0.flashSessionTabCoordinator
                  return coordinator.usesSidebar && !coordinator.isClosing
              }) else { return false }

        let nativeSessionIDs = controllers.map(\.sessionID)
        let participatingSessionIDs = Set(controllers.flatMap {
            $0.sessionWorkspace.orderedSessionIDs
        })
        guard Set(nativeSessionIDs).count == nativeSessionIDs.count,
              Set(nativeSessionIDs) == participatingSessionIDs,
              let selectedSessionID = tabGroup.selectedWindow.flatMap({
                  ($0.windowController as? TerminalController)?.sessionID
              }),
              nativeSessionIDs.contains(selectedSessionID) else {
            return false
        }

        let adapters = controllers.map(\.sessionTabGroupAdapter)
        let uniqueAdapters = Dictionary(
            grouping: adapters,
            by: ObjectIdentifier.init
        ).compactMap(\.value.first)

        if uniqueAdapters.count == 1,
           let adapter = uniqueAdapters.first,
           Set(adapter.workspace.orderedSessionIDs) == Set(nativeSessionIDs) {
            adapter.cancelPendingPartitionReconciliation()
            return true
        }

        guard let presentation = SessionWorkspacePresentationMergePolicy.resolve(
            selectedSessionID: selectedSessionID,
            candidates: controllers.map {
                SessionWorkspacePresentationMergePolicy.Candidate(
                    sessionID: $0.sessionID,
                    isSidebarVisible: $0.sessionSidebarIsVisible,
                    isFileBrowserVisible: $0.fileBrowserIsVisible
                )
            }
        ) else { return false }
        let mergedAdapter = NativeTabGroupAdapter(
            workspace: SessionWorkspace(
                isSidebarVisible: presentation.isSidebarVisible,
                isFileBrowserVisible: presentation.isFileBrowserVisible
            )
        )
        let memberships = controllers.compactMap { controller -> WorkspaceMembership? in
            guard let index = controller.sessionWorkspace.orderedSessionIDs
                .firstIndex(of: controller.sessionID) else { return nil }
            return WorkspaceMembership(
                controller: controller,
                adapter: controller.sessionTabGroupAdapter,
                index: index,
                selectedSessionID: controller.sessionWorkspace.selectedSessionID
            )
        }
        guard memberships.count == controllers.count else { return false }

        for (index, controller) in controllers.enumerated() {
            guard controller.flashSessionTabCoordinator.adoptWorkspace(
                mergedAdapter,
                at: index,
                select: controller.sessionID == selectedSessionID
            ) else {
                Self.restoreMemberships(memberships)
                return false
            }
        }

        _ = mergedAdapter.reconcile(
            .init(
                orderedSessionIDs: nativeSessionIDs,
                selectedSessionID: selectedSessionID,
                reportedWindowCount: windows.count
            )
        )
        return true
    }

    private struct NativeWorkspaceTopologySample {
        struct Group {
            let controllers: [TerminalController]
            let selectedSessionID: SessionID
        }

        let topology: NativeTabGroupAdapter.NativeTopology
        let groups: [Group]
    }

    private enum NativeTopologyGroupKey: Hashable {
        case tabGroup(ObjectIdentifier)
        case standalone(SessionID)
    }

    /// Samples every native group for one complete logical workspace. Partial,
    /// duplicated, closing, fullscreen, and cross-adapter samples are rejected.
    private static func nativeTopologySample(
        for adapter: NativeTabGroupAdapter
    ) -> NativeWorkspaceTopologySample? {
        let workspaceIDs = adapter.workspace.orderedSessionIDs
        guard workspaceIDs.count > 1 else { return nil }

        var groups: [NativeTopologyGroupKey: NativeWorkspaceTopologySample.Group] = [:]
        for sessionID in workspaceIDs {
            guard let window = adapter.window(for: sessionID),
                  let controller = window.windowController as? TerminalController,
                  controller.sessionID == sessionID,
                  controller.sessionTabGroupAdapter === adapter,
                  controller.flashSessionTabCoordinator.usesSidebar,
                  !controller.flashSessionTabCoordinator.isClosing,
                  controller.fullscreenStyle?.isFullscreen != true,
                  !window.styleMask.contains(.fullScreen) else { return nil }

            guard let tabGroup = window.tabGroup else {
                groups[.standalone(sessionID)] = .init(
                    controllers: [controller],
                    selectedSessionID: sessionID
                )
                continue
            }

            let key = NativeTopologyGroupKey.tabGroup(ObjectIdentifier(tabGroup))
            if groups[key] != nil { continue }

            let nativeControllers = tabGroup.windows.compactMap {
                $0.windowController as? TerminalController
            }
            guard !nativeControllers.isEmpty,
                  nativeControllers.count == tabGroup.windows.count,
                  nativeControllers.allSatisfy({ member in
                      guard let memberWindow = member.window else { return false }
                      let coordinator = member.flashSessionTabCoordinator
                      return coordinator.adapter === adapter &&
                          coordinator.usesSidebar &&
                          !coordinator.isClosing &&
                          member.fullscreenStyle?.isFullscreen != true &&
                          !memberWindow.styleMask.contains(.fullScreen) &&
                          memberWindow.tabGroup === tabGroup
                  }),
                  tabGroup.windows.contains(where: { $0 === window }) else { return nil }

            let selectedSessionID: SessionID
            if let selectedController = tabGroup.selectedWindow?.windowController
                as? TerminalController {
                selectedSessionID = selectedController.sessionID
            } else if nativeControllers.count == 1 {
                selectedSessionID = nativeControllers[0].sessionID
            } else {
                return nil
            }
            groups[key] = .init(
                controllers: nativeControllers,
                selectedSessionID: selectedSessionID
            )
        }

        let workspaceIndex = Dictionary(
            uniqueKeysWithValues: workspaceIDs.enumerated().map { ($1, $0) }
        )
        let orderedGroups = groups.values.sorted { lhs, rhs in
            let lhsIndex = lhs.controllers.compactMap {
                workspaceIndex[$0.sessionID]
            }.min() ?? Int.max
            let rhsIndex = rhs.controllers.compactMap {
                workspaceIndex[$0.sessionID]
            }.min() ?? Int.max
            return lhsIndex < rhsIndex
        }
        let topology = NativeTabGroupAdapter.NativeTopology(
            groups: orderedGroups.map { group in
                .init(
                    orderedSessionIDs: group.controllers.map(\.sessionID),
                    selectedSessionID: group.selectedSessionID
                )
            }
        )
        guard adapter.partitionSnapshots(for: topology) != nil else { return nil }
        return .init(topology: topology, groups: orderedGroups)
    }

    private func requestStablePartition(for adapter: NativeTabGroupAdapter) {
        guard !isClosing,
              self.adapter === adapter,
              let candidate = Self.nativeTopologySample(for: adapter),
              candidate.groups.count > 1 else { return }

        adapter.schedulePartitionReconciliation(
            candidate.topology,
            resample: { [weak self, weak adapter] in
                guard let self, let adapter,
                      !self.isClosing,
                      self.adapter === adapter else { return nil }
                return Self.nativeTopologySample(for: adapter)?.topology
            },
            apply: { [weak self, weak adapter] topology in
                guard let self, let adapter,
                      !self.isClosing,
                      self.adapter === adapter,
                      let confirmed = Self.nativeTopologySample(for: adapter),
                      confirmed.topology == topology else { return }
                self.applyStablePartition(confirmed, from: adapter)
            }
        )
    }

    private func applyStablePartition(
        _ sample: NativeWorkspaceTopologySample,
        from sourceAdapter: NativeTabGroupAdapter
    ) {
        guard let snapshots = sourceAdapter.partitionSnapshots(for: sample.topology),
              snapshots.count == sample.groups.count,
              snapshots.count > 1 else { return }

        let controllers = sample.groups.flatMap(\.controllers)
        let memberships = controllers.compactMap { controller -> WorkspaceMembership? in
            guard controller.sessionTabGroupAdapter === sourceAdapter,
                  let index = sourceAdapter.workspace.orderedSessionIDs
                    .firstIndex(of: controller.sessionID) else { return nil }
            return .init(
                controller: controller,
                adapter: sourceAdapter,
                index: index,
                selectedSessionID: sourceAdapter.workspace.selectedSessionID
            )
        }
        guard memberships.count == controllers.count else { return }

        for (group, snapshot) in zip(sample.groups, snapshots) {
            let partitionAdapter = NativeTabGroupAdapter(
                workspace: SessionWorkspace(
                    isSidebarVisible: snapshot.isSidebarVisible,
                    isFileBrowserVisible: snapshot.isFileBrowserVisible
                )
            )
            for (index, controller) in group.controllers.enumerated() {
                guard controller.flashSessionTabCoordinator.adoptWorkspace(
                    partitionAdapter,
                    at: index,
                    select: controller.sessionID == snapshot.selectedSessionID
                ) else {
                    Self.restoreMemberships(memberships)
                    return
                }
            }
            _ = partitionAdapter.reconcile(
                .init(
                    orderedSessionIDs: snapshot.orderedSessionIDs,
                    selectedSessionID: snapshot.selectedSessionID
                )
            )
        }

        for controller in controllers {
            controller.flashSessionTabCoordinator.setupObservation()
            controller.invalidateRestorableState()
        }
    }

    /// The native attachment is permanently absent. Preserve the session as a
    /// standalone workspace instead of deleting it from the logical model.
    func nativeAttachmentDidFail() {
        guard usesSidebar, !isClosing, let owner else { return }
        let visibility = isSidebarVisible
        let fileBrowserVisibility = fileBrowserIsVisible
        if becomeIndependent(
            isSidebarVisible: visibility,
            isFileBrowserVisible: fileBrowserVisibility
        ) {
            setupObservation()
            owner.invalidateRestorableState()
        }
    }

    func toggleSidebar() {
        guard usesSidebar else { return }
        synchronizeVisibility(!isSidebarVisible)

        DispatchQueue.main.async { [weak self] in
            self?.restoreTerminalFocusAfterToggle()
        }
    }

    func synchronizeVisibility(
        _ isVisible: Bool,
        invalidateSavedState: Bool = true
    ) {
        guard isSidebarVisible != isVisible else { return }

        workspace.setSidebarVisible(isVisible)
        if invalidateSavedState {
            for controller in controllers {
                controller.invalidateRestorableState()
            }
        }
    }

    func toggleFileBrowser() {
        guard usesSidebar else { return }
        synchronizeFileBrowserVisibility(!fileBrowserIsVisible)

        DispatchQueue.main.async { [weak self] in
            self?.restoreTerminalFocusAfterToggle()
        }
    }

    func synchronizeFileBrowserVisibility(
        _ isVisible: Bool,
        invalidateSavedState: Bool = true
    ) {
        guard fileBrowserIsVisible != isVisible else { return }

        workspace.setFileBrowserVisible(isVisible)
        if invalidateSavedState {
            for controller in controllers {
                controller.invalidateRestorableState()
            }
        }
    }

    private func updateInitialContentSize(
        for snapshot: SessionWorkspace.Snapshot
    ) {
        guard usesSidebar,
              let owner,
              owner.isWindowLoaded,
              let container = owner.terminalViewContainer,
              var initialContentSize = owner.focusedSurface?.initialSize else { return }

        initialContentSize.width += TerminalSessionRootView.sidebarChromeWidth(
            isVisible: snapshot.isSidebarVisible
        )
        initialContentSize.width += TerminalSessionRootView.fileBrowserChromeWidth(
            isVisible: snapshot.isFileBrowserVisible
        )
        initialContentSize.height += TerminalSessionRootView.terminalMetadataHeight
        container.initialContentSize = initialContentSize
        container.invalidateIntrinsicContentSize()
    }

    private func restoreTerminalFocusAfterToggle() {
        guard let hostWindow = owner?.window else { return }
        let selectedWindow = resolvedTabGroup(for: hostWindow)?.selectedWindow ?? hostWindow
        guard selectedWindow.isKeyWindow,
              let selectedController = selectedWindow.windowController as? TerminalController,
              let focusedSurface = selectedController.focusedSurface else { return }
        selectedWindow.makeFirstResponder(focusedSurface)
    }

    func select(_ target: TerminalController) {
        guard let targetWindow = target.window else { return }
        _ = selectNativeWindow(targetWindow)
    }

    func isSelected(_ target: TerminalController) -> Bool {
        workspace.selectedSessionID == target.sessionID
    }

    @discardableResult
    func selectNativeWindow(_ targetWindow: NSWindow) -> Bool {
        guard let owner, let hostWindow = owner.window else { return false }
        if hostWindow === targetWindow, hostWindow.tabGroup == nil {
            return workspace.selectSession(sessionID)
        }

        guard let tabGroup = resolvedTabGroup(for: hostWindow),
              tabGroup.windows.contains(where: { $0 === targetWindow }),
              let targetController = targetWindow.windowController as? TerminalController else {
            return false
        }

        return adapter.selectSession(targetController.sessionID, in: tabGroup)
    }

    /// Select through a native group when required, rather than ordering one
    /// tab window independently and risking an AppKit detach.
    @discardableResult
    func focusSafely(
        _ targetWindow: NSWindow,
        in confirmedTabGroup: NSWindowTabGroup? = nil
    ) -> Bool {
        let targetController = targetWindow.windowController as? TerminalController
        let targetCoordinator = targetController?.flashSessionTabCoordinator
        let targetUsesSidebar = targetCoordinator?.usesSidebar ?? usesSidebar
        let resolvedTargetGroup: NSWindowTabGroup?
        if targetUsesSidebar, let targetCoordinator {
            resolvedTargetGroup = targetCoordinator.resolvedTabGroup(for: targetWindow)
        } else {
            resolvedTargetGroup = targetWindow.tabGroup
        }
        let tabGroup: NSWindowTabGroup?
        if let confirmedTabGroup,
           confirmedTabGroup.windows.contains(where: { $0 === targetWindow }) {
            tabGroup = confirmedTabGroup
        } else {
            tabGroup = resolvedTargetGroup
        }
        let windows = tabGroup?.windows ?? []
        let strategy = NativeTabFocusPolicy.strategy(
            usesSessionSidebar: targetUsesSidebar,
            logicalSessionCount: targetCoordinator?.workspace.sessionCount ?? workspace.sessionCount,
            nativeWindowCount: windows.count,
            containsTarget: windows.contains(where: { $0 === targetWindow })
        )

        switch strategy {
        case .selectNativeTab:
            guard let tabGroup, let targetCoordinator else { return false }
            return targetCoordinator.adapter.selectSession(
                targetCoordinator.sessionID,
                in: tabGroup
            )
        case .orderWindow:
            targetWindow.makeKeyAndOrderFront(nil)
            return true
        case .reject:
            return false
        }
    }

    func metadataDidChange() {
        guard usesSidebar else { return }
        owner?.flashSessionSidebarRevisionDidChange()
    }

    func close(_ target: TerminalController) {
        performAction(on: target) { target.closeTab(nil) }
    }

    func rename(_ target: TerminalController) {
        performAction(on: target) { target.promptTabTitle() }
    }

    func setName(_ target: TerminalController, name: String) {
        target.updateTitleOverride(name)
        for controller in controllers {
            controller.flashSessionSidebarRevisionDidChange()
        }
    }

    func restoreTerminalFocusAfterRename() {
        guard let owner,
              let window = owner.window,
              window.isKeyWindow,
              let focusedSurface = owner.focusedSurface else { return }
        window.makeFirstResponder(focusedSurface)
    }

    func closeOthers(_ target: TerminalController) {
        performAction(on: target) { target.closeOtherTabs(nil) }
    }

    func closeToRight(_ target: TerminalController) {
        performAction(on: target) { target.closeTabsOnTheRight(nil) }
    }

    private func performAction(
        on target: TerminalController,
        _ action: @MainActor @Sendable @escaping () -> Void
    ) {
        guard let hostWindow = owner?.window,
              let targetWindow = target.window else { return }

        let targetIsSelected = hostWindow.tabGroup?.selectedWindow === targetWindow ||
            (hostWindow === targetWindow && hostWindow.tabGroup == nil)
        if targetIsSelected {
            action()
        } else if selectNativeWindow(targetWindow) {
            Task { @MainActor in action() }
        }
    }

    func setupObservation() {
        guard usesSidebar, !isClosing else { return }
        updateObservation()
    }

    private func updateObservation() {
        guard usesSidebar, !isClosing, let window = owner?.window else { return }
        let currentTabGroup = resolvedTabGroup(for: window)
        bindObservation(to: currentTabGroup)
        reconcile(currentTabGroup, fallbackWindow: window)
    }

    func bindObservation(to tabGroup: NSWindowTabGroup?) {
        let observationsValid = tabGroup == nil ||
            (windowsObservation != nil && selectedWindowObservation != nil)
        guard observedTabGroup !== tabGroup || !observationsValid else { return }

        windowsObservation?.invalidate()
        windowsObservation = nil
        selectedWindowObservation?.invalidate()
        selectedWindowObservation = nil
        observedTabGroup = tabGroup

        windowsObservation = tabGroup?.observe(\.windows, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isClosing else { return }
                self.updateObservation()
            }
        }

        selectedWindowObservation = tabGroup?.observe(\.selectedWindow, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isClosing else { return }
                self.updateObservation()
            }
        }
    }

    /// Reconciliation accepts only a complete native state. It never creates
    /// or deletes logical workspace membership from a transient KVO sample.
    func reconcile(
        _ tabGroup: NSWindowTabGroup?,
        fallbackWindow: NSWindow? = nil
    ) {
        guard usesSidebar, !isClosing else { return }

        let windows = tabGroup?.windows ?? fallbackWindow.map { [$0] } ?? []
        if let tabGroup {
            if mergeWorkspaces(in: tabGroup) {
                adapter.cancelPendingPartitionReconciliation()
                _ = adapter.reconcile(tabGroup)
            } else {
                requestStablePartition(for: adapter)
            }
        } else {
            requestStablePartition(for: adapter)
        }

        for case let tabWindow as TerminalWindow in windows {
            tabWindow.syncSessionSidebarTabBarAccessoryVisibility()
            tabWindow.sessionSidebarTabSelectionDidChange(in: tabGroup)
        }
    }

    func register(window: NSWindow) {
        guard usesSidebar else { return }
        _ = adapter.register(
            window,
            as: sessionID,
            select: workspace.selectedSessionID == sessionID
        )
    }

    /// Marks the logical session as closing before AppKit starts mutating the
    /// native group, preventing synchronous KVO from re-adopting it.
    func beginClosing(window: NSWindow?) {
        isClosing = true
        workspaceObservation?.cancel()
        workspaceObservation = nil
        adapterObservation?.cancel()
        adapterObservation = nil
        windowsObservation?.invalidate()
        windowsObservation = nil
        selectedWindowObservation?.invalidate()
        selectedWindowObservation = nil
        observedTabGroup = nil
        adapter.cancelPendingPartitionReconciliation()
        if usesSidebar, let window {
            _ = adapter.unregister(window)
        }
    }
}
