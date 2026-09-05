import AppKit
import Combine

/// An application-process-only projection of live terminal state. Nothing is
/// persisted, and neither terminal text nor agent instructions leave the app.
@MainActor
final class SessionAttentionCoordinator {
    static let shared = SessionAttentionCoordinator()

    private let controllers = NSHashTable<BaseTerminalController>.weakObjects()
    private var surfaces: [UUID: WeakSurface] = [:]
    private var reconciliationWork: DispatchWorkItem?
    private var notifications: Set<AnyCancellable> = []
    private var renderer: SessionAttentionDockRenderer?
    private var isStopped = false

    private struct WeakSurface {
        weak var value: Ghostty.SurfaceView?
    }

    private lazy var tracker = SessionAttentionTracker(
        makeSource: { [weak self] id in self?.makeSource(for: id) },
        isViewed: { [weak self] id in self?.isViewed(id) == true },
        countDidChange: { [weak self] count in self?.renderer?.update(count: count) }
    )

    private init() {
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.refreshVisibility() }
                .store(in: &notifications)
        }
    }

    func startRendering() {
        guard !isStopped, renderer == nil else { return }
        renderer = SessionAttentionDockRenderer()
        renderer?.update(count: tracker.count)
    }

    func refreshIcon() {
        renderer?.refreshIcon()
    }

    func register(_ controller: BaseTerminalController) {
        guard !isStopped else { return }
        controllers.add(controller)
        scheduleReconciliation()
    }

    func unregister(_ controller: BaseTerminalController) {
        controllers.remove(controller)
        scheduleReconciliation()
    }

    func surfacesDidChange() {
        scheduleReconciliation()
    }

    func refreshVisibility() {
        guard !isStopped else { return }
        tracker.refreshVisibility()
    }

    func stop() {
        isStopped = true
        reconciliationWork?.cancel()
        reconciliationWork = nil
        notifications.removeAll()
        controllers.removeAllObjects()
        surfaces.removeAll()
        tracker.stop()
        renderer?.stop()
        renderer = nil
    }

    private func scheduleReconciliation() {
        guard !isStopped, reconciliationWork == nil else { return }
        // Split transfers remove a surface from one tree before adding it to
        // another. Reconcile the final ownership once per main-loop turn so
        // those moves preserve unread state and reuse the existing monitor.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !isStopped else { return }
            reconciliationWork = nil
            reconcile()
        }
        reconciliationWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func reconcile() {
        var owners: [UUID: UUID] = [:]
        var liveSurfaces: [UUID: WeakSurface] = [:]
        for controller in controllers.allObjects {
            for surface in controller.surfaceTree {
                owners[surface.id] = controller.sessionAttentionID
                liveSurfaces[surface.id] = WeakSurface(value: surface)
            }
        }
        surfaces = liveSurfaces
        tracker.reconcile(owners: owners)
    }

    private func isViewed(_ id: UUID) -> Bool {
        guard NSApp.isActive, let surface = surfaces[id]?.value,
              let controller = BaseTerminalController.controller(owning: surface),
              controllers.contains(controller), controller.isWindowLoaded,
              let window = controller.window,
              window.isKeyWindow, window.isVisible, !window.isMiniaturized else { return false }
        return controller.focusedSurface === surface && surface.isFirstResponder
    }

    private func makeSource(for id: UUID) -> TerminalSessionMetadataMonitor? {
        guard let surface = surfaces[id]?.value else { return nil }
        let monitor = TerminalSessionMetadataMonitor()
        monitor.updateRefreshContext(
            sidebarIsVisible: false,
            sessionIsSelected: false,
            attentionIsEnabled: true
        )
        monitor.bind(
            to: surface,
            preserving: nil,
            contains: { $0 === surface },
            titleDidChange: { _, _ in }
        )
        return monitor
    }
}

extension TerminalSessionMetadataMonitor: SessionAttentionSource {
    var attentionUpdates: AnyPublisher<TerminalSessionActivitySnapshot, Never> {
        $activitySnapshot.eraseToAnyPublisher()
    }

    func startAttentionMonitoring() {
        TerminalSessionMetadataRefreshScheduler.shared.register(self)
    }

    func stopAttentionMonitoring() {
        stopMonitoring()
        TerminalSessionMetadataRefreshScheduler.shared.unregister(self)
    }
}
