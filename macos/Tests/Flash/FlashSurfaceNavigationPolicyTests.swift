import Testing
@testable import Ghostty

@Suite
struct FlashSurfaceNavigationPolicyTests {
    @Test func navigationActionsEncodeCoreBindingNames() {
        #expect(
            FlashSurfaceNavigationAction.scrollToBottom.bindingAction ==
                "scroll_to_bottom"
        )
        #expect(
            FlashSurfaceNavigationAction.scrollToRow(90).bindingAction ==
                "scroll_to_row:90"
        )
        #expect(
            FlashSurfaceNavigationAction.scrollToRow(UInt64.max).bindingAction ==
                "scroll_to_row:\(UInt64.max)"
        )
    }

    @Test func hidesWhenThereIsNoScrollableHistory() {
        #expect(
            !FlashSurfaceNavigationPolicy.isScrollToBottomVisible(
                total: 24,
                offset: 0,
                length: 24
            )
        )
        #expect(
            !FlashSurfaceNavigationPolicy.isScrollToBottomVisible(
                total: 12,
                offset: 0,
                length: 24
            )
        )
        #expect(
            !FlashSurfaceNavigationPolicy.isScrollToBottomVisible(
                total: 12,
                offset: 0,
                length: 0
            )
        )
    }

    @Test func showsOnlyWhenTheViewportIsAboveTheBottom() {
        #expect(
            FlashSurfaceNavigationPolicy.isScrollToBottomVisible(
                total: 100,
                offset: 75,
                length: 24
            )
        )
        #expect(
            !FlashSurfaceNavigationPolicy.isScrollToBottomVisible(
                total: 100,
                offset: 76,
                length: 24
            )
        )
    }

    @Test func historyReportsItsExactBottomOffset() {
        #expect(
            FlashSurfaceHistoryShape(total: 100, length: 24).bottomOffset == 76
        )
        #expect(
            FlashSurfaceHistoryShape(total: 24, length: 24).bottomOffset == 0
        )
        #expect(
            FlashSurfaceHistoryShape(total: 12, length: 24).bottomOffset == nil
        )
        #expect(
            FlashSurfaceHistoryShape(total: 12, length: 0).bottomOffset == nil
        )
    }

    @Test func hidesForAnOffsetBeyondTheBottom() {
        #expect(
            !FlashSurfaceNavigationPolicy.isScrollToBottomVisible(
                total: 100,
                offset: 100,
                length: 24
            )
        )
    }

    @Test func handlesMaximumValuesWithoutOverflow() {
        #expect(
            FlashSurfaceNavigationPolicy.isScrollToBottomVisible(
                total: UInt64.max,
                offset: 0,
                length: 1
            )
        )
        #expect(
            !FlashSurfaceNavigationPolicy.isScrollToBottomVisible(
                total: UInt64.max,
                offset: UInt64.max - 1,
                length: 1
            )
        )
    }

    @Test func presentationEnablesPinsOnlyForScrollableHistory() {
        let empty = FlashSurfaceNavigationPresentation(
            history: FlashSurfaceHistoryShape(total: 24, length: 24),
            offset: 0
        )
        #expect(!empty.isPinningAvailable)
        #expect(!empty.isScrollToBottomVisible)

        let history = FlashSurfaceNavigationPresentation(
            history: FlashSurfaceHistoryShape(total: 100, length: 24),
            offset: 40
        )
        #expect(history.isPinningAvailable)
        #expect(history.isScrollToBottomVisible)

        let activeArea = FlashSurfaceNavigationPresentation(
            history: FlashSurfaceHistoryShape(total: 100, length: 24),
            offset: 76
        )
        #expect(!activeArea.isPinningAvailable)
        #expect(!activeArea.isScrollToBottomVisible)
    }

    @Test func scrollbarUpdateCombinesPresentationAndPinInvalidation() {
        let initial = FlashSurfaceHistoryShape(total: 100, length: 24)
        var accumulator = FlashSurfaceNavigationUpdateAccumulator(
            initialHistory: initial
        )

        let normalGrowth = accumulator.update(
            history: FlashSurfaceHistoryShape(total: 120, length: 24),
            offset: 96
        )
        #expect(!normalGrowth.invalidatesPins)
        #expect(!normalGrowth.presentation.isScrollToBottomVisible)
        #expect(!normalGrowth.presentation.isPinningAvailable)

        let historyReset = accumulator.update(
            history: FlashSurfaceHistoryShape(total: 90, length: 24),
            offset: 20
        )
        #expect(historyReset.invalidatesPins)
        #expect(historyReset.presentation.isScrollToBottomVisible)

        let resize = accumulator.update(
            history: FlashSurfaceHistoryShape(total: 90, length: 30),
            offset: 20
        )
        #expect(resize.invalidatesPins)
    }

    @Test func firstScrollbarUpdateDoesNotInvalidatePins() {
        var accumulator = FlashSurfaceNavigationUpdateAccumulator(
            initialHistory: nil
        )

        let update = accumulator.update(
            history: FlashSurfaceHistoryShape(total: 100, length: 24),
            offset: 10
        )
        #expect(!update.invalidatesPins)
        #expect(update.presentation.isScrollToBottomVisible)
    }

    @Test func coalescedPruneAndGrowthInvalidatesPinsByContentIdentity() {
        let before = FlashSurfaceHistoryShape(
            total: 120,
            length: 24,
            contentGeneration: 7
        )
        var accumulator = FlashSurfaceNavigationUpdateAccumulator(
            initialHistory: before
        )

        // A full history page was pruned and equal new output arrived between
        // UI samples. Geometry is identical, but the same row no longer names
        // the same terminal content.
        let update = accumulator.update(
            history: FlashSurfaceHistoryShape(
                total: 120,
                length: 24,
                contentGeneration: 8
            ),
            offset: 96
        )

        #expect(update.invalidatesPins)
        #expect(update.snapshot.history.total == before.total)
        #expect(update.snapshot.history.length == before.length)
    }

    @Test func frameCoalescingKeepsLatestSnapshotAndAnyInvalidation() {
        var accumulator = FlashSurfaceNavigationUpdateAccumulator(
            initialHistory: FlashSurfaceHistoryShape(
                total: 100,
                length: 24
            )
        )

        let update = accumulator.coalescing([
            // A short-lived reset would be lost if a latest-only throttle
            // discarded this intermediate sample.
            FlashSurfaceNavigationSample(
                history: FlashSurfaceHistoryShape(total: 80, length: 24),
                offset: 10
            ),
            FlashSurfaceNavigationSample(
                history: FlashSurfaceHistoryShape(total: 100, length: 24),
                offset: 76
            ),
        ])

        #expect(update?.invalidatesPins == true)
        #expect(update?.snapshot.history.total == 100)
        #expect(update?.snapshot.offset == 76)
        #expect(accumulator.coalescing([]) == nil)
    }

    @Test func pinlessGeometryBurstNeverFetchesCoreSnapshot() {
        let cachedHistory = FlashSurfaceHistoryShape(
            total: 20_000,
            length: 24,
            contentGeneration: 41,
            screenIdentity: 7
        )
        var fetchCount = 0
        var latest: FlashSurfaceNavigationResolvedSample?

        for rawOffset in 0..<10_000 {
            latest = FlashSurfaceNavigationSampleResolver.resolve(
                geometry: FlashSurfaceScrollbarGeometry(
                    total: 20_000,
                    offset: UInt64(rawOffset),
                    length: 24
                ),
                cachedHistory: cachedHistory,
                requiresHistoryIdentity: false,
                fetchSnapshot: {
                    fetchCount += 1
                    return .empty
                }
            )
        }

        #expect(fetchCount == 0)
        #expect(latest?.identitySource == .cached)
        #expect(latest?.sample.offset == 9_999)
        #expect(latest?.sample.history.contentGeneration == 41)
        #expect(latest?.sample.history.screenIdentity == 7)
    }

    @Test func activePinRefreshDetectsEqualGeometryIdentityChange() {
        let previousHistory = FlashSurfaceHistoryShape(
            total: 100,
            length: 24,
            contentGeneration: 7,
            screenIdentity: 2
        )
        let refreshedSnapshot = FlashSurfaceNavigationSnapshot(
            history: FlashSurfaceHistoryShape(
                total: 100,
                length: 24,
                contentGeneration: 8,
                screenIdentity: 2
            ),
            offset: 20
        )
        var fetchCount = 0

        let resolved = FlashSurfaceNavigationSampleResolver.resolve(
            geometry: FlashSurfaceScrollbarGeometry(
                total: 100,
                offset: 20,
                length: 24
            ),
            cachedHistory: previousHistory,
            requiresHistoryIdentity: true,
            fetchSnapshot: {
                fetchCount += 1
                return refreshedSnapshot
            }
        )
        var accumulator = FlashSurfaceNavigationUpdateAccumulator(
            initialHistory: previousHistory
        )
        let update = accumulator.update(
            history: resolved.sample.history,
            offset: resolved.sample.offset
        )

        #expect(fetchCount == 1)
        #expect(resolved.identitySource == .authoritative)
        #expect(resolved.sample.snapshot == refreshedSnapshot)
        #expect(update.invalidatesPins)
    }

    @Test func pinSlotsAreStableAndReuseTheLowestAvailableNumber() {
        let history = FlashSurfaceHistoryShape(total: 100, length: 10)
        var state = FlashSurfacePinState()

        for number in 1...FlashSurfacePinState.maximumCount {
            let row = UInt64(number * 10)
            #expect(
                state.add(row: row, within: history) ==
                    .added(FlashSurfacePin(number: number, row: row))
            )
        }

        #expect(!state.canAddPin)
        #expect(state.add(row: 70, within: history) == .full)
        #expect(state.pins.map(\.number) == [1, 2, 3, 4, 5])

        let removed = state.remove(number: 2)
        #expect(removed)
        #expect(state.pins.map(\.number) == [1, 3, 4, 5])
        #expect(
            state.add(row: 70, within: history) ==
                .added(FlashSurfacePin(number: 2, row: 70))
        )
        #expect(state.pins.map(\.number) == [1, 2, 3, 4, 5])
    }

    @Test func duplicateAndUnavailablePinsDoNotChangeState() {
        let history = FlashSurfaceHistoryShape(total: 100, length: 10)
        var state = FlashSurfacePinState()

        #expect(
            state.add(row: 25, within: history) ==
                .added(FlashSurfacePin(number: 1, row: 25))
        )
        #expect(
            state.add(row: 25, within: history) ==
                .duplicate(FlashSurfacePin(number: 1, row: 25))
        )
        #expect(
            state.add(
                row: 0,
                within: FlashSurfaceHistoryShape(total: 24, length: 24)
            ) == .unavailable
        )
        #expect(state.pins == [FlashSurfacePin(number: 1, row: 25)])
    }

    @Test func targetRowsNeverClampToDifferentContent() {
        let initialHistory = FlashSurfaceHistoryShape(total: 100, length: 10)
        var state = FlashSurfacePinState()
        _ = state.add(row: 89, within: initialHistory)

        #expect(state.targetRow(for: 1, within: initialHistory) == 89)
        #expect(
            state.targetRow(
                for: 1,
                within: FlashSurfaceHistoryShape(total: 80, length: 10)
            ) == nil
        )
        #expect(state.targetRow(for: 2, within: initialHistory) == nil)
    }

    @Test func pinTargetsRequireTheSameContentGeneration() {
        let original = FlashSurfaceHistoryShape(
            total: 100,
            length: 10,
            contentGeneration: 41
        )
        var state = FlashSurfacePinState()

        #expect(
            state.add(row: 40, within: original) ==
                .added(FlashSurfacePin(
                    number: 1,
                    row: 40,
                    contentGeneration: 41
                ))
        )
        #expect(state.targetRow(for: 1, within: original) == 40)
        #expect(
            state.targetRow(
                for: 1,
                within: FlashSurfaceHistoryShape(
                    total: 100,
                    length: 10,
                    contentGeneration: 42
                )
            ) == nil
        )
    }

    @Test func equalGeometryAcrossScreensInvalidatesPinIdentity() {
        let primary = FlashSurfaceHistoryShape(
            total: 100,
            length: 10,
            contentGeneration: 4,
            screenIdentity: 0
        )
        let alternate = FlashSurfaceHistoryShape(
            total: 100,
            length: 10,
            contentGeneration: 4,
            screenIdentity: 1
        )
        var state = FlashSurfacePinState()
        _ = state.add(row: 40, within: primary)

        #expect(
            FlashSurfaceHistoryShape.shouldInvalidatePins(
                previous: primary,
                current: alternate
            )
        )
        #expect(state.targetRow(for: 1, within: alternate) == nil)
    }

    @Test func historyInvalidationDetectsResizeAndReset() {
        let initial = FlashSurfaceHistoryShape(total: 100, length: 24)

        #expect(
            !FlashSurfaceHistoryShape.shouldInvalidatePins(
                previous: initial,
                current: FlashSurfaceHistoryShape(total: 120, length: 24)
            )
        )
        #expect(
            FlashSurfaceHistoryShape.shouldInvalidatePins(
                previous: initial,
                current: FlashSurfaceHistoryShape(total: 90, length: 24)
            )
        )
        #expect(
            FlashSurfaceHistoryShape.shouldInvalidatePins(
                previous: initial,
                current: FlashSurfaceHistoryShape(total: 100, length: 30)
            )
        )
    }

    @Test func pinBoundariesDoNotOverflow() {
        let maximumHistory = FlashSurfaceHistoryShape(
            total: UInt64.max,
            length: 1
        )

        #expect(maximumHistory.containsHistoryOffset(UInt64.max - 2))
        #expect(!maximumHistory.containsHistoryOffset(UInt64.max - 1))
        #expect(!maximumHistory.containsHistoryOffset(UInt64.max))
        #expect(
            !FlashSurfaceHistoryShape(total: 1, length: 0)
                .containsHistoryOffset(0)
        )
    }

    @Test func pinsRejectTheActiveAreaBoundary() {
        let history = FlashSurfaceHistoryShape(total: 100, length: 24)
        var state = FlashSurfacePinState()

        #expect(
            state.add(row: 75, within: history) ==
                .added(FlashSurfacePin(number: 1, row: 75))
        )
        #expect(state.add(row: 76, within: history) == .unavailable)
        #expect(state.targetRow(for: 1, within: history) == 75)
    }

    @Test @MainActor func gridSizeChangesClearPins() {
        let model = FlashSurfaceNavigationModel()
        let history = FlashSurfaceHistoryShape(total: 100, length: 10)

        model.updateGridSize(FlashSurfaceGridSize(columns: 80, rows: 24))
        _ = model.addPin(row: 20, within: history)
        model.updateGridSize(FlashSurfaceGridSize(columns: 80, rows: 24))
        #expect(model.pins.count == 1)

        model.updateGridSize(FlashSurfaceGridSize(columns: 81, rows: 24))
        #expect(model.pins.isEmpty)
    }

    @Test @MainActor func idleNavigationModelSchedulesNoFrameDrain() {
        var scheduledDrains: [FlashSurfaceNavigationModel.FrameDrain] = []
        _ = FlashSurfaceNavigationModel { drain in
            scheduledDrains.append(drain)
        }

        #expect(scheduledDrains.isEmpty)
    }

    @Test @MainActor func scrollbarBurstSchedulesOnlyOneFrameDrain() {
        var scheduledDrains: [FlashSurfaceNavigationModel.FrameDrain] = []
        let model = FlashSurfaceNavigationModel { drain in
            scheduledDrains.append(drain)
        }
        let history = FlashSurfaceHistoryShape(total: 100, length: 24)

        model.enqueue(FlashSurfaceNavigationSample(history: history, offset: 10))
        model.enqueue(FlashSurfaceNavigationSample(history: history, offset: 20))
        model.enqueue(FlashSurfaceNavigationSample(history: history, offset: 30))

        #expect(scheduledDrains.count == 1)
    }

    @Test @MainActor func frameDrainKeepsLatestSampleAndAnyInvalidation() {
        var scheduledDrains: [FlashSurfaceNavigationModel.FrameDrain] = []
        let model = FlashSurfaceNavigationModel { drain in
            scheduledDrains.append(drain)
        }
        let initial = FlashSurfaceHistoryShape(total: 100, length: 24)
        model.setSnapshot(FlashSurfaceNavigationSnapshot(
            history: initial,
            offset: 20
        ))
        _ = model.addPin(row: 20, within: initial)

        model.enqueue(FlashSurfaceNavigationSample(
            history: FlashSurfaceHistoryShape(total: 80, length: 24),
            offset: 10
        ))
        model.enqueue(FlashSurfaceNavigationSample(
            history: FlashSurfaceHistoryShape(total: 100, length: 24),
            offset: 76
        ))

        #expect(scheduledDrains.count == 1)
        #expect(model.latestSnapshot.offset == 20)
        #expect(model.pins.count == 1)

        scheduledDrains.removeFirst()()

        #expect(model.latestSnapshot.history.total == 100)
        #expect(model.latestSnapshot.offset == 76)
        #expect(model.pins.isEmpty)
        #expect(scheduledDrains.isEmpty)
    }

    @Test @MainActor func directSnapshotSupersedesPendingFrame() {
        var scheduledDrains: [FlashSurfaceNavigationModel.FrameDrain] = []
        let model = FlashSurfaceNavigationModel { drain in
            scheduledDrains.append(drain)
        }
        let history = FlashSurfaceHistoryShape(total: 100, length: 24)

        model.enqueue(FlashSurfaceNavigationSample(history: history, offset: 10))
        model.setSnapshot(FlashSurfaceNavigationSnapshot(
            history: history,
            offset: 40
        ))
        scheduledDrains.removeFirst()()

        #expect(model.latestSnapshot.offset == 40)
    }

    @Test @MainActor func pinCreationUsesImmediateCoreSnapshot() {
        var scheduledDrains: [FlashSurfaceNavigationModel.FrameDrain] = []
        let model = FlashSurfaceNavigationModel { drain in
            scheduledDrains.append(drain)
        }
        let history = FlashSurfaceHistoryShape(
            total: 100,
            length: 24,
            contentGeneration: 7,
            screenIdentity: 2
        )
        model.setSnapshot(FlashSurfaceNavigationSnapshot(
            history: history,
            offset: 20
        ))
        model.enqueue(FlashSurfaceNavigationSample(
            history: history,
            offset: 30
        ))

        let result = model.addPin(at: FlashSurfaceNavigationSnapshot(
            history: history,
            offset: 40
        ))

        #expect(result == .added(FlashSurfacePin(
            number: 1,
            row: 40,
            contentGeneration: 7,
            screenIdentity: 2
        )))
        #expect(model.latestSnapshot.offset == 40)
        #expect(model.pins.first?.row == 40)
        #expect(scheduledDrains.count == 1)

        // The callback already scheduled by the stale sample must be harmless.
        scheduledDrains.removeFirst()()
        #expect(model.latestSnapshot.offset == 40)
    }

    @Test @MainActor func unavailableIdentityWithActivePinFailsClosed() {
        var scheduledDrains: [FlashSurfaceNavigationModel.FrameDrain] = []
        let model = FlashSurfaceNavigationModel { drain in
            scheduledDrains.append(drain)
        }
        let history = FlashSurfaceHistoryShape(
            total: 100,
            length: 24,
            contentGeneration: 7,
            screenIdentity: 2
        )
        model.setSnapshot(FlashSurfaceNavigationSnapshot(
            history: history,
            offset: 20
        ))
        _ = model.addPin(row: 20, within: history)

        let resolved = FlashSurfaceNavigationSampleResolver.resolve(
            geometry: FlashSurfaceScrollbarGeometry(
                total: 100,
                offset: 21,
                length: 24
            ),
            cachedHistory: history,
            requiresHistoryIdentity: true,
            fetchSnapshot: { nil }
        )
        model.enqueue(resolved)

        #expect(resolved.identitySource == .unavailable)
        #expect(model.pins.isEmpty)
        #expect(scheduledDrains.count == 1)
    }

    @Test @MainActor func latestSnapshotDrivesPinCreationAndNavigation() {
        let model = FlashSurfaceNavigationModel()
        let history = FlashSurfaceHistoryShape(total: 100, length: 24)

        model.apply(FlashSurfaceNavigationUpdate(
            snapshot: FlashSurfaceNavigationSnapshot(
                history: history,
                offset: 20
            ),
            invalidatesPins: false
        ))
        #expect(model.presentation.isScrollToBottomVisible)
        #expect(model.presentation.isPinningAvailable)
        #expect(
            model.addPin(
                row: model.latestSnapshot.offset,
                within: model.latestSnapshot.history
            ) == .added(FlashSurfacePin(number: 1, row: 20))
        )

        // A later scrollbar sample changes the current viewport, while the pin
        // keeps its original absolute target.
        model.apply(FlashSurfaceNavigationUpdate(
            snapshot: FlashSurfaceNavigationSnapshot(
                history: history,
                offset: 60
            ),
            invalidatesPins: false
        ))
        #expect(model.latestSnapshot.offset == 60)
        #expect(model.targetRow(for: 1) == 20)

        // A successful button action updates the same source immediately,
        // rather than waiting for a second observer-owned cache.
        model.updateCurrentOffset(20)
        #expect(model.latestSnapshot.offset == 20)

        model.removePin(number: 1)
        #expect(model.pins.isEmpty)
        #expect(model.targetRow(for: 1) == nil)
    }

    @Test @MainActor func snapshotUpdateInvalidatesPinsOnHistoryReset() {
        let model = FlashSurfaceNavigationModel()
        let history = FlashSurfaceHistoryShape(total: 100, length: 24)
        model.setSnapshot(FlashSurfaceNavigationSnapshot(
            history: history,
            offset: 20
        ))
        _ = model.addPin(row: 20, within: history)

        model.apply(FlashSurfaceNavigationUpdate(
            snapshot: FlashSurfaceNavigationSnapshot(
                history: FlashSurfaceHistoryShape(total: 80, length: 24),
                offset: 10
            ),
            invalidatesPins: true
        ))

        #expect(model.pins.isEmpty)
        #expect(model.latestSnapshot.offset == 10)
    }

    @Test @MainActor func directSnapshotRefreshClearsPinsAfterMissedPrune() {
        let model = FlashSurfaceNavigationModel()
        let original = FlashSurfaceHistoryShape(
            total: 100,
            length: 24,
            contentGeneration: 9
        )
        model.setSnapshot(FlashSurfaceNavigationSnapshot(
            history: original,
            offset: 20
        ))
        _ = model.addPin(row: 20, within: original)

        // Overlay reconstruction can miss the notification that performed the
        // prune. setSnapshot must compare with the model's retained identity,
        // not rely solely on the publisher accumulator.
        model.setSnapshot(FlashSurfaceNavigationSnapshot(
            history: FlashSurfaceHistoryShape(
                total: 100,
                length: 24,
                contentGeneration: 10
            ),
            offset: 20
        ))

        #expect(model.pins.isEmpty)
    }

    @Test @MainActor func normalAppendKeepsPins() {
        let model = FlashSurfaceNavigationModel()
        let original = FlashSurfaceHistoryShape(
            total: 100,
            length: 24,
            contentGeneration: 9
        )
        model.setSnapshot(FlashSurfaceNavigationSnapshot(
            history: original,
            offset: 20
        ))
        _ = model.addPin(row: 20, within: original)

        model.setSnapshot(FlashSurfaceNavigationSnapshot(
            history: FlashSurfaceHistoryShape(
                total: 120,
                length: 24,
                contentGeneration: 9
            ),
            offset: 40
        ))

        #expect(model.pins.count == 1)
        #expect(model.targetRow(for: 1) == 20)
    }
}
