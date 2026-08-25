import Foundation
import OSLog

/// The persistent handoff between AppKit's saved-state archive and the next
/// launch. A stored `false` is meaningful: it is a tombstone that prevents an
/// archive rejected with Start Fresh from returning after an early crash.
enum SessionRestorationArchiveMarker: Equatable {
    case legacy
    case available
    case discarded

    init(storedValue: Any?) {
        guard let storedValue else {
            self = .legacy
            return
        }

        guard let value = storedValue as? NSNumber else {
            self = .discarded
            return
        }

        self = value.boolValue ? .available : .discarded
    }
}

/// Storage boundary for the small marker that accompanies AppKit's archive.
/// Keeping this separate makes launch policy testable without UserDefaults.
protocol SessionRestorationArchiveStoring: AnyObject {
    var marker: SessionRestorationArchiveMarker { get }
    func store(_ marker: SessionRestorationArchiveMarker)
}

final class UserDefaultsSessionRestorationArchiveStore:
    SessionRestorationArchiveStoring {
    static let markerKey = "FLASHGhosttyRestorableSessionsAvailable"

    private let defaults: UserDefaults
    private let markerKey: String

    init(
        defaults: UserDefaults = .ghostty,
        markerKey: String = UserDefaultsSessionRestorationArchiveStore.markerKey
    ) {
        self.defaults = defaults
        self.markerKey = markerKey
    }

    var marker: SessionRestorationArchiveMarker {
        .init(storedValue: defaults.object(forKey: markerKey))
    }

    func store(_ marker: SessionRestorationArchiveMarker) {
        switch marker {
        case .legacy:
            defaults.removeObject(forKey: markerKey)
        case .available:
            defaults.set(true, forKey: markerKey)
        case .discarded:
            defaults.set(false, forKey: markerKey)
        }
    }
}

/// An independently-owned restoration payload. Creating a snapshot only
/// copies archived bytes; decoding it may create terminal surfaces and must
/// happen only after the user chooses to restore.
struct TerminalRestorableSnapshot<State: TerminalRestorable> {
    private let bridge: CodableBridge<State>

    init?(coder: NSCoder) {
        let current = coder.decodeInteger(forKey: State.versionKey)
        guard current >= State.minimumVersion else {
            AppDelegate.logger.error(
                "error restoring terminal: version not supported: expected=\(State.minimumVersion, privacy: .public), got=\(current, privacy: .public)"
            )
            return nil
        }

        guard let bridge = coder.decodeObject(
            of: CodableBridge<State>.self,
            forKey: State.selfKey
        ) else {
            AppDelegate.logger.error("error restoring terminal: snapshot failed")
            return nil
        }

        self.bridge = bridge
    }

    func decodedValue() -> State? {
        guard let value = bridge.decodedValue() else {
            AppDelegate.logger.error("error restoring terminal: decode failed")
            return nil
        }

        return State(copy: value)
    }
}
