import AppKit

/// Native macOS actions for a local file link selected in terminal output.
enum FlashTerminalFileActionMenu {
    private static let preparationQueue = DispatchQueue(
        label: "com.flashghostty.terminal-file-actions.prepare-menu",
        qos: .userInitiated
    )
    private static let applicationCache = FlashTerminalFileApplicationCache()

    static func resolveAndPresent(
        _ rawValue: String,
        workingDirectory: String?,
        sourceSurfaceID: UUID? = nil,
        onFailure: (@Sendable () -> Void)? = nil
    ) {
        let request = requestGate.begin()

        // Mouse location and source lookup are AppKit state. Capture them on
        // the main actor after returning from the renderer callback; a later
        // completion must still match the exact surface, controller, session,
        // and window snapshot.
        DispatchQueue.main.async { @MainActor in
            guard requestGate.isLatest(request) else { return }
            guard let sourceContext = FlashTerminalFileActionSourceContext.capture(
                sourceSurfaceID: sourceSurfaceID
            ), sourceContext.isCurrent else { return }
            prepareAndPresent(
                rawValue,
                workingDirectory: workingDirectory,
                screenPoint: NSEvent.mouseLocation,
                request: request,
                sourceContext: sourceContext,
                onFailure: onFailure
            )
        }
    }

    private static let requestGate = FlashTerminalFileActionRequestGate()

    @MainActor
    private static func prepareAndPresent(
        _ rawValue: String,
        workingDirectory: String?,
        screenPoint: NSPoint,
        request: FlashTerminalFileActionRequestGate.Request,
        sourceContext: FlashTerminalFileActionSourceContext,
        onFailure: (@Sendable () -> Void)?
    ) {
        preparationQueue.async {
            guard let target = FlashTerminalFileTargetResolver.resolve(
                rawValue,
                workingDirectory: workingDirectory
            ) else {
                if let onFailure {
                    DispatchQueue.main.async { @MainActor in
                        guard FlashTerminalFileMenuPresentationPolicy.shouldPresent(
                            isLatestRequest: requestGate.isLatest(request),
                            sourceState: sourceContext.currentState
                        ) else { return }
                        onFailure()
                    }
                }
                return
            }

            // The serial preparation queue can still be working on an older
            // click when a new click arrives. Avoid the more expensive Launch
            // Services work when this request has already been superseded.
            guard requestGate.isLatest(request) else { return }

            // Launch Services, bundle metadata, and application icon lookups
            // are synchronous. Prepare all of them away from the UI thread;
            // the main queue only constructs and displays native menu objects.
            let applicationMetadata = applicationCache.metadata(for: target)

            DispatchQueue.main.async { @MainActor in
                guard FlashTerminalFileMenuPresentationPolicy.shouldPresent(
                    isLatestRequest: requestGate.isLatest(request),
                    sourceState: sourceContext.currentState
                ) else { return }
                let terminalController = sourceContext.currentTerminalController
                let menu = makeMenu(
                    for: target,
                    applicationMetadata: applicationMetadata,
                    workingDirectory: workingDirectory,
                    terminalController: terminalController,
                    sourceContext: sourceContext
                )
                menu.popUp(positioning: nil, at: screenPoint, in: nil)
            }
        }
    }
}

private extension FlashTerminalFileActionMenu {
    @MainActor
    static func makeMenu(
        for target: FlashTerminalFileTarget,
        applicationMetadata: FlashTerminalFileApplicationMenuMetadata,
        workingDirectory: String?,
        terminalController: TerminalController?,
        sourceContext: FlashTerminalFileActionSourceContext
    ) -> NSMenu {
        let menu = NSMenu(title: target.lexicalURL.lastPathComponent)
        menu.autoenablesItems = false
        var hasOpenActions = false

        if target.openSafety == .allowed {
            if let defaultApplication = applicationMetadata.defaultApplication {
                let openItem = NSMenuItem(
                    title: "Open in \(defaultApplication.name)",
                    action: #selector(FlashTerminalFileActionHandler.openDefault(_:)),
                    keyEquivalent: ""
                )
                openItem.target = FlashTerminalFileActionHandler.shared
                openItem.representedObject = FlashTerminalFileActionPayload(
                    target: target,
                    applicationTarget: defaultApplication.target
                )
                openItem.toolTip = target.lexicalURL.path
                openItem.image = defaultApplication.icon
                menu.addItem(openItem)
                hasOpenActions = true
            }

            let alternatives = applicationMetadata.alternativeApplications
            if !alternatives.isEmpty {
                let openWithItem = NSMenuItem(
                    title: "Open With",
                    action: nil,
                    keyEquivalent: ""
                )
                let submenu = NSMenu(title: "Open With")
                submenu.autoenablesItems = false

                for application in alternatives {
                    let item = NSMenuItem(
                        title: application.name,
                        action: #selector(FlashTerminalFileActionHandler.openWith(_:)),
                        keyEquivalent: ""
                    )
                    item.target = FlashTerminalFileActionHandler.shared
                    item.representedObject = FlashTerminalFileActionPayload(
                        target: target,
                        applicationTarget: application.target
                    )
                    item.image = application.icon
                    submenu.addItem(item)
                }

                menu.addItem(openWithItem)
                menu.setSubmenu(submenu, for: openWithItem)
                hasOpenActions = true
            }
        }

        if hasOpenActions { menu.addItem(.separator()) }

        let revealDestination = FlashTerminalFileActionRevealPolicy.destination(
            for: target,
            workingDirectory: workingDirectory,
            fileBrowserAvailable: terminalController?.usesSessionSidebarTitlebar == true
        )
        let revealItem = NSMenuItem(
            title: revealDestination.title,
            action: revealDestination == .fileBrowser
                ? #selector(FlashTerminalFileActionHandler.showInFileBrowser(_:))
                : #selector(FlashTerminalFileActionHandler.revealInFinder(_:)),
            keyEquivalent: ""
        )
        revealItem.target = FlashTerminalFileActionHandler.shared
        revealItem.representedObject = FlashTerminalFileActionPayload(
            target: target,
            workingDirectoryURL: workingDirectory.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            },
            terminalController: terminalController,
            sourceContext: sourceContext
        )
        revealItem.toolTip = target.lexicalURL.path
        revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(revealItem)

        return menu
    }
}

enum FlashTerminalFileActionRevealDestination: Equatable, Sendable {
    case fileBrowser
    case finder

    var title: String {
        switch self {
        case .fileBrowser: return "Show in File Browser"
        case .finder: return "Show in Finder"
        }
    }
}

/// The session file browser is intentionally rooted at the shell working
/// directory. An absolute terminal link outside that boundary must fall back
/// to Finder instead of presenting an action guaranteed to be rejected.
enum FlashTerminalFileActionRevealPolicy {
    static func destination(
        for target: FlashTerminalFileTarget,
        workingDirectory: String?,
        fileBrowserAvailable: Bool
    ) -> FlashTerminalFileActionRevealDestination {
        guard
            fileBrowserAvailable,
            let workingDirectory,
            workingDirectory.hasPrefix("/")
        else { return .finder }

        let rootComponents = URL(fileURLWithPath: workingDirectory)
            .standardizedFileURL
            .pathComponents
        let targetComponents = target.lexicalURL
            .standardizedFileURL
            .pathComponents
        return targetComponents.starts(with: rootComponents)
            ? .fileBrowser
            : .finder
    }
}

/// AppKit image objects are created on the preparation queue and become
/// immutable before this value crosses to the main queue for menu assembly.
private struct FlashTerminalFileApplicationMetadata: @unchecked Sendable {
    let target: FlashTerminalFileApplicationTarget
    let name: String
    let icon: NSImage?

    var url: URL { target.applicationURL }
}

/// Pins both an application bundle and its effective executable while an Open
/// With menu is visible. Application associations may point into a user's
/// writable Applications directory, so retaining only the path would let a
/// same-path replacement change which program receives the document.
struct FlashTerminalFileApplicationTarget: Equatable, Sendable {
    let applicationURL: URL
    let executableURL: URL

    private let canonicalApplicationURL: URL
    private let canonicalExecutableURL: URL
    private let lexicalApplicationIdentity: FlashFilesystemIdentity
    private let canonicalApplicationIdentity: FlashFilesystemIdentity
    private let lexicalExecutableIdentity: FlashApplicationExecutableIdentity
    private let canonicalExecutableIdentity: FlashApplicationExecutableIdentity

    init?(applicationURL: URL, fileManager: FileManager = .default) {
        let normalizedApplicationURL = applicationURL.standardizedFileURL
        guard let executableURL = Bundle(url: normalizedApplicationURL)?.executableURL else {
            return nil
        }
        self.init(
            applicationURL: normalizedApplicationURL,
            executableURL: executableURL,
            fileManager: fileManager
        )
    }

    init?(
        applicationURL: URL,
        executableURL: URL,
        fileManager: FileManager = .default
    ) {
        let normalizedApplicationURL = applicationURL.standardizedFileURL
        let canonicalApplicationURL = normalizedApplicationURL.resolvingSymlinksInPath()
        let normalizedExecutableURL = executableURL.standardizedFileURL
        let canonicalExecutableURL = normalizedExecutableURL.resolvingSymlinksInPath()

        let applicationValues = try? canonicalApplicationURL.resourceValues(
            forKeys: [.isDirectoryKey]
        )
        let executableValues = try? canonicalExecutableURL.resourceValues(
            forKeys: [.isRegularFileKey]
        )
        guard
            applicationValues?.isDirectory == true,
            executableValues?.isRegularFile == true,
            fileManager.isExecutableFile(atPath: canonicalExecutableURL.path),
            let lexicalApplicationIdentity = FlashFilesystemIdentity(
                url: normalizedApplicationURL
            ),
            let canonicalApplicationIdentity = FlashFilesystemIdentity(
                url: canonicalApplicationURL
            ),
            let lexicalExecutableIdentity = FlashApplicationExecutableIdentity(
                url: normalizedExecutableURL
            ),
            let canonicalExecutableIdentity = FlashApplicationExecutableIdentity(
                url: canonicalExecutableURL
            )
        else { return nil }

        self.applicationURL = normalizedApplicationURL
        self.executableURL = normalizedExecutableURL
        self.canonicalApplicationURL = canonicalApplicationURL
        self.canonicalExecutableURL = canonicalExecutableURL
        self.lexicalApplicationIdentity = lexicalApplicationIdentity
        self.canonicalApplicationIdentity = canonicalApplicationIdentity
        self.lexicalExecutableIdentity = lexicalExecutableIdentity
        self.canonicalExecutableIdentity = canonicalExecutableIdentity
    }

    func revalidated(fileManager: FileManager = .default) -> Self? {
        guard let current = Self(
            applicationURL: applicationURL,
            fileManager: fileManager
        ), current == self else { return nil }
        return current
    }
}

/// Everything needed to construct the Launch Services part of the menu.
/// No filesystem, bundle, or workspace lookup is performed by `makeMenu`.
private struct FlashTerminalFileApplicationMenuMetadata: @unchecked Sendable {
    let defaultApplication: FlashTerminalFileApplicationMetadata?
    let alternativeApplications: [FlashTerminalFileApplicationMetadata]

    static let empty = FlashTerminalFileApplicationMenuMetadata(
        defaultApplication: nil,
        alternativeApplications: []
    )
}

/// A small, time-bounded cache for Launch Services associations and app
/// presentation metadata. File type is captured by the resolver off-main, so
/// repeated clicks on files of the same type avoid both type and app lookups.
private final class FlashTerminalFileApplicationCache: @unchecked Sendable {
    private struct AssociationKey: Hashable {
        let kind: FlashTerminalFileTarget.Kind
        let contentTypeIdentifier: String?
        let pathExtension: String
    }

    private struct AssociationEntry {
        let createdAt: Date
        let applicationURLs: [URL]
    }

    private struct ApplicationEntry {
        let createdAt: Date
        let metadata: FlashTerminalFileApplicationMetadata
    }

    private let lock = NSLock()
    private let associationLifetime: TimeInterval = 30
    private let applicationLifetime: TimeInterval = 300
    private let associationLimit = 64
    private let applicationLimit = 128

    private var associations: [AssociationKey: AssociationEntry] = [:]
    private var associationOrder: [AssociationKey] = []
    private var applications: [String: ApplicationEntry] = [:]
    private var applicationOrder: [String] = []

    func metadata(
        for target: FlashTerminalFileTarget,
        now: Date = Date(),
        workspace: NSWorkspace = .shared
    ) -> FlashTerminalFileApplicationMenuMetadata {
        guard target.openSafety == .allowed else { return .empty }

        let key = AssociationKey(
            kind: target.kind,
            contentTypeIdentifier: target.contentTypeIdentifier,
            pathExtension: target.canonicalURL.pathExtension.lowercased()
        )
        let applicationURLs: [URL]
        if let cached = cachedAssociation(for: key, now: now) {
            applicationURLs = cached
        } else {
            var seen = Set<String>()
            applicationURLs = workspace.urlsForApplications(toOpen: target.canonicalURL)
                .filter { url in
                    seen.insert(url.standardizedFileURL.path).inserted
                }
            storeAssociation(applicationURLs, for: key, now: now)
        }

        // A document may carry a per-file default application, so only the
        // compatible-app set is cached by type. Resolve the default for this
        // exact URL on every click (still on the preparation queue).
        let defaultURL = workspace.urlForApplication(toOpen: target.canonicalURL)
        let defaultPath = defaultURL?.standardizedFileURL.path
        let alternativeURLs = applicationURLs
            .filter { url in
                let path = url.standardizedFileURL.path
                return path != defaultPath
            }

        let defaultApplication = defaultURL.flatMap {
            applicationMetadata(for: $0, now: now, workspace: workspace)
        }
        let alternatives = alternativeURLs
            .compactMap { applicationMetadata(for: $0, now: now, workspace: workspace) }
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.url.path < rhs.url.path
            }
        let result = FlashTerminalFileApplicationMenuMetadata(
            defaultApplication: defaultApplication,
            alternativeApplications: alternatives
        )
        return result
    }

    private func applicationMetadata(
        for url: URL,
        now: Date,
        workspace: NSWorkspace
    ) -> FlashTerminalFileApplicationMetadata? {
        let normalizedURL = url.standardizedFileURL
        let path = normalizedURL.path
        if let cached = cachedApplication(for: path, now: now),
           cached.target.revalidated() != nil {
            return cached
        }

        guard let target = FlashTerminalFileApplicationTarget(
            applicationURL: normalizedURL
        ) else { return nil }

        let name: String
        if let bundle = Bundle(url: normalizedURL),
           let displayName = bundle.object(
               forInfoDictionaryKey: "CFBundleDisplayName"
           ) as? String,
           !displayName.isEmpty {
            name = displayName
        } else {
            name = normalizedURL.deletingPathExtension().lastPathComponent
        }

        let icon = (workspace.icon(forFile: path).copy() as? NSImage).map { image in
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        let result = FlashTerminalFileApplicationMetadata(
            target: target,
            name: name,
            icon: icon
        )
        storeApplication(result, for: path, now: now)
        return result
    }

    private func cachedAssociation(
        for key: AssociationKey,
        now: Date
    ) -> [URL]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = associations[key] else { return nil }
        guard now.timeIntervalSince(entry.createdAt) <= associationLifetime else {
            associations.removeValue(forKey: key)
            associationOrder.removeAll { $0 == key }
            return nil
        }
        return entry.applicationURLs
    }

    private func storeAssociation(
        _ applicationURLs: [URL],
        for key: AssociationKey,
        now: Date
    ) {
        lock.lock()
        defer { lock.unlock() }
        if associations[key] == nil {
            associationOrder.append(key)
        }
        associations[key] = AssociationEntry(
            createdAt: now,
            applicationURLs: applicationURLs
        )
        while associationOrder.count > associationLimit {
            associations.removeValue(forKey: associationOrder.removeFirst())
        }
    }

    private func cachedApplication(
        for path: String,
        now: Date
    ) -> FlashTerminalFileApplicationMetadata? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = applications[path] else { return nil }
        guard now.timeIntervalSince(entry.createdAt) <= applicationLifetime else {
            applications.removeValue(forKey: path)
            applicationOrder.removeAll { $0 == path }
            return nil
        }
        return entry.metadata
    }

    private func storeApplication(
        _ metadata: FlashTerminalFileApplicationMetadata,
        for path: String,
        now: Date
    ) {
        lock.lock()
        defer { lock.unlock() }
        if applications[path] == nil {
            applicationOrder.append(path)
        }
        applications[path] = ApplicationEntry(createdAt: now, metadata: metadata)
        while applicationOrder.count > applicationLimit {
            applications.removeValue(forKey: applicationOrder.removeFirst())
        }
    }
}

/// Revalidates a menu payload away from the main thread and delivers the
/// result back on the main queue. Completion always runs, including for stale
/// targets, which makes it impossible for callers to accidentally fall back to
/// the prevalidated target.
enum FlashTerminalFileActionExecutor {
    typealias Revalidator = @Sendable (
        FlashTerminalFileTarget
    ) -> FlashTerminalFileTarget?
    typealias Completion = @MainActor @Sendable (
        FlashTerminalFileTarget?
    ) -> Void
    typealias ApplicationRevalidator = @Sendable (
        FlashTerminalFileApplicationTarget
    ) -> FlashTerminalFileApplicationTarget?
    typealias OpenWithCompletion = @MainActor @Sendable (
        FlashTerminalFileTarget?,
        FlashTerminalFileApplicationTarget?
    ) -> Void

    private static let validationQueue = DispatchQueue(
        label: "com.flashghostty.terminal-file-actions.revalidate",
        qos: .userInitiated
    )

    static func revalidate(
        _ target: FlashTerminalFileTarget,
        queue: DispatchQueue? = nil,
        using revalidator: @escaping Revalidator = {
            FlashTerminalFileTargetResolver.revalidate($0)
        },
        completion: @escaping Completion
    ) {
        (queue ?? validationQueue).async {
            #if DEBUG
            waitForUITestRevalidationBarrierIfConfigured()
            #endif
            let current = revalidator(target)
            DispatchQueue.main.async { @MainActor in
                completion(current)
            }
        }
    }

    static func revalidateOpenWith(
        _ target: FlashTerminalFileTarget,
        application: FlashTerminalFileApplicationTarget,
        queue: DispatchQueue? = nil,
        using revalidator: @escaping Revalidator = {
            FlashTerminalFileTargetResolver.revalidate($0)
        },
        applicationUsing applicationRevalidator: @escaping ApplicationRevalidator = {
            $0.revalidated()
        },
        completion: @escaping OpenWithCompletion
    ) {
        (queue ?? validationQueue).async {
            let currentTarget = revalidator(target)
            let currentApplication = applicationRevalidator(application)
            DispatchQueue.main.async { @MainActor in
                completion(currentTarget, currentApplication)
            }
        }
    }

    #if DEBUG
    /// Gives UI automation a deterministic point at which to change split
    /// focus while the real filesystem revalidation remains in flight. The
    /// seam is inert unless the launched test app opts in with a fresh
    /// temporary directory.
    private static func waitForUITestRevalidationBarrierIfConfigured() {
        let environmentKey =
            "GHOSTTY_TEST_TERMINAL_FILE_REVALIDATION_BARRIER"
        let uiTestBundleIdentifier =
            FlashGhosttyProductProfile.uiTestBundleIdentifier
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              bundleIdentifier ==
                FlashGhosttyProductProfile.debugBundleIdentifier ||
                bundleIdentifier == uiTestBundleIdentifier ||
                bundleIdentifier.hasPrefix("\(uiTestBundleIdentifier).run-"),
              let directoryPath = ProcessInfo.processInfo
            .environment[environmentKey],
              !directoryPath.isEmpty else { return }

        let directory = URL(
            fileURLWithPath: directoryPath,
            isDirectory: true
        )
        let entered = directory.appendingPathComponent("entered")
        let resume = directory.appendingPathComponent("resume")
        let fileManager = FileManager.default
        _ = fileManager.createFile(
            atPath: entered.path,
            contents: Data()
        )

        let deadline = Date().addingTimeInterval(60)
        while !fileManager.fileExists(atPath: resume.path),
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if !fileManager.fileExists(atPath: resume.path) {
            _ = fileManager.createFile(
                atPath: directory.appendingPathComponent("timed-out").path,
                contents: Data()
            )
        }
    }
    #endif
}

private final class FlashTerminalFileActionPayload: NSObject, @unchecked Sendable {
    let target: FlashTerminalFileTarget
    let applicationTarget: FlashTerminalFileApplicationTarget?
    let workingDirectoryURL: URL?
    weak var terminalController: TerminalController?
    let sourceContext: FlashTerminalFileActionSourceContext?

    init(
        target: FlashTerminalFileTarget,
        applicationTarget: FlashTerminalFileApplicationTarget? = nil,
        workingDirectoryURL: URL? = nil,
        terminalController: TerminalController? = nil,
        sourceContext: FlashTerminalFileActionSourceContext? = nil
    ) {
        self.target = target
        self.applicationTarget = applicationTarget
        self.workingDirectoryURL = workingDirectoryURL
        self.terminalController = terminalController
        self.sourceContext = sourceContext
    }
}

@MainActor
private final class FlashTerminalFileActionHandler: NSObject {
    static let shared = FlashTerminalFileActionHandler()

    @objc func openDefault(_ sender: NSMenuItem) {
        open(sender)
    }

    @objc func openWith(_ sender: NSMenuItem) {
        open(sender)
    }

    private func open(_ sender: NSMenuItem) {
        guard
            let payload = sender.representedObject as? FlashTerminalFileActionPayload,
            let application = payload.applicationTarget
        else { return }

        FlashTerminalFileActionExecutor.revalidateOpenWith(
            payload.target,
            application: application
        ) { target, currentApplication in
            dispatchPrecondition(condition: .onQueue(.main))
            guard
                let target,
                target.openSafety == .allowed,
                let currentApplication
            else {
                NSSound.beep()
                return
            }

            // NSWorkspace accepts an application path rather than an open
            // descriptor. The identity check closes the menu-lifetime
            // replacement window, but Launch Services must still resolve the
            // path once more after this point.
            NSWorkspace.shared.open(
                [target.canonicalURL],
                withApplicationAt: currentApplication.applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                guard error != nil else { return }
                DispatchQueue.main.async {
                    NSSound.beep()
                }
            }
        }
    }

    @objc func revealInFinder(_ sender: NSMenuItem) {
        withRevalidatedTarget(from: sender) { _, target in
            NSWorkspace.shared.activateFileViewerSelecting([target.lexicalURL])
        }
    }

    @objc func showInFileBrowser(_ sender: NSMenuItem) {
        withRevalidatedTarget(from: sender) { payload, target in
            guard
                let sourceContext = payload.sourceContext,
                let terminalController =
                    sourceContext.fileBrowserRevealTerminalController,
                terminalController === payload.terminalController
            else { return }
            terminalController.requestRevealInFileBrowser(
                target.lexicalURL,
                workingDirectoryURL: payload.workingDirectoryURL
            )
        }
    }

    private func withRevalidatedTarget(
        from sender: NSMenuItem,
        perform: @escaping @MainActor @Sendable (
            FlashTerminalFileActionPayload,
            FlashTerminalFileTarget
        ) -> Void
    ) {
        guard let payload = sender.representedObject as? FlashTerminalFileActionPayload else {
            return
        }
        withRevalidatedTarget(payload, perform: perform)
    }

    private func withRevalidatedTarget(
        _ payload: FlashTerminalFileActionPayload,
        perform: @escaping @MainActor @Sendable (
            FlashTerminalFileActionPayload,
            FlashTerminalFileTarget
        ) -> Void
    ) {
        // Re-resolve immediately before acting so a symlink swap or permission
        // change while the menu is open cannot bypass the safety policy. The
        // filesystem work is synchronous, so it must never run on AppKit's
        // event thread.
        FlashTerminalFileActionExecutor.revalidate(payload.target) { current in
            dispatchPrecondition(condition: .onQueue(.main))
            guard let current else {
                NSSound.beep()
                return
            }
            perform(payload, current)
        }
    }
}
