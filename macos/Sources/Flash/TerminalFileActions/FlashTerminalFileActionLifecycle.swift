import AppKit

/// Thread-safe request generations prevent an older, slower Launch Services
/// query from presenting after a newer terminal-file request has started.
final class FlashTerminalFileActionRequestGate: @unchecked Sendable {
    struct Request: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0

    func begin() -> Request {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return Request(generation: generation)
    }

    func isLatest(_ request: Request) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request.generation == generation
    }
}

/// A testable projection of the AppKit ownership and selection state required
/// for a terminal-file menu to remain associated with its originating UI.
struct FlashTerminalFileActionSourceState: Equatable, Sendable {
    let surfaceIdentityMatches: Bool
    let focusedSurfaceMatches: Bool
    let sessionIsSelected: Bool
    let windowIdentityMatches: Bool
    let windowIsVisible: Bool
    let windowIsSelected: Bool
    let windowIsKey: Bool

    var isCurrent: Bool {
        surfaceIdentityMatches &&
            focusedSurfaceMatches &&
            sessionIsSelected &&
            windowIdentityMatches &&
            windowIsVisible &&
            windowIsSelected &&
            windowIsKey
    }

    /// Once the user chooses "Show in File Browser", moving focus to another
    /// split must not discard the already-issued reveal. Every ownership and
    /// session invariant remains required; only transient split focus is
    /// allowed to change while filesystem identity is revalidated.
    var isValidFileBrowserRevealSource: Bool {
        surfaceIdentityMatches &&
            sessionIsSelected &&
            windowIdentityMatches &&
            windowIsVisible &&
            windowIsSelected &&
            windowIsKey
    }
}

enum FlashTerminalFileMenuPresentationPolicy {
    /// An unscoped request has no session file-browser destination and retains
    /// the legacy Finder-only behavior. Scoped requests must still point at
    /// the exact active surface, session, and window captured at click time.
    static func shouldPresent(
        isLatestRequest: Bool,
        sourceState: FlashTerminalFileActionSourceState?
    ) -> Bool {
        isLatestRequest && (sourceState?.isCurrent ?? true)
    }
}

enum FlashTerminalFileActionSessionPolicy {
    /// Quick Terminal has no SessionWorkspace identity and should retain the
    /// Finder-only file menu. Regular terminal windows must still match the
    /// exact captured and selected session.
    static func isSelected(
        capturedSessionID: SessionWorkspace.SessionID?,
        currentSessionID: SessionWorkspace.SessionID?,
        selectedSessionID: SessionWorkspace.SessionID?
    ) -> Bool {
        guard let capturedSessionID else {
            return currentSessionID == nil && selectedSessionID == nil
        }
        return currentSessionID == capturedSessionID &&
            selectedSessionID == capturedSessionID
    }
}

/// Weakly pins the source UI without extending the lifetime of a closed
/// surface, terminal controller, or native window.
final class FlashTerminalFileActionSourceContext: @unchecked Sendable {
    private let isScoped: Bool
    private let sourceSurfaceID: UUID?
    private let sessionID: SessionWorkspace.SessionID?
    private weak var sourceSurface: Ghostty.SurfaceView?
    private weak var sourceController: BaseTerminalController?
    private weak var sourceWindow: NSWindow?

    @MainActor
    static func capture(sourceSurfaceID: UUID?) -> FlashTerminalFileActionSourceContext? {
        guard let sourceSurfaceID else {
            return FlashTerminalFileActionSourceContext()
        }
        guard
            let sourceSurface = (NSApp.delegate as? GhosttyAppDelegate)?
                .findSurface(forUUID: sourceSurfaceID),
            let sourceController = BaseTerminalController.controller(
                owning: sourceSurface
            ),
            let sourceWindow = sourceSurface.window,
            sourceWindow.windowController === sourceController
        else { return nil }

        return FlashTerminalFileActionSourceContext(
            sourceSurfaceID: sourceSurfaceID,
            sourceSurface: sourceSurface,
            sourceController: sourceController,
            sourceWindow: sourceWindow
        )
    }

    @MainActor
    var currentState: FlashTerminalFileActionSourceState? {
        guard isScoped else { return nil }
        guard
            let sourceSurfaceID,
            let sourceSurface,
            let sourceController,
            let sourceWindow
        else { return unavailableState }

        let owner = BaseTerminalController.controller(owning: sourceSurface)
        let terminalController = sourceController as? TerminalController
        let windowIsSelected: Bool
        if let tabGroup = sourceWindow.tabGroup {
            windowIsSelected = tabGroup.selectedWindow === sourceWindow
        } else {
            windowIsSelected = true
        }
        return FlashTerminalFileActionSourceState(
            surfaceIdentityMatches: sourceSurface.id == sourceSurfaceID &&
                owner === sourceController,
            focusedSurfaceMatches: sourceController.focusedSurface === sourceSurface,
            sessionIsSelected: FlashTerminalFileActionSessionPolicy.isSelected(
                capturedSessionID: sessionID,
                currentSessionID: terminalController?.sessionID,
                selectedSessionID:
                    terminalController?.sessionWorkspace.selectedSessionID
            ),
            windowIdentityMatches: sourceWindow.windowController === sourceController &&
                sourceSurface.window === sourceWindow,
            windowIsVisible: sourceWindow.isVisible,
            windowIsSelected: windowIsSelected,
            windowIsKey: sourceWindow.isKeyWindow
        )
    }

    @MainActor
    var isCurrent: Bool {
        currentState?.isCurrent ?? !isScoped
    }

    @MainActor
    var currentTerminalController: TerminalController? {
        guard isCurrent else { return nil }
        return sourceController as? TerminalController
    }

    @MainActor
    var fileBrowserRevealTerminalController: TerminalController? {
        guard
            currentState?.isValidFileBrowserRevealSource ?? !isScoped
        else { return nil }
        return sourceController as? TerminalController
    }

    private init() {
        self.isScoped = false
        self.sourceSurfaceID = nil
        self.sessionID = nil
    }

    private init(
        sourceSurfaceID: UUID,
        sourceSurface: Ghostty.SurfaceView,
        sourceController: BaseTerminalController,
        sourceWindow: NSWindow
    ) {
        self.isScoped = true
        self.sourceSurfaceID = sourceSurfaceID
        self.sessionID = (sourceController as? TerminalController)?.sessionID
        self.sourceSurface = sourceSurface
        self.sourceController = sourceController
        self.sourceWindow = sourceWindow
    }

    private var unavailableState: FlashTerminalFileActionSourceState {
        FlashTerminalFileActionSourceState(
            surfaceIdentityMatches: false,
            focusedSurfaceMatches: false,
            sessionIsSelected: false,
            windowIdentityMatches: false,
            windowIsVisible: false,
            windowIsSelected: false,
            windowIsKey: false
        )
    }
}
