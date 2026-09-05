import Combine
import Foundation

@MainActor
protocol SessionAttentionSource: AnyObject {
    var attentionUpdates: AnyPublisher<TerminalSessionActivitySnapshot, Never> { get }
    func startAttentionMonitoring()
    func stopAttentionMonitoring()
}

/// Owns subscriptions, not terminal views. A removed source cannot resurrect an
/// alert, even if an old publisher delivers another value during cancellation.
@MainActor
final class SessionAttentionTracker {
    private final class Registration {
        let source: any SessionAttentionSource
        var subscription: AnyCancellable?
        var wasViewed = false
        var lastViewedUptime: TimeInterval?

        init(source: any SessionAttentionSource) {
            self.source = source
        }
    }

    private var state = SessionAttentionState()
    private var registrations: [UUID: Registration] = [:]
    private var deadlineWork: DispatchWorkItem?
    private var scheduledDeadline: TimeInterval?
    private var publishedCount = 0
    private let makeSource: (UUID) -> (any SessionAttentionSource)?
    private let isViewed: (UUID) -> Bool
    private let countDidChange: (Int) -> Void
    private let now: () -> TimeInterval
    private let automaticallySchedule: Bool

    init(
        makeSource: @escaping (UUID) -> (any SessionAttentionSource)?,
        isViewed: @escaping (UUID) -> Bool,
        countDidChange: @escaping (Int) -> Void,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        automaticallySchedule: Bool = true
    ) {
        self.makeSource = makeSource
        self.isViewed = isViewed
        self.countDidChange = countDidChange
        self.now = now
        self.automaticallySchedule = automaticallySchedule
    }

    var count: Int { state.count }

    func reconcile(owners: [UUID: UUID]) {
        state.reconcile(owners: owners)
        for id in Array(registrations.keys) where owners[id] == nil {
            let removed = registrations.removeValue(forKey: id)
            removed?.subscription?.cancel()
            removed?.source.stopAttentionMonitoring()
        }
        for id in owners.keys where registrations[id] == nil {
            guard let source = makeSource(id) else { continue }
            let registration = Registration(source: source)
            registrations[id] = registration
            registration.subscription = source.attentionUpdates
                .sink { [weak self, weak registration] snapshot in
                    guard let self, let registration,
                          registrations[id] === registration else { return }
                    let uptime = now()
                    let viewed = recordVisibility(for: id, registration: registration, at: uptime)
                    let viewedAfterObservation = snapshot.observedAt.map { observedAt in
                        registration.lastViewedUptime.map { $0 >= observedAt } ?? false
                    } ?? false
                    state.update(
                        surfaceID: id,
                        tool: snapshot.tool,
                        status: snapshot.status,
                        isViewed: viewed || viewedAfterObservation,
                        now: snapshot.observedAt ?? uptime
                    )
                    state.advance(to: uptime)
                    refreshVisibility(at: uptime)
                }
            source.startAttentionMonitoring()
        }
        refreshVisibility()
    }

    func refreshVisibility() {
        refreshVisibility(at: now())
    }

    private func refreshVisibility(at uptime: TimeInterval) {
        for (id, registration) in registrations where recordVisibility(
            for: id, registration: registration, at: uptime
        ) {
            state.markViewed(surfaceID: id)
        }
        publishAndSchedule()
    }

    private func recordVisibility(for id: UUID, registration: Registration, at uptime: TimeInterval) -> Bool {
        let viewed = isViewed(id)
        // Keep the end of a viewing interval as well as visits while focused.
        // A completion can arrive before provider discovery, then be replayed
        // after the user has already read it and switched away.
        if viewed || registration.wasViewed {
            registration.lastViewedUptime = uptime
        }
        registration.wasViewed = viewed
        return viewed
    }

    /// Public inside the module so tests can drive the same deadline path with
    /// a deterministic clock instead of sleeping or manipulating a run loop.
    func advance() {
        let uptime = now()
        state.advance(to: uptime)
        refreshVisibility(at: uptime)
    }

    func stop() {
        reconcile(owners: [:])
        deadlineWork?.cancel()
        deadlineWork = nil
        scheduledDeadline = nil
    }

    private func publishAndSchedule() {
        if publishedCount != state.count {
            publishedCount = state.count
            countDidChange(publishedCount)
        }
        guard automaticallySchedule, scheduledDeadline != state.nextDeadline else { return }
        deadlineWork?.cancel()
        deadlineWork = nil
        scheduledDeadline = state.nextDeadline
        guard let deadline = scheduledDeadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            deadlineWork = nil
            scheduledDeadline = nil
            advance()
        }
        deadlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - now()), execute: work)
    }
}
