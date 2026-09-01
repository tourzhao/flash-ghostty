import Testing
import AppKit
@testable import Ghostty

@Suite
struct TerminalRestorableTests {
    @MainActor
    @Test func archivedSessionTitleAppliesWithoutLoadingTheWindow() throws {
        let archived = DummyTerminalRestorableState(.init(
            focusedSurface: nil,
            surfaceTree: .init(),
            effectiveFullscreenMode: nil,
            tabColor: nil,
            titleOverride: "Restored Session",
            sessionSidebarIsVisible: true,
            fileBrowser: nil
        ))
        let decoded = try #require(try snapshot(archived).decodedValue())

        let app = Ghostty.App(configPath: "/dev/null")
        #expect(app.readiness == .ready)

        let controller = RestorationWindowLoadProbeController(
            app,
            surfaceTree: .init()
        )
        #expect(!controller.isWindowLoaded)

        TerminalSessionRestorationMaterializer.applyTitle(
            decoded.internalState.titleOverride,
            to: controller
        )

        #expect(controller.titleOverride == "Restored Session")
        #expect(!controller.isWindowLoaded)
    }

    @MainActor
    @Test func decodedPresentationStateAppliesBeforeLazyWindowLoad() throws {
        let swiftType = FlashFileBrowserFileType(fileExtension: "swift")
        let archived = DummyTerminalRestorableState(.init(
            focusedSurface: nil,
            surfaceTree: .init(),
            effectiveFullscreenMode: nil,
            tabColor: nil,
            titleOverride: "Restored Workspace",
            sessionSidebarIsVisible: false,
            fileBrowser: .init(
                isVisible: false,
                selectedFileTypes: [.noExtension, swiftType]
            )
        ))
        let decoded = try #require(try snapshot(archived).decodedValue())
        let restored = decoded.internalState

        let app = Ghostty.App(configPath: "/dev/null")
        #expect(app.readiness == .ready)

        let controller = TerminalController(
            app,
            withSurfaceTree: .init(),
            windowPresentation: .init(
                windowDecorations: true,
                titlebarStyle: .sidebar
            )
        )
        #expect(!controller.isWindowLoaded)

        controller.restoreSessionSidebarVisibility(
            restored.sessionSidebarIsVisible ?? true
        )
        controller.restoreFileBrowserVisibility(
            restored.fileBrowser?.isVisible ?? true
        )
        controller.restoreFileBrowserSelectedFileTypes(
            Set(restored.fileBrowser?.selectedFileTypes ?? [])
        )
        TerminalSessionRestorationMaterializer.applyTitle(
            restored.titleOverride,
            to: controller
        )

        #expect(controller.titleOverride == "Restored Workspace")
        #expect(!controller.sessionSidebarIsVisible)
        #expect(!controller.fileBrowserIsVisible)
        #expect(controller.fileBrowserSelectedFileTypes == [.noExtension, swiftType])
        // Every property above must be available to TerminalController.windowDidLoad
        // without constructing a stale SwiftUI root as a side effect.
        #expect(!controller.isWindowLoaded)
    }

    @MainActor
    @Test func archivedSessionTitleIsReappliedWhenWindowEventuallyLoads() throws {
        let app = Ghostty.App(configPath: "/dev/null")
        #expect(app.readiness == .ready)

        let controller = RestorationWindowLoadProbeController(
            app,
            surfaceTree: .init()
        )
        TerminalSessionRestorationMaterializer.applyTitle(
            "Restored Session",
            to: controller
        )

        #expect(!controller.isWindowLoaded)
        let window = try #require(controller.window)
        #expect(controller.isWindowLoaded)
        #expect(window.title == "Restored Session")
        #expect(controller.sessionTitle == "Restored Session")
    }

    @Test func archivedSurfaceDirectoryBuildsTheRestorationConfiguration() throws {
        let surfaceID = UUID()
        let archived = Ghostty.SurfaceViewRestorationState(
            workingDirectory: "/private/tmp/flash-restore/worktree/",
            uuid: surfaceID,
            title: "shell title",
            isUserSetTitle: true
        )
        let data = try archive(CodableBridge(archived), className: nil)
        let bridge: CodableBridge<Ghostty.SurfaceViewRestorationState> =
            try unarchive(data, className: nil)
        let decoded = try #require(bridge.decodedValue())

        #expect(
            decoded.surfaceConfiguration.workingDirectory ==
                "/private/tmp/flash-restore/worktree"
        )
        #expect(decoded.uuid == surfaceID)
        #expect(decoded.title == "shell title")
        #expect(decoded.isUserSetTitle)
    }

    @MainActor
    @Test func transientUnknownDirectoryKeepsLastRestorableDirectory() {
        let surface = Ghostty.OSSurfaceView(
            id: UUID(),
            frame: .zero,
            initialWorkingDirectory: "/private/tmp/initial"
        )
        #expect(surface.lastKnownWorkingDirectory == "/private/tmp/initial")

        surface.pwd = "/private/tmp/runtime"
        surface.pwd = nil
        #expect(surface.lastKnownWorkingDirectory == "/private/tmp/runtime")

        surface.pwd = ""
        #expect(surface.lastKnownWorkingDirectory == "/private/tmp/runtime")
    }

    @MainActor
    @Test func staleOrMissingSplitFocusFallsBackDeterministically() throws {
        let (tree, first, second) = try SplitTreeTests.makeHorizontalSplit()
        let zoomedTree = SplitTree<MockView>(
            root: tree.root,
            zoomed: .leaf(view: second)
        )

        #expect(TerminalSessionRestorationMaterializer.restoredFocusedView(
            identifier: second.id.uuidString.lowercased(),
            in: tree
        ) === second)
        #expect(TerminalSessionRestorationMaterializer.restoredFocusedView(
            identifier: UUID().uuidString,
            in: tree
        ) === first)
        #expect(TerminalSessionRestorationMaterializer.restoredFocusedView(
            identifier: nil,
            in: tree
        ) === first)
        #expect(TerminalSessionRestorationMaterializer.restoredFocusedView(
            identifier: UUID().uuidString,
            in: zoomedTree
        ) === second)
        #expect(TerminalSessionRestorationMaterializer.restoredFocusedView(
            identifier: nil,
            in: zoomedTree
        ) === second)
        #expect(TerminalSessionRestorationMaterializer.restoredFocusedView(
            identifier: nil,
            in: SplitTree<MockView>()
        ) == nil)
    }

    @Test
    func codableBridgeReencodesDecodedReferenceMutations() throws {
        let original = CodableBridge(MutableCodableState(name: "before"))
        let firstArchive = try archive(original, className: nil)
        let decoded: CodableBridge<MutableCodableState> = try unarchive(
            firstArchive,
            className: nil
        )

        let value = try #require(decoded.decodedValue())
        value.name = "after"

        let secondArchive = try archive(decoded, className: nil)
        let redecoded: CodableBridge<MutableCodableState> = try unarchive(
            secondArchive,
            className: nil
        )
        #expect(redecoded.decodedValue()?.name == "after")
    }

    @Test
    func areYouForgettingToAddMigrationTests() {
        #expect(TerminalRestorableState.version == 11)
        #expect(TerminalRestorableState.minimumVersion == 5)

        #expect(QuickTerminalRestorableState.version == 1)
        #expect(QuickTerminalRestorableState.minimumVersion == 1)
    }

    @MainActor
    @Test func quickTerminalRestorableFromV1() throws {
        /* v1
        let tree = try SplitTreeTests.makeHorizontalSplit()
        let state = DummyQuickTerminalRestorableState(
            focusedSurface: "123",
            surfaceTree: tree.0,
            screenStateEntries: [:],
        )
        let data = try archive(CodableBridge(state), className: "CodableBridge<QuickTerminal>")
        print(data.base64EncodedString())
        print(tree.1.id)
        print(tree.2.id)
        */

        let decoded: CodableBridge<DummyQuickTerminalRestorableState> = try unarchive(v1QTData, className: "CodableBridge<QuickTerminal>")
        let state = decoded.value.internalState

        #expect(state.focusedSurface == "123")
        #expect(state.screenStateEntries.isEmpty)
        #expect(state.surfaceTree.contains(where: { $0.id.uuidString == "2F2F2D93-944C-474A-83BA-4DC1868C3EB9" }))
        #expect(state.surfaceTree.contains(where: { $0.id.uuidString == "994C673F-B4C5-49EE-B044-65006652636D" }))
    }

    // To generate old data: created a dummy class, archive, and copy the printed result
    @MainActor
    @Test func restoreTerminal57() throws {

//        let tree = try SplitTreeTests.makeHorizontalSplit()
//        let state = DummyTerminalRestorableState(
//            focusedSurface: "v5",
//            surfaceTree: tree.0,
//        )
//        let data = try archive(CodableBridge(state), className: "CodableBridge<Terminal>")
//        print(data.base64EncodedString())
//        print()
//        print(tree.1.id)
//        print(tree.2.id)

        let v5 = try unarchive(v5Data, className: "CodableBridge<Terminal>", as: CodableBridge<DummyTerminalRestorableState>.self)
            .value.internalState
        #expect(v5.focusedSurface == "v5")
        #expect(v5.effectiveFullscreenMode == nil)
        #expect(v5.tabColor == nil)
        #expect(v5.titleOverride == nil)
        #expect(v5.sessionSidebarIsVisible == nil)
        #expect(v5.fileBrowserIsVisible == nil)
        #expect(v5.fileBrowserSelectedFileTypes == nil)
        #expect(v5.surfaceTree.contains(where: { $0.id.uuidString == "926F3F2A-824C-40C9-87CA-2CDCA4E11049" }))
        #expect(v5.surfaceTree.contains(where: { $0.id.uuidString == "AC5E829B-85FD-4C69-B196-2EE469C72A90" }))

//        let tree = try SplitTreeTests.makeHorizontalSplit()
//        let state = DummyTerminalRestorableState(
//            focusedSurface: "v7",
//            surfaceTree: tree.0,
//            effectiveFullscreenMode: .native,
//            tabColor: .green,
//            titleOverride: "1.3.0"
//        )
//        let data = try archive(CodableBridge(state), className: "CodableBridge<Terminal>")
//        print(data.base64EncodedString())
//        print()
//        print(tree.1.id)
//        print(tree.2.id)

        let v7 = try unarchive(v7Data, className: "CodableBridge<Terminal>", as: CodableBridge<DummyTerminalRestorableState>.self)
            .value.internalState
        #expect(v7.focusedSurface == "v7")
        #expect(v7.effectiveFullscreenMode == .native)
        #expect(v7.tabColor == .green)
        #expect(v7.titleOverride == "1.3.0")
        #expect(v7.sessionSidebarIsVisible == nil)
        #expect(v7.fileBrowserIsVisible == nil)
        #expect(v7.fileBrowserSelectedFileTypes == nil)
        #expect(v7.surfaceTree.contains(where: { $0.id.uuidString == "5D580A7A-81EA-47C6-BB9A-AD4B1783E478" }))
        #expect(v7.surfaceTree.contains(where: { $0.id.uuidString == "96EA1189-7482-41BC-A6CD-26E5190E4BFA" }))

//        let tree = try SplitTreeTests.makeHorizontalSplit()
//        let state = DummyTerminalRestorableState(
//            .init(
//                focusedSurface: "v7 generic",
//                surfaceTree: tree.0,
//                effectiveFullscreenMode: .native,
//                tabColor: .green,
//                titleOverride: "tip"
//            )
//        )
//        let data = try archive(CodableBridge(state), className: "CodableBridge<Terminal>")
//        print(data.base64EncodedString())
//        print()
//        print(tree.1.id)
//        print(tree.2.id)

        let v7Generic = try unarchive(v7GenericData, className: "CodableBridge<Terminal>", as: CodableBridge<DummyTerminalRestorableState>.self)
            .value.internalState
        #expect(v7Generic.focusedSurface == "v7 generic")
        #expect(v7Generic.effectiveFullscreenMode == .native)
        #expect(v7Generic.tabColor == .green)
        #expect(v7Generic.titleOverride == "tip")
        #expect(v7Generic.sessionSidebarIsVisible == nil)
        #expect(v7Generic.fileBrowserIsVisible == nil)
        #expect(v7Generic.fileBrowserSelectedFileTypes == nil)
        #expect(v7Generic.surfaceTree.contains(where: { $0.id.uuidString == "953CE952-D91D-4D36-AC72-9D0F1F6BCE73" }))
        #expect(v7Generic.surfaceTree.contains(where: { $0.id.uuidString == "D3223569-2E01-4BC5-9DB2-DBFC3AFF46D1" }))
    }

    @MainActor
    @Test func restoreTerminal8PreservesSidebarAndUsesFileBrowserDefaults() throws {
        let state = try unarchive(
            v8Data,
            className: "CodableBridge<Terminal>",
            as: CodableBridge<DummyTerminalRestorableState>.self
        ).value.internalState

        #expect(state.focusedSurface == "v8")
        #expect(state.effectiveFullscreenMode == .native)
        #expect(state.tabColor == .purple)
        #expect(state.titleOverride == "FLASH v8")
        #expect(state.sessionSidebarIsVisible == false)
        #expect(state.fileBrowser == nil)

        // Version 8 predates file-browser persistence. Version 9 restores the
        // same defaults used for a newly created session when that payload is
        // absent: visible, with no selected type filters.
        #expect(state.fileBrowser?.isVisible ?? true)
        let selectedFileTypes = Set(
            state.fileBrowser?.selectedFileTypes ?? []
        )
        #expect(selectedFileTypes.isEmpty)

        #expect(state.surfaceTree.contains(where: {
            $0.id.uuidString == "4C5B8BA5-2534-46FD-B3B3-0C3B171042B0"
        }))
        #expect(state.surfaceTree.contains(where: {
            $0.id.uuidString == "7FA206B6-3EE8-4747-AFC3-B01D3BA8F9B2"
        }))
    }

    @MainActor
    @Test func legacyTerminalEnvelopeVersionsReachMigrationDecoder() throws {
        let archives = [
            (version: 5, data: v5Data, focusedSurface: "v5"),
            (version: 7, data: v7Data, focusedSurface: "v7"),
            (version: 8, data: v8Data, focusedSurface: "v8"),
        ]

        for archive in archives {
            let bridge: CodableBridge<DummyTerminalRestorableState> =
                try unarchive(
                    archive.data,
                    className: "CodableBridge<Terminal>"
                )
            let snapshot = try #require(try snapshot(
                bridge: bridge,
                archivedVersion: archive.version
            ))
            #expect(
                snapshot.decodedValue()?.internalState.focusedSurface ==
                    archive.focusedSurface
            )
        }
    }

    @MainActor
    @Test func unsupportedLegacyTerminalEnvelopeIsRejected() throws {
        let bridge: CodableBridge<DummyTerminalRestorableState> = try unarchive(
            v5Data,
            className: "CodableBridge<Terminal>"
        )

        #expect(try snapshot(
            bridge: bridge,
            archivedVersion: TerminalRestorableState.minimumVersion - 1
        ) == nil)
    }

    @MainActor
    @Test func unsupportedFutureTerminalEnvelopeIsRejected() throws {
        let bridge: CodableBridge<DummyTerminalRestorableState> = try unarchive(
            v8Data,
            className: "CodableBridge<Terminal>"
        )

        #expect(try snapshot(
            bridge: bridge,
            archivedVersion: TerminalRestorableState.version + 1
        ) == nil)
    }

    @MainActor
    @Test func restoreTerminal11FileBrowserStateRoundTrip() throws {
        let tree = try SplitTreeTests.makeHorizontalSplit()
        let state = DummyTerminalRestorableState(.init(
            focusedSurface: tree.1.id.uuidString,
            surfaceTree: tree.0,
            effectiveFullscreenMode: nil,
            tabColor: .blue,
            titleOverride: "Saved Session",
            sessionSidebarIsVisible: false,
            fileBrowser: .init(
                isVisible: false,
                selectedFileTypes: [
                    FlashFileBrowserFileType(fileExtension: "swift"),
                    .noExtension,
                    FlashFileBrowserFileType(fileExtension: ".SWIFT"),
                ]
            )
        ))
        // Exercise the real AppKit envelope: outer version, CodableBridge,
        // and the nested file-browser payload all make the round trip.
        let decoded = try #require(try snapshot(state).decodedValue())

        #expect(decoded.internalState.focusedSurface == tree.1.id.uuidString)
        #expect(decoded.internalState.titleOverride == "Saved Session")
        #expect(decoded.internalState.tabColor == .blue)
        #expect(decoded.internalState.sessionSidebarIsVisible == false)
        #expect(decoded.internalState.fileBrowserIsVisible == false)
        #expect(
            decoded.internalState.fileBrowserSelectedFileTypes == [
                .noExtension,
                FlashFileBrowserFileType(fileExtension: "swift"),
            ]
        )
    }

    @MainActor
    @Test func terminal11EncodingUsesConsolidatedFileBrowserSchema() throws {
        let tree = try SplitTreeTests.makeHorizontalSplit().0
        let state = TerminalRestorableState.InternalState<MockView>(
            focusedSurface: tree.first?.id.uuidString,
            surfaceTree: tree,
            effectiveFullscreenMode: .native,
            tabColor: .green,
            titleOverride: "Schema",
            sessionSidebarIsVisible: false,
            fileBrowser: .init(
                isVisible: false,
                selectedFileTypes: [.noExtension]
            )
        )

        let encoded = try JSONEncoder().encode(state)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(Set(object.keys) == [
            "effectiveFullscreenMode",
            "fileBrowser",
            "focusedSurface",
            "sessionSidebarIsVisible",
            "surfaceTree",
            "tabColor",
            "titleOverride",
        ])
        let fileBrowser = try #require(
            object["fileBrowser"] as? [String: Any]
        )
        #expect(Set(fileBrowser.keys) == [
            "isVisible",
            "selectedFileTypes",
            "version",
        ])
        #expect(
            fileBrowser["version"] as? Int ==
                FlashFileBrowserRestorableState.currentVersion
        )
        #expect(object["fileBrowserIsVisible"] == nil)
        #expect(object["fileBrowserSelectedFileTypes"] == nil)
    }

    @MainActor
    @Test func restoreTerminal9FrozenFixture() throws {
        let object = try frozenV9TerminalObject()
        let legacyFileBrowser = try #require(
            object["fileBrowser"] as? [String: Any]
        )
        #expect(legacyFileBrowser["version"] == nil)

        let state = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self,
            from: v9PayloadData
        )
        let surfaceID = try #require(UUID(
            uuidString: "CB47B40E-6A18-45AE-AB1B-84126EC06E87"
        ))

        #expect(state.focusedSurface == surfaceID.uuidString)
        #expect(state.surfaceTree.contains(where: { $0.id == surfaceID }))
        #expect(state.effectiveFullscreenMode == .native)
        #expect(state.tabColor == .purple)
        #expect(state.titleOverride == "FLASH v9 fixture")
        #expect(state.sessionSidebarIsVisible == false)
        #expect(state.fileBrowser?.isVisible == false)
        #expect(state.fileBrowser?.selectedFileTypes == [
            .noExtension,
            FlashFileBrowserFileType(fileExtension: "swift"),
        ])

        let bridge = CodableBridge(DummyTerminalRestorableState(state))
        let snapshot = try #require(try snapshot(
            bridge: bridge,
            archivedVersion: v9ArchiveVersion
        ))
        #expect(
            snapshot.decodedValue()?.internalState.focusedSurface ==
                surfaceID.uuidString
        )
    }

    @MainActor
    @Test func consolidatedFileBrowserStateDecodesLegacyDevelopmentKeys() throws {
        let tree = try SplitTreeTests.makeHorizontalSplit()
        let current = TerminalRestorableState.InternalState<MockView>(
            focusedSurface: tree.1.id.uuidString,
            surfaceTree: tree.0,
            effectiveFullscreenMode: nil,
            tabColor: nil,
            titleOverride: "Legacy",
            sessionSidebarIsVisible: true,
            fileBrowser: .init(
                isVisible: true,
                selectedFileTypes: []
            )
        )

        let encoded = try JSONEncoder().encode(current)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "fileBrowser")
        object["fileBrowserIsVisible"] = false
        object["fileBrowserSelectedFileTypes"] = [
            ["fileExtension": "swift"],
            [String: String](),
        ]

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self,
            from: legacyData
        )

        #expect(decoded.fileBrowser?.isVisible == false)
        #expect(decoded.fileBrowser?.selectedFileTypes == [
            .noExtension,
            FlashFileBrowserFileType(fileExtension: "swift"),
        ])
    }

    @MainActor
    @Test func legacyTerminal9RealEnvelopeReachesMigrationDecoder() throws {
        let tree = try SplitTreeTests.makeHorizontalSplit()
        let legacy = LegacyV9TerminalRestorableState(
            focusedSurface: tree.1.id.uuidString,
            surfaceTree: tree.0,
            effectiveFullscreenMode: .native,
            tabColor: .purple,
            titleOverride: "FLASH v9 real archive",
            sessionSidebarIsVisible: false,
            fileBrowser: .init(
                isVisible: false,
                selectedFileTypes: [
                    FlashFileBrowserFileType(fileExtension: "swift"),
                    .noExtension,
                ]
            )
        )
        let archiveData = try archive(
            CodableBridge(legacy),
            className: "CodableBridge<Terminal>"
        )
        let bridge: CodableBridge<DummyTerminalRestorableState> = try unarchive(
            archiveData,
            className: "CodableBridge<Terminal>"
        )
        let archived = try #require(try snapshot(
            bridge: bridge,
            archivedVersion: 9
        ))
        let state = try #require(archived.decodedValue()).internalState

        #expect(state.focusedSurface == tree.1.id.uuidString)
        #expect(state.titleOverride == "FLASH v9 real archive")
        #expect(state.sessionSidebarIsVisible == false)
        #expect(state.fileBrowser?.isVisible == false)
        #expect(state.fileBrowser?.selectedFileTypes == [
            .noExtension,
            FlashFileBrowserFileType(fileExtension: "swift"),
        ])
    }

    @MainActor
    @Test func legacyTerminal10EnvelopeReachesMigrationDecoder() throws {
        let tree = try SplitTreeTests.makeHorizontalSplit()
        let legacy = LegacyV10TerminalRestorableState(
            focusedSurface: tree.1.id.uuidString,
            surfaceTree: tree.0,
            effectiveFullscreenMode: .native,
            tabColor: .green,
            titleOverride: "FLASH v10",
            sessionSidebarIsVisible: false,
            fileBrowserIsVisible: false,
            fileBrowserSelectedFileTypes: [
                FlashFileBrowserFileType(fileExtension: "swift"),
                .noExtension,
            ]
        )
        let archiveData = try archive(
            CodableBridge(legacy),
            className: "CodableBridge<Terminal>"
        )
        let bridge: CodableBridge<DummyTerminalRestorableState> = try unarchive(
            archiveData,
            className: "CodableBridge<Terminal>"
        )
        let archived = try #require(try snapshot(
            bridge: bridge,
            archivedVersion: 10
        ))
        let state = try #require(archived.decodedValue()).internalState

        #expect(state.focusedSurface == tree.1.id.uuidString)
        #expect(state.titleOverride == "FLASH v10")
        #expect(state.sessionSidebarIsVisible == false)
        #expect(state.fileBrowser?.isVisible == false)
        #expect(state.fileBrowser?.selectedFileTypes == [
            .noExtension,
            FlashFileBrowserFileType(fileExtension: "swift"),
        ])
    }

    @MainActor
    @Test func partialFileBrowserPayloadsUseIndependentDefaults() throws {
        let tree = try SplitTreeTests.makeHorizontalSplit().0
        let state = TerminalRestorableState.InternalState<MockView>(
            focusedSurface: tree.first?.id.uuidString,
            surfaceTree: tree,
            effectiveFullscreenMode: nil,
            tabColor: nil,
            titleOverride: nil,
            sessionSidebarIsVisible: true,
            fileBrowser: nil
        )
        let encoded = try JSONEncoder().encode(state)
        let baseObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let swiftType = FlashFileBrowserFileType(fileExtension: "swift")

        for (payload, expectedVisibility, expectedTypes) in [
            (
                ["isVisible": false] as [String: Any],
                false,
                [] as [FlashFileBrowserFileType]
            ),
            (
                ["selectedFileTypes": [["fileExtension": "swift"]]],
                true,
                [swiftType]
            ),
        ] {
            var object = baseObject
            object["fileBrowser"] = payload
            let data = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(
                TerminalRestorableState.InternalState<MockView>.self,
                from: data
            )

            #expect(decoded.fileBrowser?.isVisible == expectedVisibility)
            #expect(decoded.fileBrowser?.selectedFileTypes == expectedTypes)
        }

        for (legacyFields, expectedVisibility, expectedTypes) in [
            (
                ["fileBrowserIsVisible": false] as [String: Any],
                false,
                [] as [FlashFileBrowserFileType]
            ),
            (
                [
                    "fileBrowserSelectedFileTypes": [
                        ["fileExtension": "swift"],
                    ],
                ],
                true,
                [swiftType]
            ),
        ] {
            var object = baseObject
            object.merge(legacyFields) { _, newValue in newValue }
            let data = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(
                TerminalRestorableState.InternalState<MockView>.self,
                from: data
            )

            #expect(decoded.fileBrowser?.isVisible == expectedVisibility)
            #expect(decoded.fileBrowser?.selectedFileTypes == expectedTypes)
        }
    }

    @MainActor
    @Test func futureNestedFileBrowserSchemaFailsSoftWithoutDowngrade() throws {
        var object = try frozenV9TerminalObject()
        object["fileBrowser"] = [
            "version": FlashFileBrowserRestorableState.currentVersion + 1,
            "isVisible": false,
            "selectedFileTypes": [["fileExtension": "swift"]],
        ] as [String: Any]
        // A nested payload owns this namespace whenever the key is present.
        // Stale flat keys must not turn a corrupt/future schema into a silent
        // downgrade to a different historical representation.
        object["fileBrowserIsVisible"] = false
        object["fileBrowserSelectedFileTypes"] = [
            ["fileExtension": "txt"],
        ]

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self,
            from: data
        )

        #expect(
            decoded.focusedSurface ==
                "CB47B40E-6A18-45AE-AB1B-84126EC06E87"
        )
        #expect(decoded.titleOverride == "FLASH v9 fixture")
        #expect(decoded.fileBrowser == nil)
    }

    @MainActor
    @Test func malformedNestedFileBrowserFieldsFailSoftIndependently() throws {
        let maximumByteCount =
            FlashFileBrowserFileType.maximumRestoredExtensionUTF8ByteCount
        let maximumExtension = String(
            repeating: "m",
            count: maximumByteCount
        )
        let oversizedExtension = String(
            repeating: "x",
            count: maximumByteCount + 1
        )
        let malformedTypes: [[String: Any]] = [
            ["fileExtension": "swift"],
            ["fileExtension": maximumExtension],
            ["fileExtension": oversizedExtension],
            ["fileExtension": 42],
        ]
        var object = try frozenV9TerminalObject()
        object["fileBrowser"] = [
            "version": FlashFileBrowserRestorableState.currentVersion,
            "isVisible": "not-a-boolean",
            "selectedFileTypes": malformedTypes,
        ] as [String: Any]

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self,
            from: data
        )

        #expect(decoded.fileBrowser?.isVisible == true)
        #expect(Set(decoded.fileBrowser?.selectedFileTypes ?? []) == [
            FlashFileBrowserFileType(fileExtension: "swift"),
            FlashFileBrowserFileType(fileExtension: maximumExtension),
        ])
    }

    @MainActor
    @Test func nestedAndLegacyFileTypeListsEnforceInputLimit() throws {
        let maximumCount =
            FlashFileBrowserRestorableState.maximumSelectedFileTypeCount
        let maximumList: [[String: String]] = (0..<maximumCount).map {
            ["fileExtension": "type\($0)"]
        }
        let oversizedList = maximumList + [[
            "fileExtension": "type\(maximumCount)",
        ]]

        var maximumObject = try frozenV9TerminalObject()
        maximumObject["fileBrowser"] = [
            "version": FlashFileBrowserRestorableState.currentVersion,
            "isVisible": false,
            "selectedFileTypes": maximumList,
        ] as [String: Any]
        let maximumData = try JSONSerialization.data(
            withJSONObject: maximumObject
        )
        let maximum = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self,
            from: maximumData
        )
        #expect(
            maximum.fileBrowser?.selectedFileTypes.count == maximumCount
        )

        var nestedObject = try frozenV9TerminalObject()
        nestedObject["fileBrowser"] = [
            "version": FlashFileBrowserRestorableState.currentVersion,
            "isVisible": false,
            "selectedFileTypes": oversizedList,
        ] as [String: Any]
        let nestedData = try JSONSerialization.data(
            withJSONObject: nestedObject
        )
        let nested = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self,
            from: nestedData
        )
        #expect(nested.fileBrowser?.isVisible == false)
        #expect(nested.fileBrowser?.selectedFileTypes.isEmpty == true)

        var legacyObject = try frozenV9TerminalObject()
        legacyObject.removeValue(forKey: "fileBrowser")
        legacyObject["fileBrowserIsVisible"] = false
        legacyObject["fileBrowserSelectedFileTypes"] = oversizedList
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyObject
        )
        let legacy = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<MockView>.self,
            from: legacyData
        )
        #expect(legacy.fileBrowser?.isVisible == false)
        #expect(legacy.fileBrowser?.selectedFileTypes.isEmpty == true)
    }

    @Test func fileBrowserRestorableStateBoundsEncodedPreferences() {
        let maximumCount =
            FlashFileBrowserRestorableState.maximumSelectedFileTypeCount
        var types = (0...maximumCount).map {
            FlashFileBrowserFileType(fileExtension: "type\($0)")
        }
        types.append(FlashFileBrowserFileType(
            fileExtension: String(
                repeating: "x",
                count: FlashFileBrowserFileType
                    .maximumRestoredExtensionUTF8ByteCount + 1
            )
        ))

        let state = FlashFileBrowserRestorableState(
            isVisible: true,
            selectedFileTypes: types
        )

        #expect(state.selectedFileTypes.count == maximumCount)
        #expect(state.selectedFileTypes.allSatisfy {
            $0.isWithinRestorationLimits
        })
    }

    @MainActor
    @Test func startupRestorationGateRestoresEveryRequestOnce() {
        var gate = StartupRestorationGate()
        var events: [String] = []

        let first = gate.enqueue(
            restore: { events.append("restore-1") },
            discard: { events.append("discard-1") }
        )
        let second = gate.enqueue(
            restore: { events.append("restore-2") },
            discard: { events.append("discard-2") }
        )

        #expect(first == nil)
        #expect(second == nil)
        #expect(gate.hasPendingRequests)
        #expect(events.isEmpty)

        let actions = gate.resolve(.restore)
        #expect(actions.count == 2)
        #expect(!gate.hasPendingRequests)
        actions.forEach { $0() }
        #expect(events == ["restore-1", "restore-2"])
        #expect(gate.resolve(.startFresh).isEmpty)

        let late = gate.enqueue(
            restore: { events.append("restore-late") },
            discard: { events.append("discard-late") }
        )
        #expect(late != nil)
        late?()
        #expect(events == ["restore-1", "restore-2", "restore-late"])
    }

    @MainActor
    @Test func startupRestorationGateDiscardsEveryRequest() {
        var gate = StartupRestorationGate()
        var events: [String] = []

        _ = gate.enqueue(
            restore: { events.append("restore") },
            discard: { events.append("discard") }
        )
        let actions = gate.resolve(.startFresh)
        actions.forEach { $0() }

        #expect(events == ["discard"])
        #expect(gate.decision == .startFresh)
    }

    @MainActor
    @Test func startupRestorationDefersDecodeUntilRestoreDecision() throws {
        DeferredDecodeRestorableState.decodeCount = 0

        let discardedSnapshot = try snapshot(
            DeferredDecodeRestorableState(name: "discarded")
        )
        #expect(DeferredDecodeRestorableState.decodeCount == 0)

        var discarded = false
        var discardGate = StartupRestorationGate()
        _ = discardGate.enqueue(
            restore: { _ = discardedSnapshot.decodedValue() },
            discard: { discarded = true }
        )
        discardGate.resolve(.startFresh).forEach { $0() }

        #expect(discarded)
        #expect(DeferredDecodeRestorableState.decodeCount == 0)

        let restoredSnapshot = try snapshot(
            DeferredDecodeRestorableState(name: "restored")
        )
        #expect(DeferredDecodeRestorableState.decodeCount == 0)

        var restoredName: String?
        var restoreGate = StartupRestorationGate()
        _ = restoreGate.enqueue(
            restore: { restoredName = restoredSnapshot.decodedValue()?.name },
            discard: {}
        )
        restoreGate.resolve(.restore).forEach { $0() }

        #expect(restoredName == "restored")
        #expect(DeferredDecodeRestorableState.decodeCount == 1)
    }

    @Test func startupRestorationMarkerDistinguishesLegacyAndDiscardedState() {
        #expect(SessionRestorationArchiveMarker(storedValue: nil) == .legacy)
        #expect(SessionRestorationArchiveMarker(storedValue: NSNumber(value: true)) == .available)
        #expect(SessionRestorationArchiveMarker(storedValue: NSNumber(value: false)) == .discarded)
        #expect(SessionRestorationArchiveMarker(storedValue: "invalid") == .discarded)
    }
}

@MainActor
private final class RestorationWindowLoadProbeController:
    BaseTerminalController {
    override var undoManager: ExpiringUndoManager? { nil }

    // `NSWindowController(window: nil)` is considered already loaded when no
    // nib name is provided. Supply a synthetic name so this probe exercises
    // the real lazy-load path; `loadWindow` below deliberately avoids a nib.
    override var windowNibName: NSNib.Name? { "RestorationWindowLoadProbe" }

    override func loadWindow() {
        window = NSWindow(
            contentRect: .zero,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
    }
}

private extension TerminalRestorableTests {
    func frozenV9TerminalObject() throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: v9PayloadData) as? [String: Any]
        )
    }

    func snapshot<State: TerminalRestorable>(
        _ state: State
    ) throws -> TerminalRestorableSnapshot<State> {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        state.encode(with: archiver)
        archiver.finishEncoding()

        let unarchiver = try NSKeyedUnarchiver(
            forReadingFrom: archiver.encodedData
        )
        defer { unarchiver.finishDecoding() }
        return try #require(TerminalRestorableSnapshot<State>(coder: unarchiver))
    }

    func snapshot<State: TerminalRestorable>(
        bridge: CodableBridge<State>,
        archivedVersion: Int
    ) throws -> TerminalRestorableSnapshot<State>? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(archivedVersion, forKey: State.versionKey)
        archiver.encode(bridge, forKey: State.selfKey)
        archiver.finishEncoding()

        let unarchiver = try NSKeyedUnarchiver(
            forReadingFrom: archiver.encodedData
        )
        defer { unarchiver.finishDecoding() }
        return TerminalRestorableSnapshot<State>(coder: unarchiver)
    }

    func archive<T: NSObject & NSSecureCoding>(_ obj: T, className: String?) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        defer { archiver.finishEncoding() }
        if let className {
            archiver.setClassName(className, for: T.self)
        }
        archiver.encode(obj, forKey: NSKeyedArchiveRootObjectKey)
        return archiver.encodedData
    }

    func unarchive<T: NSObject & NSSecureCoding>(_ data: Data, className: String?, as: T.Type = T.self) throws -> T {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        defer { unarchiver.finishDecoding()}
        if let className {
            unarchiver.setClass(T.self, forClassName: className)
        }
        unarchiver.requiresSecureCoding = true
        let result = unarchiver.decodeObject(of: T.self, forKey: NSKeyedArchiveRootObjectKey)
        return try #require(result)
    }
}

// MARK: - Dummy States

private final class MutableCodableState: Codable {
    var name: String

    init(name: String) {
        self.name = name
    }
}

@MainActor
private final class DeferredDecodeRestorableState: TerminalRestorable {
    static let version = 1
    static var decodeCount = 0

    let name: String

    init(name: String) {
        self.name = name
    }

    required init(copy other: DeferredDecodeRestorableState) {
        self.name = other.name
    }

    required init(from decoder: any Decoder) throws {
        Self.decodeCount += 1
        let container = try decoder.singleValueContainer()
        self.name = try container.decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

@MainActor
private final class DummyTerminalRestorableState: TerminalRestorable {
    static var version: Int {
        TerminalRestorableState.version
    }

    static var minimumVersion: Int {
        TerminalRestorableState.minimumVersion
    }

    required init(copy other: DummyTerminalRestorableState) {
        internalState = other.internalState
    }

    let internalState: TerminalRestorableState.InternalState<MockView>

    init(_ internalState: TerminalRestorableState.InternalState<MockView>) {
        self.internalState = internalState
    }

    required init(from decoder: any Decoder) throws {
        self.internalState = try TerminalRestorableState.InternalState<MockView>(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try internalState.encode(to: encoder)
    }
}

/// Matches the unversioned nested file-browser payload written by local v9
/// builds. This type deliberately must not adopt the current nested schema.
private struct LegacyV9FileBrowserRestorableState: Codable {
    let isVisible: Bool
    let selectedFileTypes: [FlashFileBrowserFileType]
}

private struct LegacyV9TerminalRestorableState: Codable {
    let focusedSurface: String?
    let surfaceTree: SplitTree<MockView>
    let effectiveFullscreenMode: FullscreenMode?
    let tabColor: TerminalTabColor?
    let titleOverride: String?
    let sessionSidebarIsVisible: Bool?
    let fileBrowser: LegacyV9FileBrowserRestorableState?
}

/// Matches the two independent file-browser keys written by local v10 builds.
/// Archiving this type and decoding the bridge as the current state exercises
/// both the outer version gate and the real Codable migration path.
private struct LegacyV10TerminalRestorableState: Codable {
    let focusedSurface: String?
    let surfaceTree: SplitTree<MockView>
    let effectiveFullscreenMode: FullscreenMode?
    let tabColor: TerminalTabColor?
    let titleOverride: String?
    let sessionSidebarIsVisible: Bool?
    let fileBrowserIsVisible: Bool?
    let fileBrowserSelectedFileTypes: [FlashFileBrowserFileType]?
}

@MainActor
struct DummyQuickTerminalRestorableState: TerminalRestorable {
    static var version: Int = QuickTerminalRestorableState.version

    static var minimumVersion: Int = QuickTerminalRestorableState.minimumVersion

    init(copy other: DummyQuickTerminalRestorableState) {
        internalState = other.internalState
    }

    let internalState: QuickTerminalRestorableState.InternalState<MockView>

    init(_ internalState: QuickTerminalRestorableState.InternalState<MockView>) {
        self.internalState = internalState
    }

    init(from decoder: any Decoder) throws {
        self.internalState = try QuickTerminalRestorableState.InternalState<MockView>(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        try internalState.encode(to: encoder)
    }
}

// MARK: - QuickTerminal V1 (1.3.0)

private let v1QTData = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGkCwwRElUkbnVsbNINDg8QVGRhdGFWJGNsYXNzgAKAA08RA6hicGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVXZhbHVlgAGvECALDBkaGxwfJicvMDEyODlFRkdISU9QVldYXF1jaWpwcVUkbnVsbNMNDg8QFBhXTlMua2V5c1pOUy5vYmplY3RzViRjbGFzc6MREhOAAoADgASjFRYXgAWAB4AIgBhfEBJzY3JlZW5TdGF0ZUVudHJpZXNeZm9jdXNlZFN1cmZhY2Vbc3VyZmFjZVRyZWXSDg8dHqCABtIgISIjWiRjbGFzc25hbWVYJGNsYXNzZXNeTlNNdXRhYmxlQXJyYXmjIiQlV05TQXJyYXlYTlNPYmplY3RTMTIz0w0ODygrGKIpKoAJgAqiLC2AC4AMgBhXdmVyc2lvblRyb290EAHTDQ4PMzUYoTSADaE2gA6AGFVzcGxpdNMNDg86PxikOzw9PoAPgBCAEYASpEBBQkOAE4AZgBqAHYAYVXJpZ2h0VXJhdGlvVGxlZnRZZGlyZWN0aW9u0w0OD0pMGKFLgBShTYAVgBhUdmlld9MNDg9RUxihUoAWoVSAF4AYUmlkXxAkOTk0QzY3M0YtQjRDNS00OUVFLUIwNDQtNjUwMDY2NTI2MzZE0iAhWVpfEBNOU011dGFibGVEaWN0aW9uYXJ5o1lbJVxOU0RpY3Rpb25hcnkjP+AAAAAAAADTDQ4PXmAYoUuAFKFhgBuAGNMNDg9kZhihUoAWoWeAHIAYXxAkMkYyRjJEOTMtOTQ0Qy00NzRBLTgzQkEtNERDMTg2OEMzRUI50w0OD2ttGKFsgB6hboAfgBhaaG9yaXpvbnRhbNMNDg9ycxigoIAYAAgAEQAaACQAKQAyADcASQBMAFIAVAB3AH0AhACMAJcAngCiAKQApgCoAKwArgCwALIAtADJANgA5ADpAOoA7ADxAPwBBQEUARgBIAEpAS0BNAE3ATkBOwE+AUABQgFEAUwBUQFTAVoBXAFeAWABYgFkAWoBcQF2AXgBegF8AX4BgwGFAYcBiQGLAY0BkwGZAZ4BqAGvAbEBswG1AbcBuQG+AcUBxwHJAcsBzQHPAdIB+QH+AhQCGAIlAi4CNQI3AjkCOwI9Aj8CRgJIAkoCTAJOAlACdwJ+AoACggKEAoYCiAKTApoCmwKcAAAAAAAAAgEAAAAAAAAAdQAAAAAAAAAAAAAAAAAAAp7RExRaJGNsYXNzbmFtZV8QHENvZGFibGVCcmlkZ2U8UXVpY2tUZXJtaW5hbD4ACAARABoAJAApADIANwBJAEwAUQBTAFgAXgBjAGgAbwBxAHMEHwQiBC0AAAAAAAACAQAAAAAAAAAVAAAAAAAAAAAAAAAAAAAETA==
    """)!

// MARK: - Terminal V5 (1.2.3)

private let v5Data = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGkCwwRElUkbnVsbNINDg8QVGRhdGFWJGNsYXNzgAKAA08RA01icGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVXZhbHVlgAGvEB0LDBcYGRoiIyQlKyw4OTo7PEJDSUpLUlNZX2BmZ1UkbnVsbNMNDg8QExZXTlMua2V5c1pOUy5vYmplY3RzViRjbGFzc6IREoACgAOiFBWABIAFgBVeZm9jdXNlZFN1cmZhY2Vbc3VyZmFjZVRyZWVSdjXTDQ4PGx4WohwdgAaAB6IfIIAIgAmAFVd2ZXJzaW9uVHJvb3QQAdMNDg8mKBahJ4AKoSmAC4AVVXNwbGl00w0ODy0yFqQuLzAxgAyADYAOgA+kMzQ1NoAQgBaAF4AagBVVcmlnaHRVcmF0aW9UbGVmdFlkaXJlY3Rpb27TDQ4PPT8WoT6AEaFAgBKAFVR2aWV30w0OD0RGFqFFgBOhR4AUgBVSaWRfECRBQzVFODI5Qi04NUZELTRDNjktQjE5Ni0yRUU0NjlDNzJBOTDSTE1OT1okY2xhc3NuYW1lWCRjbGFzc2VzXxATTlNNdXRhYmxlRGljdGlvbmFyeaNOUFFcTlNEaWN0aW9uYXJ5WE5TT2JqZWN0Iz/gAAAAAAAA0w0OD1RWFqE+gBGhV4AYgBXTDQ4PWlwWoUWAE6FdgBmAFV8QJDkyNkYzRjJBLTgyNEMtNDBDOS04N0NBLTJDRENBNEUxMTA0OdMNDg9hYxahYoAboWSAHIAVWmhvcml6b250YWzTDQ4PaGkWoKCAFQAIABEAGgAkACkAMgA3AEkATABSAFQAdAB6AIEAiQCUAJsAngCgAKIApQCnAKkAqwC6AMYAyQDQANMA1QDXANoA3ADeAOAA6ADtAO8A9gD4APoA/AD+AQABBgENARIBFAEWARgBGgEfASEBIwElAScBKQEvATUBOgFEAUsBTQFPAVEBUwFVAVoBYQFjAWUBZwFpAWsBbgGVAZoBpQGuAcQByAHVAd4B5wHuAfAB8gH0AfYB+AH/AgECAwIFAgcCCQIwAjcCOQI7Aj0CPwJBAkwCUwJUAlUAAAAAAAACAQAAAAAAAABrAAAAAAAAAAAAAAAAAAACV9ETFFokY2xhc3NuYW1lXxAXQ29kYWJsZUJyaWRnZTxUZXJtaW5hbD4ACAARABoAJAApADIANwBJAEwAUQBTAFgAXgBjAGgAbwBxAHMDxAPHA9IAAAAAAAACAQAAAAAAAAAVAAAAAAAAAAAAAAAAAAAD7A==
    """)!

// MARK: - Terminal V7 (1.3.0)

private let v7Data = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGkCwwRElUkbnVsbNINDg8QVGRhdGFWJGNsYXNzgAKAA08RA71icGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVXZhbHVlgAGvECMLDB0eHyAhIiMkLC0uLzU2QkNERUZMTVNUVVxdY2lqcHF1dlUkbnVsbNMNDg8QFhxXTlMua2V5c1pOUy5vYmplY3RzViRjbGFzc6UREhMUFYACgAOABIAFgAalFxgZGhuAB4AIgAmAIYAigBlfEBdlZmZlY3RpdmVGdWxsc2NyZWVuTW9kZV5mb2N1c2VkU3VyZmFjZVtzdXJmYWNlVHJlZVh0YWJDb2xvcl10aXRsZU92ZXJyaWRlVm5hdGl2ZVJ2N9MNDg8lKByiJieACoALoikqgAyADYAZV3ZlcnNpb25Ucm9vdBAB0w0ODzAyHKExgA6hM4APgBlVc3BsaXTTDQ4PNzwcpDg5OjuAEIARgBKAE6Q9Pj9AgBSAGoAbgB6AGVVyaWdodFVyYXRpb1RsZWZ0WWRpcmVjdGlvbtMNDg9HSRyhSIAVoUqAFoAZVHZpZXfTDQ4PTlAcoU+AF6FRgBiAGVJpZF8QJDk2RUExMTg5LTc0ODItNDFCQy1BNkNELTI2RTUxOTBFNEJGQdJWV1hZWiRjbGFzc25hbWVYJGNsYXNzZXNfEBNOU011dGFibGVEaWN0aW9uYXJ5o1haW1xOU0RpY3Rpb25hcnlYTlNPYmplY3QjP+AAAAAAAADTDQ4PXmAcoUiAFaFhgByAGdMNDg9kZhyhT4AXoWeAHYAZXxAkNUQ1ODBBN0EtODFFQS00N0M2LUJCOUEtQUQ0QjE3ODNFNDc40w0OD2ttHKFsgB+hboAggBlaaG9yaXpvbnRhbNMNDg9ycxygoIAZEAdVMS4zLjAACAARABoAJAApADIANwBJAEwAUgBUAHoAgACHAI8AmgChAKcAqQCrAK0ArwCxALcAuQC7AL0AvwDBAMMA3QDsAPgBAQEPARYBGQEgASMBJQEnASoBLAEuATABOAE9AT8BRgFIAUoBTAFOAVABVgFdAWIBZAFmAWgBagFvAXEBcwF1AXcBeQF/AYUBigGUAZsBnQGfAaEBowGlAaoBsQGzAbUBtwG5AbsBvgHlAeoB9QH+AhQCGAIlAi4CNwI+AkACQgJEAkYCSAJPAlECUwJVAlcCWQKAAocCiQKLAo0CjwKRApwCowKkAqUCpwKpAAAAAAAAAgEAAAAAAAAAdwAAAAAAAAAAAAAAAAAAAq/RExRaJGNsYXNzbmFtZV8QF0NvZGFibGVCcmlkZ2U8VGVybWluYWw+AAgAEQAaACQAKQAyADcASQBMAFEAUwBYAF4AYwBoAG8AcQBzBDQENwRCAAAAAAAAAgEAAAAAAAAAFQAAAAAAAAAAAAAAAAAABFw=
    """)!

// MARK: - Terminal V7 Generic (tip)

private let v7GenericData = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGkCwwRElUkbnVsbNINDg8QVGRhdGFWJGNsYXNzgAKAA08RA8NicGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVXZhbHVlgAGvECMLDB0eHyAhIiMkLC0uLzU2QkNERUZMTVNUVVxdY2lqcHF1dlUkbnVsbNMNDg8QFhxXTlMua2V5c1pOUy5vYmplY3RzViRjbGFzc6UREhMUFYACgAOABIAFgAalFxgZGhuAB4AIgAmAIYAigBlfEBdlZmZlY3RpdmVGdWxsc2NyZWVuTW9kZV5mb2N1c2VkU3VyZmFjZVtzdXJmYWNlVHJlZVh0YWJDb2xvcl10aXRsZU92ZXJyaWRlVm5hdGl2ZVp2NyBnZW5lcmlj0w0ODyUoHKImJ4AKgAuiKSqADIANgBlXdmVyc2lvblRyb290EAHTDQ4PMDIcoTGADqEzgA+AGVVzcGxpdNMNDg83PBykODk6O4AQgBGAEoATpD0+P0CAFIAagBuAHoAZVXJpZ2h0VXJhdGlvVGxlZnRZZGlyZWN0aW9u0w0OD0dJHKFIgBWhSoAWgBlUdmlld9MNDg9OUByhT4AXoVGAGIAZUmlkXxAkRDMyMjM1NjktMkUwMS00QkM1LTlEQjItREJGQzNBRkY0NkQx0lZXWFlaJGNsYXNzbmFtZVgkY2xhc3Nlc18QE05TTXV0YWJsZURpY3Rpb25hcnmjWFpbXE5TRGljdGlvbmFyeVhOU09iamVjdCM/4AAAAAAAANMNDg9eYByhSIAVoWGAHIAZ0w0OD2RmHKFPgBehZ4AdgBlfECQ5NTNDRTk1Mi1EOTFELTREMzYtQUM3Mi05RDBGMUY2QkNFNzPTDQ4Pa20coWyAH6FugCCAGVpob3Jpem9udGFs0w0OD3JzHKCggBkQB1N0aXAACAARABoAJAApADIANwBJAEwAUgBUAHoAgACHAI8AmgChAKcAqQCrAK0ArwCxALcAuQC7AL0AvwDBAMMA3QDsAPgBAQEPARYBIQEoASsBLQEvATIBNAE2ATgBQAFFAUcBTgFQAVIBVAFWAVgBXgFlAWoBbAFuAXABcgF3AXkBewF9AX8BgQGHAY0BkgGcAaMBpQGnAakBqwGtAbIBuQG7Ab0BvwHBAcMBxgHtAfIB/QIGAhwCIAItAjYCPwJGAkgCSgJMAk4CUAJXAlkCWwJdAl8CYQKIAo8CkQKTApUClwKZAqQCqwKsAq0CrwKxAAAAAAAAAgEAAAAAAAAAdwAAAAAAAAAAAAAAAAAAArXRExRaJGNsYXNzbmFtZV8QF0NvZGFibGVCcmlkZ2U8VGVybWluYWw+AAgAEQAaACQAKQAyADcASQBMAFEAUwBYAF4AYwBoAG8AcQBzBDoEPQRIAAAAAAAAAgEAAAAAAAAAFQAAAAAAAAAAAAAAAAAABGI=
    """)!

// MARK: - Terminal V8 (FLASH-Ghostty)

private let v8Data = Data(base64Encoded: """
    YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGkCwwRElUkbnVsbNINDg8QVGRhdGFWJGNsYXNzgAKAA08RA+ticGxpc3QwMNQBAgMEBQYHClgkdmVyc2lvblkkYXJjaGl2ZXJUJHRvcFgkb2JqZWN0cxIAAYagXxAPTlNLZXllZEFyY2hpdmVy0QgJVXZhbHVlgAGvECULDB8gISIjJCUmJy8wMTI4OUVGR0hJT1BWV1hfYGZsbXN0eHl6VSRudWxs0w0ODxAXHldOUy5rZXlzWk5TLm9iamVjdHNWJGNsYXNzphESExQVFoACgAOABIAFgAaAB6YYGRobHB2ACIAJgAqAIoAjgCSAGl8QF2VmZmVjdGl2ZUZ1bGxzY3JlZW5Nb2RlXmZvY3VzZWRTdXJmYWNlW3N1cmZhY2VUcmVlWHRhYkNvbG9yXXRpdGxlT3ZlcnJpZGVfEBdzZXNzaW9uU2lkZWJhcklzVmlzaWJsZVZuYXRpdmVSdjjTDQ4PKCseoikqgAuADKIsLYANgA6AGld2ZXJzaW9uVHJvb3QQAdMNDg8zNR6hNIAPoTaAEIAaVXNwbGl00w0ODzo/HqQ7PD0+gBGAEoATgBSkQEFCQ4AVgBuAHIAfgBpVcmlnaHRVcmF0aW9UbGVmdFlkaXJlY3Rpb27TDQ4PSkweoUuAFqFNgBeAGlR2aWV30w0OD1FTHqFSgBihVIAZgBpSaWRfECQ3RkEyMDZCNi0zRUU4LTQ3NDctQUZDMy1CMDFEM0JBOEY5QjLSWVpbXFokY2xhc3NuYW1lWCRjbGFzc2VzXxATTlNNdXRhYmxlRGljdGlvbmFyeaNbXV5cTlNEaWN0aW9uYXJ5WE5TT2JqZWN0Iz/gAAAAAAAA0w0OD2FjHqFLgBahZIAdgBrTDQ4PZ2keoVKAGKFqgB6AGl8QJDRDNUI4QkE1LTI1MzQtNDZGRC1CM0IzLTBDM0IxNzEwNDJCMNMNDg9ucB6hb4AgoXGAIYAaWmhvcml6b250YWzTDQ4PdXYeoKCAGhACWEZMQVNIIHY4CAAIABEAGgAkACkAMgA3AEkATABSAFQAfACCAIkAkQCcAKMAqgCsAK4AsACyALQAtgC9AL8AwQDDAMUAxwDJAMsA5QD0AQABCQEXATEBOAE7AUIBRQFHAUkBTAFOAVABUgFaAV8BYQFoAWoBbAFuAXABcgF4AX8BhAGGAYgBigGMAZEBkwGVAZcBmQGbAaEBpwGsAbYBvQG/AcEBwwHFAccBzAHTAdUB1wHZAdsB3QHgAgcCDAIXAiACNgI6AkcCUAJZAmACYgJkAmYCaAJqAnECcwJ1AncCeQJ7AqICqQKrAq0CrwKxArMCvgLFAsYCxwLJAssC1AAAAAAAAAIBAAAAAAAAAHsAAAAAAAAAAAAAAAAAAALV0RMUWiRjbGFzc25hbWVfEBdDb2RhYmxlQnJpZGdlPFRlcm1pbmFsPgAIABEAGgAkACkAMgA3AEkATABRAFMAWABeAGMAaABvAHEAcwRiBGUEcAAAAAAAAAIBAAAAAAAAABUAAAAAAAAAAAAAAAAAAASK
    """)!

// MARK: - Terminal V9 (FLASH-Ghostty)

private let v9ArchiveVersion = 9

/// Frozen at the v9 Codable payload boundary. Older binary fixtures above
/// protect bridge compatibility; this readable fixture makes schema drift in
/// v9's unversioned nested file-browser state explicit during review.
private let v9PayloadData = Data("""
    {
      "effectiveFullscreenMode": "native",
      "fileBrowser": {
        "isVisible": false,
        "selectedFileTypes": [
          {},
          { "fileExtension": "swift" }
        ]
      },
      "focusedSurface": "CB47B40E-6A18-45AE-AB1B-84126EC06E87",
      "sessionSidebarIsVisible": false,
      "surfaceTree": {
        "root": {
          "view": {
            "id": "CB47B40E-6A18-45AE-AB1B-84126EC06E87"
          }
        },
        "version": 1
      },
      "tabColor": 2,
      "titleOverride": "FLASH v9 fixture"
    }
    """.utf8)
