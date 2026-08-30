import Cocoa

protocol TerminalRestorable: Codable {
    static var selfKey: String { get }
    static var versionKey: String { get }
    static var version: Int { get }
    /// Minimum version that can be decoded safely
    static var minimumVersion: Int { get }
    init(copy other: Self)

    /// Returns a base configuration to use when restoring terminal surfaces.
    /// Override this to provide custom environment variables or other configuration.
    var baseConfig: Ghostty.SurfaceConfiguration? { get }
}

extension TerminalRestorable {
    static var minimumVersion: Int { version }
}

extension TerminalRestorable {
    static var selfKey: String { "state" }
    static var versionKey: String { "version" }

    private var debugDescription: String {
        withUnsafePointer(to: self) { ptr in
            "<\(ptr)>[version: \(Self.version)]"
        }
    }

    /// Default implementation returns nil (no custom base config).
    var baseConfig: Ghostty.SurfaceConfiguration? { nil }

    init?(coder aDecoder: NSCoder) {
        guard let snapshot = TerminalRestorableSnapshot<Self>(coder: aDecoder),
              let value = snapshot.decodedValue() else { return nil }
        self.init(copy: value)
    }

    func encode(with coder: NSCoder) {
        coder.encode(Self.version, forKey: Self.versionKey)
        coder.encode(CodableBridge(self), forKey: Self.selfKey)

        AppDelegate.logger.debug("saved terminal state: \(debugDescription, privacy: .public)")
    }
}

/// The state stored for terminal window restoration.
final class TerminalRestorableState: TerminalRestorable {
    // Versions 9 and 10 were used by FLASH development builds while the
    // file-browser payload was being consolidated. Keep the version monotonic
    // so those archives reach InternalState's migration decoder.
    static var version: Int { 11 }
    static var minimumVersion: Int { 5 }

    var focusedSurface: String? {
        internalState.focusedSurface
    }
    var surfaceTree: SplitTree<Ghostty.SurfaceView> {
        internalState.surfaceTree
    }
    var effectiveFullscreenMode: FullscreenMode? {
        internalState.effectiveFullscreenMode
    }
    var tabColor: TerminalTabColor? {
        internalState.tabColor
    }
    var titleOverride: String? {
        internalState.titleOverride
    }
    var sessionSidebarIsVisible: Bool {
        internalState.sessionSidebarIsVisible ?? true
    }
    var fileBrowserIsVisible: Bool {
        internalState.fileBrowser?.isVisible ?? true
    }
    var fileBrowserSelectedFileTypes: Set<FlashFileBrowserFileType> {
        Set(internalState.fileBrowser?.selectedFileTypes ?? [])
    }

    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    private let internalState: InternalState<Ghostty.SurfaceView>

    init(from controller: TerminalController) {
        internalState = .init(from: controller)
    }

    required init(copy other: TerminalRestorableState) {
        self.internalState = other.internalState
    }

    /// This is just wrapper around internalState
    ///
    /// - Important: If you intend to add more things, go to `InternalState`.
    init(from decoder: any Decoder) throws {
        self.internalState = try InternalState<Ghostty.SurfaceView>(from: decoder)
    }

    /// This is just wrapper around internalState
    ///
    /// - Important: If you intend to add more things, go to `InternalState`.
    func encode(to encoder: any Encoder) throws {
        try internalState.encode(to: encoder)
    }
}

enum TerminalRestoreError: Error {
    case delegateInvalid
    case identifierUnknown
    case stateDecodeFailed
    case windowDidNotLoad
}

/// The NSWindowRestoration implementation that is called when a terminal window needs to be restored.
/// The encoding of a terminal window is handled elsewhere (usually NSWindowDelegate).
class TerminalWindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        // Verify the identifier is what we expect
        guard identifier == .init(String(describing: Self.self)) else {
            completionHandler(nil, TerminalRestoreError.identifierUnknown)
            return
        }

        // The app delegate is definitely setup by now. If it isn't our AppDelegate
        // then something is royally fucked up but protect against it anyhow.
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            completionHandler(nil, TerminalRestoreError.delegateInvalid)
            return
        }

        // If our configuration is "never" then we never restore the state
        // no matter what. Note its safe to use "ghostty.config" directly here
        // because window restoration is only ever invoked on app start so we
        // don't have to deal with config reloads.
        if appDelegate.ghostty.config.windowSaveState == "never" {
            AppDelegate.logger.warning("skip restoration: window-save-state=never")
            completionHandler(nil, nil)
            return
        }

        // Copy the serialized payload before returning from AppKit's callback.
        // This does not decode SurfaceViews or start any PTYs.
        guard let snapshot = TerminalRestorableSnapshot<TerminalRestorableState>(
            coder: state
        ) else {
            completionHandler(nil, TerminalRestoreError.stateDecodeFailed)
            return
        }

        // State decoding creates terminal surfaces and starts their PTYs. Defer
        // that work until the user has decided whether to restore this launch.
        appDelegate.enqueueStartupRestoration(
            restore: {
                TerminalSessionRestorationMaterializer.materialize(
                    snapshot: snapshot,
                    appDelegate: appDelegate,
                    completionHandler: completionHandler)
            },
            discard: {
                completionHandler(nil, nil)
            })
    }

}
