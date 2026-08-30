import Foundation

enum SessionContentsRefreshDecision: Equatable, Sendable {
    case deferUntilScrollingStops
    case reuseSnapshot
    case refreshSnapshot
}

/// Keeps Claude active-screen refreshes away from active scrolling and bounds
/// how often stable sessions reacquire the renderer lock.
enum SessionContentsRefreshPolicy {
    static let scrollCooldown: TimeInterval = 0.35
    static let refreshInterval: TimeInterval = 2
    /// Active-screen contents are cached for 500 ms. Starting another
    /// renderer-backed refresh sooner cannot produce a newer snapshot.
    static let minimumRendererReadInterval: TimeInterval = 0.5

    static func decision(
        now: TimeInterval,
        lastScrollInput: TimeInterval?,
        lastRefresh: TimeInterval?,
        allowsSnapshotReuse: Bool,
        defersSnapshotRefresh: Bool = false
    ) -> SessionContentsRefreshDecision {
        if defersSnapshotRefresh {
            return .deferUntilScrollingStops
        }

        if let lastScrollInput,
           now - lastScrollInput < scrollCooldown {
            return .deferUntilScrollingStops
        }

        if allowsSnapshotReuse,
           let lastRefresh,
           now - lastRefresh < refreshInterval {
            return .reuseSnapshot
        }

        return .refreshSnapshot
    }

    static func requiresSnapshot(
        forStatusFallback: Bool,
        contentIndependentStatus: TerminalSessionActivityStatus?
    ) -> Bool {
        return forStatusFallback && contentIndependentStatus != .active
    }
}

struct DeferredInstructionCaptureState {
    private(set) var isPending = false
    private var generation: UInt = 0

    var pendingID: UInt? {
        isPending ? generation : nil
    }

    @discardableResult
    mutating func markDeferred() -> UInt {
        if !isPending {
            generation &+= 1
        }
        isPending = true
        return generation
    }

    mutating func reset() {
        isPending = false
    }

    mutating func consume(id: UInt) -> Bool {
        guard isPending, generation == id else { return false }
        isPending = false
        return true
    }
}

enum InstructionCaptureRetryPolicy {
    static func shouldRetry(
        hasPendingCapture: Bool,
        defersVisibleContentsRefresh: Bool
    ) -> Bool {
        hasPendingCapture && !defersVisibleContentsRefresh
    }
}

/// Coalesces renderer-backed active-screen requests for one provider. At most
/// one read is active and one replaceable trailing refresh is scheduled. Status
/// polls can share an in-flight read, while a newer instruction capture replaces
/// the less-specific trailing purpose.
struct SessionContentsRequestState {
    enum Purpose: Equatable, Sendable {
        case status
        case instructionCapture(UInt)

        var captureID: UInt? {
            guard case .instructionCapture(let id) = self else { return nil }
            return id
        }
    }

    struct Request: Equatable, Sendable {
        let id: UInt
        let purpose: Purpose
    }

    struct TrailingRefresh: Equatable, Sendable {
        let id: UInt
        let delay: TimeInterval
    }

    enum RequestAction: Equatable, Sendable {
        case start(Request)
        case scheduleTrailing(TrailingRefresh)
        case coalesced
    }

    struct Completion: Equatable, Sendable {
        let acceptsResult: Bool
        let fulfilledCaptureID: UInt?
        let followUpPurpose: Purpose?

        var requiresFollowUp: Bool { followUpPurpose != nil }
    }

    private var nextRequestID: UInt = 0
    private var activeRequest: Request?
    private var pendingFollowUpPurpose: Purpose?
    private var nextTrailingRefreshID: UInt = 0
    private var trailingRefresh: (
        id: UInt,
        purpose: Purpose,
        deadline: TimeInterval
    )?
    private var lastCompletionUptime: TimeInterval?
    private let minimumInterval: TimeInterval

    var isInFlight: Bool { activeRequest != nil }
    var hasScheduledTrailingRefresh: Bool { trailingRefresh != nil }

    init(
        minimumInterval: TimeInterval =
            SessionContentsRefreshPolicy.minimumRendererReadInterval
    ) {
        self.minimumInterval = max(0, minimumInterval)
    }

    mutating func request(
        _ purpose: Purpose,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        requiresFreshResultIfBusy: Bool = false
    ) -> RequestAction {
        if let activeRequest {
            recordFollowUp(
                purpose,
                activeRequest: activeRequest,
                requiresFreshResultIfBusy: requiresFreshResultIfBusy
            )
            return .coalesced
        }

        if let trailingRefresh {
            return replaceTrailingRefresh(
                trailingRefresh,
                with: purpose,
                now: now
            )
        }

        if let lastCompletionUptime {
            let deadline = lastCompletionUptime + minimumInterval
            if now < deadline {
                return makeTrailingRefresh(
                    purpose: purpose,
                    deadline: deadline,
                    now: now
                )
            }
        }

        return start(purpose)
    }

    mutating func complete(
        requestID: UInt,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Completion {
        guard let activeRequest, activeRequest.id == requestID else {
            return Completion(
                acceptsResult: false,
                fulfilledCaptureID: nil,
                followUpPurpose: nil
            )
        }

        self.activeRequest = nil
        lastCompletionUptime = now
        let followUpPurpose = pendingFollowUpPurpose
        pendingFollowUpPurpose = nil
        return Completion(
            acceptsResult: true,
            fulfilledCaptureID: followUpPurpose == nil ?
                activeRequest.purpose.captureID : nil,
            followUpPurpose: followUpPurpose
        )
    }

    /// Consumes only the newest scheduled token. Replaced or lifecycle-cancelled
    /// work items cannot become renderer reads even if their dispatch block runs.
    mutating func beginTrailingRefresh(
        id: UInt,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Request? {
        guard let trailingRefresh,
              trailingRefresh.id == id,
              now >= trailingRefresh.deadline else { return nil }
        self.trailingRefresh = nil
        guard activeRequest == nil else { return nil }
        guard case .start(let request) = start(trailingRefresh.purpose) else {
            return nil
        }
        return request
    }

    mutating func reset() {
        activeRequest = nil
        pendingFollowUpPurpose = nil
        trailingRefresh = nil
        lastCompletionUptime = nil
    }

    private mutating func start(_ purpose: Purpose) -> RequestAction {
        trailingRefresh = nil
        nextRequestID &+= 1
        let request = Request(id: nextRequestID, purpose: purpose)
        activeRequest = request
        return .start(request)
    }

    private mutating func recordFollowUp(
        _ purpose: Purpose,
        activeRequest: Request,
        requiresFreshResultIfBusy: Bool
    ) {
        switch purpose {
        case .instructionCapture:
            if activeRequest.purpose != purpose,
               pendingFollowUpPurpose != purpose {
                // Instruction capture is more specific than a pending status
                // refresh and its fresh analysis also satisfies that refresh.
                pendingFollowUpPurpose = purpose
            }
        case .status:
            if requiresFreshResultIfBusy, pendingFollowUpPurpose == nil {
                pendingFollowUpPurpose = .status
            }
        }
    }

    private mutating func replaceTrailingRefresh(
        _ existing: (id: UInt, purpose: Purpose, deadline: TimeInterval),
        with incomingPurpose: Purpose,
        now: TimeInterval
    ) -> RequestAction {
        let purpose: Purpose
        switch (existing.purpose, incomingPurpose) {
        case (.instructionCapture, .status):
            purpose = existing.purpose
        default:
            purpose = incomingPurpose
        }
        return makeTrailingRefresh(
            purpose: purpose,
            deadline: existing.deadline,
            now: now
        )
    }

    private mutating func makeTrailingRefresh(
        purpose: Purpose,
        deadline: TimeInterval,
        now: TimeInterval
    ) -> RequestAction {
        nextTrailingRefreshID &+= 1
        let id = nextTrailingRefreshID
        trailingRefresh = (id, purpose, deadline)
        return .scheduleTrailing(
            TrailingRefresh(
                id: id,
                delay: max(0, deadline - now)
            )
        )
    }
}
