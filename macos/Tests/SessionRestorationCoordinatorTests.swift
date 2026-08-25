import Testing
@testable import Ghostty

@MainActor
@Suite
struct SessionRestorationCoordinatorTests {
    @Test func launchPolicySeparatesPreserveAndDiscardPaths() {
        #expect(
            StartupRestorationPolicy.plan(
                launchedWithExecuteCommand: true,
                restorationEnabled: false,
                archiveMarker: .available
            ) == .startFreshPreservingArchive
        )
        #expect(
            StartupRestorationPolicy.plan(
                launchedWithExecuteCommand: false,
                restorationEnabled: false,
                archiveMarker: .available
            ) == .startFreshDiscardingArchive
        )
        #expect(
            StartupRestorationPolicy.plan(
                launchedWithExecuteCommand: false,
                restorationEnabled: true,
                archiveMarker: .discarded
            ) == .startFreshDiscardingArchive
        )
        #expect(
            StartupRestorationPolicy.plan(
                launchedWithExecuteCommand: false,
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

    @Test func executeCommandLaunchNeverMutatesPreviousArchiveMarker() {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let presenter = RecordingSessionRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter
        )

        coordinator.prepareLaunch(
            launchedWithExecuteCommand: true,
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
        let presenter = RecordingSessionRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter
        )
        coordinator.prepareLaunch(
            launchedWithExecuteCommand: false,
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

    @Test func quitIsCancelledOnlyUntilPromptDecision() {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let presenter = RecordingSessionRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter
        )
        coordinator.prepareLaunch(
            launchedWithExecuteCommand: false,
            restorationEnabled: true
        )

        // Protect the narrow interval before AppKit delivers its first window
        // payload as well as the visible-prompt interval after enqueue.
        #expect(coordinator.shouldCancelTermination)
        coordinator.enqueue(restore: {}, discard: {})
        #expect(coordinator.shouldCancelTermination)

        presenter.respond(with: .restore)

        #expect(!coordinator.shouldCancelTermination)
        #expect(!coordinator.preservesExistingArchive)
        #expect(store.marker == .available)
        #expect(store.writes.isEmpty)
    }

    @Test func systemTerminationOverridesPendingPromptWithoutMutatingArchiveMarker() {
        let store = RecordingSessionRestorationArchiveStore(marker: .available)
        let presenter = RecordingSessionRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter
        )
        coordinator.prepareLaunch(
            launchedWithExecuteCommand: false,
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
        let presenter = RecordingSessionRestorationPromptPresenter()
        var decisions: [SessionRestorationDecision] = []
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter,
            didResolveFromPrompt: { decisions.append($0) }
        )
        coordinator.prepareLaunch(
            launchedWithExecuteCommand: false,
            restorationEnabled: true
        )

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
        let presenter = RecordingSessionRestorationPromptPresenter()
        let coordinator = SessionRestorationCoordinator(
            archiveStore: store,
            promptPresenter: presenter
        )
        coordinator.prepareLaunch(
            launchedWithExecuteCommand: false,
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
private final class RecordingSessionRestorationPromptPresenter:
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
