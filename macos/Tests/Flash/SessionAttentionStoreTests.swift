import Combine
import Foundation
import Testing
@testable import Ghostty

@Suite @MainActor
struct SessionAttentionStoreTests {
    @Test(arguments: [false, true])
    func subscriptionImmediatelyReceivesTheCurrentSessionSummary(hasAttention: Bool) {
        let session = UUID()
        let store = SessionAttentionStore()
        let expected = SessionAttentionSummary(hasUnreadCompletion: hasAttention)
        if hasAttention { store.update([session: expected]) }
        var values: [SessionAttentionSummary] = []
        let subscription = store.updates(for: session).sink { values.append($0) }
        defer { subscription.cancel() }
        #expect(values == [expected])
    }

    @Test func updatesAreDeduplicatedPerSessionIncludingReasonChangesAndOwnershipMoves() {
        let firstSession = UUID()
        let secondSession = UUID()
        let store = SessionAttentionStore()
        var firstValues: [SessionAttentionSummary] = []
        var secondValues: [SessionAttentionSummary] = []
        let firstSubscription = store.updates(for: firstSession).sink { firstValues.append($0) }
        let secondSubscription = store.updates(for: secondSession).sink { secondValues.append($0) }
        defer {
            firstSubscription.cancel()
            secondSubscription.cancel()
        }
        let empty = SessionAttentionSummary()
        let completion = SessionAttentionSummary(hasUnreadCompletion: true)
        let approval = SessionAttentionSummary(needsInput: true)
        store.update([firstSession: completion])
        store.update([firstSession: completion])
        #expect(firstValues == [empty, completion])
        #expect(secondValues == [empty])

        // The number of sessions needing attention stays one throughout.
        store.update([firstSession: approval])
        #expect(firstValues == [empty, completion, approval])
        #expect(secondValues == [empty])
        store.update([secondSession: approval])
        #expect(firstValues == [empty, completion, approval, empty])
        #expect(secondValues == [empty, approval])
        store.update([secondSession: approval])
        #expect(firstValues == [empty, completion, approval, empty])
        #expect(secondValues == [empty, approval])

        store.update([:])
        store.update([:])
        #expect(firstValues == [empty, completion, approval, empty])
        #expect(secondValues == [empty, approval, empty])
    }

    @Test func cancelledSubscriptionDoesNotReceiveLaterChanges() {
        let session = UUID()
        let store = SessionAttentionStore()
        var values: [SessionAttentionSummary] = []
        let subscription = store.updates(for: session).sink { values.append($0) }
        subscription.cancel()
        store.update([session: .init(needsInput: true)])
        store.update([:])
        #expect(values == [.init()])
    }
}
