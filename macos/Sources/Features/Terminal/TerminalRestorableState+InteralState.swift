import AppKit

extension TerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // MARK: - Version 8 (FLASH-Ghostty)
        // Optional so archives from versions 5 through 7 continue to decode.
        let sessionSidebarIsVisible: Bool?

        // MARK: - Version 11 (FLASH-Ghostty)
        // Keep all file-browser preferences in one optional payload so future
        // fields do not require a terminal archive version for each property.
        let fileBrowser: FlashFileBrowserRestorableState?

        // Read-only migration accessors retained for fixture assertions.
        var fileBrowserIsVisible: Bool? { fileBrowser?.isVisible }
        var fileBrowserSelectedFileTypes: [FlashFileBrowserFileType]? {
            fileBrowser?.selectedFileTypes
        }

        init(
            focusedSurface: String?,
            surfaceTree: SplitTree<ViewType>,
            effectiveFullscreenMode: FullscreenMode?,
            tabColor: TerminalTabColor?,
            titleOverride: String?,
            sessionSidebarIsVisible: Bool?,
            fileBrowser: FlashFileBrowserRestorableState?
        ) {
            self.focusedSurface = focusedSurface
            self.surfaceTree = surfaceTree
            self.effectiveFullscreenMode = effectiveFullscreenMode
            self.tabColor = tabColor
            self.titleOverride = titleOverride
            self.sessionSidebarIsVisible = sessionSidebarIsVisible
            self.fileBrowser = fileBrowser
        }

        private enum CodingKeys: String, CodingKey {
            case focusedSurface
            case surfaceTree
            case effectiveFullscreenMode
            case tabColor
            case titleOverride
            case sessionSidebarIsVisible
            case fileBrowser

            // Compatibility with local v9/v10 development archives created
            // before the file-browser payload was consolidated.
            case fileBrowserIsVisible
            case fileBrowserSelectedFileTypes
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            focusedSurface = try container.decodeIfPresent(
                String.self,
                forKey: .focusedSurface
            )
            surfaceTree = try container.decode(
                SplitTree<ViewType>.self,
                forKey: .surfaceTree
            )
            effectiveFullscreenMode = try container.decodeIfPresent(
                FullscreenMode.self,
                forKey: .effectiveFullscreenMode
            )
            tabColor = try container.decodeIfPresent(
                TerminalTabColor.self,
                forKey: .tabColor
            )
            titleOverride = try container.decodeIfPresent(
                String.self,
                forKey: .titleOverride
            )
            sessionSidebarIsVisible = try container.decodeIfPresent(
                Bool.self,
                forKey: .sessionSidebarIsVisible
            )

            if container.contains(.fileBrowser) {
                // File-browser preferences are optional presentation state.
                // A future, malformed, or oversized nested payload must not
                // prevent the terminal surfaces themselves from restoring.
                fileBrowser = try? container.decode(
                    FlashFileBrowserRestorableState.self,
                    forKey: .fileBrowser
                )
            } else {
                let hasLegacyVisibility = container.contains(
                    .fileBrowserIsVisible
                )
                let hasLegacyTypes = container.contains(
                    .fileBrowserSelectedFileTypes
                )
                let legacyVisibility = try? container.decode(
                    Bool.self,
                    forKey: .fileBrowserIsVisible
                )
                let legacyTypes = FlashFileBrowserRestorableState
                    .decodeSelectedFileTypes(
                        from: container,
                        forKey: .fileBrowserSelectedFileTypes
                    )
                fileBrowser = if hasLegacyVisibility || hasLegacyTypes {
                    FlashFileBrowserRestorableState(
                        isVisible: legacyVisibility ?? true,
                        selectedFileTypes: legacyTypes ?? []
                    )
                } else {
                    nil
                }
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(focusedSurface, forKey: .focusedSurface)
            try container.encode(surfaceTree, forKey: .surfaceTree)
            try container.encodeIfPresent(
                effectiveFullscreenMode,
                forKey: .effectiveFullscreenMode
            )
            try container.encodeIfPresent(tabColor, forKey: .tabColor)
            try container.encodeIfPresent(titleOverride, forKey: .titleOverride)
            try container.encodeIfPresent(
                sessionSidebarIsVisible,
                forKey: .sessionSidebarIsVisible
            )
            try container.encodeIfPresent(fileBrowser, forKey: .fileBrowser)
        }
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: TerminalController) {
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: controller.titleOverride,
            sessionSidebarIsVisible: controller.sessionSidebarIsVisible,
            fileBrowser: .init(
                isVisible: controller.fileBrowserIsVisible,
                selectedFileTypes: controller.fileBrowserSelectedFileTypes
            )
        )
    }
}
