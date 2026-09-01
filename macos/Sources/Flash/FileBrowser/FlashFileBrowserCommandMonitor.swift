import AppKit
import SwiftUI

/// Keeps a SwiftUI file table focused after a row click and routes its
/// Finder-style shortcuts before Ghostty's terminal key equivalents. The
/// explicit focus boundary prevents Command-C/V/Delete from being intercepted
/// while the terminal or either search field is active.
struct FlashFileBrowserCommandMonitor: NSViewRepresentable {
    let sessionIsSelected: Bool
    let listHasFocus: Bool
    let canCopy: Bool
    let canPaste: Bool
    let canMoveToTrash: Bool
    let copy: () -> Void
    let paste: () -> Void
    let moveToTrash: () -> Void
    let requestListFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = MarkerView(frame: .zero)
        view.coordinator = context.coordinator
        context.coordinator.install(markerView: view)
        updateCoordinator(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateCoordinator(context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    private func updateCoordinator(_ coordinator: Coordinator) {
        coordinator.listHasFocus = listHasFocus
        coordinator.canCopy = canCopy
        coordinator.canPaste = canPaste
        coordinator.canMoveToTrash = canMoveToTrash
        coordinator.copy = copy
        coordinator.paste = paste
        coordinator.moveToTrash = moveToTrash
        coordinator.requestListFocus = requestListFocus
        coordinator.setSessionIsSelected(sessionIsSelected)
    }

    final class MarkerView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.markerViewDidMoveToWindow()
        }
    }

    final class Coordinator {
        private final class WindowKeyObservation {
            private let center = NotificationCenter.default
            private var observers: [NSObjectProtocol] = []

            init(window: NSWindow, onChange: @escaping @Sendable () -> Void) {
                observers = [
                    center.addObserver(
                        forName: NSWindow.didBecomeKeyNotification,
                        object: window,
                        queue: .main
                    ) { _ in onChange() },
                    center.addObserver(
                        forName: NSWindow.didResignKeyNotification,
                        object: window,
                        queue: .main
                    ) { _ in onChange() },
                ]
            }

            deinit {
                for observer in observers {
                    center.removeObserver(observer)
                }
            }
        }

        fileprivate var listHasFocus = false
        fileprivate var canCopy = false
        fileprivate var canPaste = false
        fileprivate var canMoveToTrash = false
        fileprivate var copy: () -> Void = {}
        fileprivate var paste: () -> Void = {}
        fileprivate var moveToTrash: () -> Void = {}
        fileprivate var requestListFocus: () -> Void = {}

        private weak var markerView: MarkerView?
        private var windowKeyObservation: WindowKeyObservation?
        private var sessionIsSelected = false
        private var eventMonitor: Any?

        func install(markerView: MarkerView) {
            self.markerView = markerView
            rebindWindowObservation()
        }

        func setSessionIsSelected(_ isSelected: Bool) {
            guard sessionIsSelected != isSelected else { return }
            sessionIsSelected = isSelected
            rebindWindowObservation()
        }

        func markerViewDidMoveToWindow() {
            rebindWindowObservation()
        }

        func uninstall() {
            removeEventMonitor()
            windowKeyObservation = nil
            markerView = nil
        }

        deinit {
            uninstall()
        }

        private func rebindWindowObservation() {
            windowKeyObservation = if sessionIsSelected,
                                      let window = markerView?.window {
                WindowKeyObservation(window: window) { [weak self] in
                    self?.updateEventMonitor()
                }
            } else {
                nil
            }
            updateEventMonitor()
        }

        private func updateEventMonitor() {
            let shouldMonitor = FlashFileBrowserCommandRouting.shouldMonitorEvents(
                sessionIsSelected: sessionIsSelected,
                windowIsKey: markerView?.window?.isKeyWindow == true
            )
            if shouldMonitor, eventMonitor == nil {
                eventMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.keyDown, .leftMouseDown]
                ) { [weak self] event in
                    self?.handle(event) ?? event
                }
            } else if !shouldMonitor {
                removeEventMonitor()
            }
        }

        private func removeEventMonitor() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window = markerView?.window,
                  event.window === window,
                  FlashFileBrowserCommandRouting.shouldMonitorEvents(
                    sessionIsSelected: sessionIsSelected,
                    windowIsKey: window.isKeyWindow
                  ) else { return event }

            if event.type == .leftMouseDown {
                requestFocusIfClickIsInsideList(event)
                return event
            }

            guard let command = FlashFileBrowserCommandRouting.command(
                    for: event,
                    sessionIsSelected: sessionIsSelected,
                    windowIsKey: window.isKeyWindow,
                    listHasFocus: listHasFocus,
                    canCopy: canCopy,
                    canPaste: canPaste,
                    canMoveToTrash: canMoveToTrash
                  ) else {
                return event
            }

            switch command {
            case .copy:
                copy()
            case .paste:
                paste()
            case .moveToTrash:
                moveToTrash()
            }
            return nil
        }

        private func requestFocusIfClickIsInsideList(_ event: NSEvent) {
            guard let markerView,
                  let window = markerView.window,
                  event.window === window else { return }

            let location = markerView.convert(event.locationInWindow, from: nil)
            guard markerView.bounds.contains(location) else { return }

            // Let the Table finish its own selection handling first, then move
            // focus away from a previously active search field.
            DispatchQueue.main.async { [weak self] in
                self?.requestListFocus()
            }
        }
    }
}

enum FlashFileBrowserCommand: Equatable {
    case copy
    case paste
    case moveToTrash
}

/// Pure shortcut classification kept separate from the event monitor so the
/// focus boundary and Finder-style key equivalents can be regression tested.
enum FlashFileBrowserCommandRouting {
    static func shouldMonitorEvents(
        sessionIsSelected: Bool,
        windowIsKey: Bool
    ) -> Bool {
        sessionIsSelected && windowIsKey
    }

    static func command(
        for event: NSEvent,
        sessionIsSelected: Bool = true,
        windowIsKey: Bool = true,
        listHasFocus: Bool,
        canCopy: Bool,
        canPaste: Bool,
        canMoveToTrash: Bool
    ) -> FlashFileBrowserCommand? {
        guard shouldMonitorEvents(
            sessionIsSelected: sessionIsSelected,
            windowIsKey: windowIsKey
        ), listHasFocus else { return nil }

        let relevantModifiers = event.modifierFlags.intersection([
            .command,
            .control,
            .option,
            .shift,
        ])
        guard relevantModifiers == .command else { return nil }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c" where canCopy:
            return .copy
        case "v" where canPaste:
            return .paste
        default:
            break
        }

        // Finder moves selected items to Trash with Command-Delete.
        return event.keyCode == 51 && canMoveToTrash ? .moveToTrash : nil
    }
}
