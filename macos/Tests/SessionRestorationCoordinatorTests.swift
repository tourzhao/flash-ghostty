import Testing
@testable import Ghostty

@Suite
struct SessionRestorationProcessRoleTests {
    @Test func recognizesInjectedXCTestConfiguration() {
        #expect(SessionRestorationProcessRole.isUnitTestHost(
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            loadedBundlePaths: []
        ))
    }

    @Test func recognizesLoadedTestBundle() {
        #expect(SessionRestorationProcessRole.isUnitTestHost(
            environment: [:],
            loadedBundlePaths: ["/tmp/GhosttyTests.xctest"]
        ))
    }

    @Test func ordinaryAndUITestedAppProcessesAreNotUnitTestHosts() {
        #expect(!SessionRestorationProcessRole.isUnitTestHost(
            environment: ["FLASH_GHOSTTY_UI_TEST_RUN_ID": "isolated-run"],
            loadedBundlePaths: ["/Applications/FLASH-Ghostty.app"]
        ))
    }
}

@MainActor
@Suite
struct SessionRestorationCoordinatorTests {
    @Test func launchPolicySeparatesAwaitAndDiscardPaths() {
        #expect(
            StartupRestorationPolicy.plan(
                restorationEnabled: false,
                archiveMarker: .available
            ) == .startFreshDiscardingArchive
        )
        #expect(
            StartupRestorationPolicy.plan(
                restorationEnabled: true,
                archiveMarker: .discarded
            ) == .startFreshDiscardingArchive
        )
        #expect(
            StartupRestorationPolicy.plan(
                restorationEnabled: true,
                archiveMarker: .available
            ) == .awaitUserDecision
        )
    }

    @Test func didFinishLaunchingOnlyInfersRequestFreeRestorationCompletion() {
        #expect(
            SessionRestorationLaunchMilestonePolicy
                .mayInferCompletionAtDidFinishLaunching(
                    notificationWasObserved: false,
                    hasPendingRequests: false
                )
        )
        #expect(
            !SessionRestorationLaunchMilestonePolicy
                .mayInferCompletionAtDidFinishLaunching(
                    notificationWasObserved: false,
                    hasPendingRequests: true
                )
        )
        #expect(
            !SessionRestorationLaunchMilestonePolicy
                .mayInferCompletionAtDidFinishLaunching(
                    notificationWasObserved: true,
                    hasPendingRequests: false
                )
        )
    }

    @Test func availableMarkerPresentsBeforeAppKitRestorationCallback() {
        let presenter = RecordingRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: RecordingSessionRestorationArchiveStore(
                marker: .available
            ),
            promptPresenter: presenter
        )

        coordinator.prepareLaunch(
            restorationEnabled: true
        )

        #expect(presenter.presentationCount == 1)
        #expect(coordinator.isPromptActive)
        #expect(!coordinator.hasPendingRequests)
    }

    @Test func legacyMarkerWaitsForAnObservedPayloadBeforePrompting() {
        let presenter = RecordingRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: RecordingSessionRestorationArchiveStore(
                marker: .legacy
            ),
            promptPresenter: presenter
        )

        coordinator.prepareLaunch(
            restorationEnabled: true
        )
        #expect(presenter.presentationCount == 0)

        coordinator.enqueue(restore: {}, discard: {})
        #expect(presenter.presentationCount == 1)
        #expect(coordinator.isPromptActive)
    }

    @Test func executeCommandLaunchNeverMutatesPreviousArchiveMarker() throws {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let presenter = RecordingRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter
        )

        let isolation = try #require(appKitOuterArchiveIsolation)
        coordinator.prepareLaunch(
            outerArchiveIsolation: isolation,
            restorationEnabled: false
        )

        #expect(coordinator.decision == .startFresh)
        #expect(coordinator.preservesArchiveForLaunch)
        #expect(coordinator.preservesExistingArchive)
        #expect(!coordinator.shouldCancelTermination)
        #expect(!coordinator.shouldInvalidateSavedState)
        #expect(store.marker == .available)
        #expect(store.writes.isEmpty)
        #expect(presenter.presentationCount == 0)

        var discardedRequest = false
        coordinator.enqueue(
            restore: { Issue.record("one-shot launch restored an old workspace") },
            discard: { discardedRequest = true }
        )
        coordinator.recordArchiveAvailability(false)
        coordinator.discardArchiveBecauseRestorationIsDisabled()

        #expect(discardedRequest)
        #expect(store.marker == .available)
        #expect(store.writes.isEmpty)
    }

    @Test func pendingMaterializationCannotTombstoneAvailableArchive() {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let presenter = RecordingRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter
        )
        coordinator.prepareLaunch(
            restorationEnabled: true
        )

        coordinator.enqueue(restore: {}, discard: {})

        #expect(coordinator.hasPendingRequests)
        #expect(coordinator.isPromptActive)
        #expect(coordinator.preservesExistingArchive)

        // This is the exact lifecycle race: AppKit asks the not-yet-restored
        // process to encode or terminate, and its current workspace is empty.
        coordinator.recordArchiveAvailability(false)

        #expect(store.marker == .available)
        #expect(store.writes.isEmpty)
    }

    @Test func isolatedRequestFreeLaunchCannotTombstoneAvailableArchive() throws {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: RecordingRestorationPromptPresenter()
        )
        let isolation = try #require(appKitOuterArchiveIsolation)
        coordinator.prepareLaunch(
            outerArchiveIsolation: isolation,
            restorationEnabled: true
        )

        #expect(coordinator.resolveNoPayloadIfPossible())
        #expect(coordinator.decision == .startFresh)
        #expect(!coordinator.shouldInvalidateSavedState)
        #expect(coordinator.archiveWritePolicy == .preserveExisting(isolation))
        #expect(!coordinator.allowsRestorableWindowCreation)
        #expect(store.marker == .available)
        #expect(store.writes.isEmpty)
    }

    @Test func missingIsolationCannotAcquirePreservePolicy() {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: RecordingRestorationPromptPresenter()
        )

        coordinator.prepareLaunch(
            outerArchiveIsolation: nil,
            restorationEnabled: false
        )

        #expect(coordinator.decision == .startFresh)
        #expect(coordinator.archiveWritePolicy == .ownCurrent)
        #expect(!coordinator.preservesArchiveForLaunch)
        #expect(store.writes == [.discarded])
    }

    @Test func quitIsCancelledOnlyUntilPromptDecision() {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let presenter = RecordingRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter
        )
        coordinator.prepareLaunch(
            restorationEnabled: true
        )

        // Protect the narrow interval before AppKit delivers its first window
        // payload as well as the visible-prompt interval after enqueue.
        #expect(coordinator.shouldCancelTermination)
        coordinator.enqueue(restore: {}, discard: {})
        #expect(coordinator.shouldCancelTermination)

        presenter.respond(with: .restore)

        #expect(!coordinator.shouldCancelTermination)
        #expect(coordinator.preservesExistingArchive)
        #expect(coordinator.allowsRestorableWindowCreation)
        coordinator.restorationMilestoneCompleted()
        #expect(!coordinator.preservesExistingArchive)
        #expect(store.marker == .available)
        #expect(store.writes.isEmpty)
    }

    @Test func systemTerminationOverridesPendingPromptWithoutMutatingArchiveMarker() {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let presenter = RecordingRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter
        )
        coordinator.prepareLaunch(
            restorationEnabled: true
        )
        coordinator.enqueue(restore: {}, discard: {})

        #expect(
            SessionRestorationTerminationPolicy.disposition(
                isSystemTermination: true,
                isAwaitingUserDecision: coordinator.shouldCancelTermination
            ) == .terminateNow
        )
        #expect(
            SessionRestorationTerminationPolicy.disposition(
                isSystemTermination: false,
                isAwaitingUserDecision: coordinator.shouldCancelTermination
            ) == .cancel
        )

        // The termination callbacks see an intentionally empty workspace. The
        // coordinator must neither tombstone the prior marker nor request an
        // app-level persistence write while that workspace remains gated.
        coordinator.recordArchiveAvailability(false)
        #expect(coordinator.preservesExistingArchive)
        #expect(store.marker == .available)
        #expect(store.writes.isEmpty)
    }

    @Test func asyncPromptResolvesEveryQueuedMaterializationOnce() {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let presenter = RecordingRestorationPromptPresenter()
        var decisions: [SessionRestorationDecision] = []
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter,
            didResolveFromPrompt: { decisions.append($0) }
        )
        coordinator.prepareLaunch(
            restorationEnabled: true
        )
        coordinator.applicationLaunchCompleted()

        var events: [String] = []
        coordinator.enqueue(
            restore: { events.append("restore-1") },
            discard: { events.append("discard-1") }
        )
        coordinator.enqueue(
            restore: { events.append("restore-2") },
            discard: { events.append("discard-2") }
        )

        #expect(presenter.presentationCount == 1)
        #expect(coordinator.isPromptActive)
        #expect(events.isEmpty)

        presenter.respond(with: .restore)

        #expect(events == ["restore-1", "restore-2"])
        #expect(decisions == [.restore])
        #expect(coordinator.decision == .restore)
        #expect(!coordinator.isPromptActive)
        #expect(store.writes.isEmpty)
    }

    @Test func startFreshTombstonesAndInvalidatesSavedState() {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let presenter = RecordingRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter
        )
        coordinator.prepareLaunch(
            restorationEnabled: true
        )

        var discarded = false
        coordinator.enqueue(
            restore: { Issue.record("discarded archive was materialized") },
            discard: { discarded = true }
        )
        presenter.respond(with: .startFresh)

        #expect(discarded)
        #expect(store.marker == .discarded)
        #expect(store.writes == [.discarded])
        #expect(coordinator.shouldInvalidateSavedState)
        #expect(!coordinator.shouldCancelTermination)
        #expect(!coordinator.preservesExistingArchive)
    }

    @Test func soleProcessWithNoPayloadKeepsExplicitRestoreChoice() {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let presenter = RecordingRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter
        )
        coordinator.prepareLaunch(
            restorationEnabled: true
        )

        #expect(!coordinator.resolveNoPayloadIfPossible())
        #expect(coordinator.isPromptActive)

        presenter.respond(with: .startFresh)

        #expect(coordinator.archiveWritePolicy == .ownCurrent)
        #expect(coordinator.shouldInvalidateSavedState)
        #expect(coordinator.allowsRestorableWindowCreation)
        #expect(store.writes == [.discarded])
    }

    @Test func archiveWritesRequireCurrentProcessOwnership() {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let presenter = RecordingRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter
        )
        coordinator.prepareLaunch(
            restorationEnabled: true
        )
        coordinator.enqueue(restore: {}, discard: {})
        presenter.respond(with: .restore)

        #expect(!coordinator.mayEncodeCurrentArchive())
        coordinator.recordArchiveAvailability(false)
        #expect(store.writes.isEmpty)

        coordinator.restorationMilestoneCompleted()
        #expect(coordinator.mayEncodeCurrentArchive())
        coordinator.recordArchiveAvailability(true)
        #expect(store.writes == [.available])
    }

    @Test func deferredTerminalLaunchesReplayAfterRestorationInOrder() {
        let presenter = RecordingRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: RecordingSessionRestorationArchiveStore(
                marker: .available
            ),
            promptPresenter: presenter
        )
        coordinator.prepareLaunch(
            restorationEnabled: true
        )
        coordinator.applicationLaunchCompleted()

        var events: [String] = []
        coordinator.enqueue(
            restore: { events.append("restore") },
            discard: { events.append("discard") }
        )
        #expect(
            coordinator.deferTerminalLaunchIfNeeded {
                events.append("launch-1")
            }
        )
        #expect(
            coordinator.deferTerminalLaunchIfNeeded {
                events.append("launch-2")
            }
        )
        #expect(events.isEmpty)
        #expect(coordinator.hasDeferredTerminalLaunches)

        presenter.respond(with: .restore)

        #expect(events == ["restore", "launch-1", "launch-2"])
        #expect(!coordinator.hasDeferredTerminalLaunches)
        #expect(!coordinator.isTerminalLaunchDeferred)
    }

    @Test func launchQueuedBeforePreparationReplaysAfterImmediatePolicy() {
        var didLaunch = false
        let coordinator = SessionRestorationCoordinator(
            archiveStore: RecordingSessionRestorationArchiveStore(
                marker: .discarded
            ),
            promptPresenter: RecordingRestorationPromptPresenter()
        )

        #expect(
            coordinator.deferTerminalLaunchIfNeeded {
                didLaunch = true
            }
        )
        #expect(!didLaunch)

        coordinator.prepareLaunch(
            restorationEnabled: true
        )

        #expect(!didLaunch)
        coordinator.applicationLaunchCompleted()
        #expect(didLaunch)
        #expect(coordinator.archiveWritePolicy == .ownCurrent)
    }
}

private final class RecordingSessionRestorationArchiveStore:
    SessionRestorationArchiveStoring {
    private(set) var marker: SessionRestorationArchiveMarker
    private(set) var writes: [SessionRestorationArchiveMarker] = []

    init(marker: SessionRestorationArchiveMarker) {
        self.marker = marker
    }

    func store(_ marker: SessionRestorationArchiveMarker) {
        self.marker = marker
        writes.append(marker)
    }
}

@MainActor
private final class RecordingRestorationPromptPresenter:
    SessionRestorationPromptPresenting {
    private var completion: ((SessionRestorationDecision) -> Void)?
    private(set) var presentationCount = 0

    func present(
        completion: @escaping (SessionRestorationDecision) -> Void
    ) {
        presentationCount += 1
        self.completion = completion
    }

    func respond(with decision: SessionRestorationDecision) {
        let completion = self.completion
        self.completion = nil
        completion?(decision)
    }
}
