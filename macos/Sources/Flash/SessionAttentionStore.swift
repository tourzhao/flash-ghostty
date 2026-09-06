import Combine
import Foundation

/// Fans out the tracker's projection without making every sidebar row observe
/// every session. Subscribing never starts a monitor or changes unread state.
@MainActor
final class SessionAttentionStore {
    private let summaries = CurrentValueSubject<[UUID: SessionAttentionSummary], Never>([:])

    func update(_ value: [UUID: SessionAttentionSummary]) {
        guard summaries.value != value else { return }
        summaries.send(value)
    }

    func updates(for sessionID: UUID) -> AnyPublisher<SessionAttentionSummary, Never> {
        summaries
            .map { $0[sessionID] ?? SessionAttentionSummary() }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
