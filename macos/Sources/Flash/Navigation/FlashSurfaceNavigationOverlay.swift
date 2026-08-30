import Combine
import Foundation
import GhosttyKit
import SwiftUI

/// FLASH-owned controls layered over a terminal surface.
///
/// Scrollbar notifications are observed here instead of publishing scrollbar
/// state from `SurfaceView`. This keeps frequent scroll updates from invalidating
/// the entire terminal SwiftUI hierarchy.
struct FlashSurfaceNavigationOverlay: View {
    let surfaceView: Ghostty.SurfaceView

    @ObservedObject private var navigationModel: FlashSurfaceNavigationModel
    @State private var isScrollToBottomHovered = false
    @State private var isAddPinHovered = false
    @State private var hoveredPinNumber: Int?

    init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        _navigationModel = ObservedObject(
            wrappedValue: FlashSurfaceNavigationRegistry.shared.model(
                for: surfaceView
            )
        )
    }

    var body: some View {
        ZStack {
            scrollToBottomControl
            pinRail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            updatePresentation(from: surfaceView.scrollbar)
            updateGridSize(from: surfaceView.surfaceSize)
        }
        .onReceive(scrollbarPublisher) { scrollbar in
            handleScrollbarUpdate(scrollbar)
        }
        .onReceive(gridSizePublisher) { gridSize in
            navigationModel.updateGridSize(gridSize)
        }
    }

    /// The model coalesces scrollbar samples into a one-shot display-frame
    /// drain. Keeping this publisher event-only avoids installing a periodic
    /// timer while the surface is idle.
    private var scrollbarPublisher:
        AnyPublisher<Ghostty.Action.Scrollbar, Never> {
        return NotificationCenter.default
            .publisher(for: .ghosttyDidUpdateScrollbar, object: surfaceView)
            .compactMap { notification in
                notification.userInfo?[
                    SwiftUI.Notification.Name.ScrollbarKey
                ] as? Ghostty.Action.Scrollbar
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    private var gridSizePublisher: AnyPublisher<FlashSurfaceGridSize, Never> {
        surfaceView.$surfaceSize
            .compactMap { $0 }
            .map { size in
                FlashSurfaceGridSize(columns: size.columns, rows: size.rows)
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    private var scrollToBottomControl: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                if isScrollToBottomVisible {
                    scrollToBottomButton
                }
            }
        }
        .padding(.trailing, 18)
        .padding(.bottom, 18)
    }

    private var pinRail: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 0)

            ViewThatFits(in: .vertical) {
                pinControls

                ScrollView(.vertical, showsIndicators: false) {
                    pinControls
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, 18)
        .padding(.top, 18)
        .padding(.bottom, 72)
    }

    private var pinControls: some View {
        VStack(spacing: 7) {
            addPinButton

            ForEach(navigationModel.pins) { pin in
                pinButton(pin)
            }
        }
    }

    private var scrollToBottomButton: some View {
        Button(action: scrollToBottom) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 14, weight: .regular))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isScrollToBottomHovered ? Color.primary : Color.secondary)
        .background(controlBackground(isHovered: isScrollToBottomHovered))
        .onHover { isScrollToBottomHovered = $0 }
        .backport.pointerStyle(.link)
        .help("Scroll to Bottom")
        .accessibilityIdentifier(
            "terminal-surface.scroll-to-bottom.\(surfaceView.id.uuidString)"
        )
        .accessibilityLabel("Scroll to Bottom")
        .accessibilityHint("Moves to the newest terminal output.")
    }

    private var addPinButton: some View {
        Button(action: addPin) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 13, weight: .regular))

                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 9, weight: .regular))
                    .offset(x: 2, y: 2)
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isAddPinHovered ? Color.primary : Color.secondary)
        .background(controlBackground(isHovered: isAddPinHovered))
        .disabled(!isPinningAvailable || !navigationModel.canAddPin)
        .opacity(isPinningAvailable && navigationModel.canAddPin ? 1 : 0.48)
        .onHover { isAddPinHovered = $0 }
        .backport.pointerStyle(.link)
        .help(addPinHelp)
        .accessibilityIdentifier(
            "terminal-surface.add-pin.\(surfaceView.id.uuidString)"
        )
        .accessibilityLabel("Add Pin")
        .accessibilityHint(addPinHelp)
    }

    private func pinButton(_ pin: FlashSurfacePin) -> some View {
        let isHovered = hoveredPinNumber == pin.number

        return Button {
            scroll(to: pin)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .regular))

                Text(verbatim: "\(pin.number)")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
            }
            .frame(width: 34, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovered ? Color.primary : Color.secondary)
        .background(controlBackground(isHovered: isHovered))
        .onHover { hovering in
            hoveredPinNumber = hovering ? pin.number : nil
        }
        .backport.pointerStyle(.link)
        .help("Go to Pin \(pin.number) · Right-click to remove")
        .contextMenu {
            Button("Remove Pin \(pin.number)", role: .destructive) {
                navigationModel.removePin(number: pin.number)
            }
        }
        .accessibilityIdentifier(
            "terminal-surface.pin.\(surfaceView.id.uuidString).\(pin.number)"
        )
        .accessibilityLabel("Pin \(pin.number)")
        .accessibilityHint("Moves to this saved terminal position.")
        .accessibilityAction(named: Text("Remove Pin")) {
            navigationModel.removePin(number: pin.number)
        }
    }

    private func controlBackground(isHovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
                Color(nsColor: .windowBackgroundColor)
                    .opacity(isHovered ? 0.90 : 0.78)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(isHovered ? 0.24 : 0.15),
                        lineWidth: 1
                    )
            }
    }

    private func scrollToBottom() {
        if surfaceView.surfaceModel?.perform(
            action: FlashSurfaceNavigationAction.scrollToBottom.bindingAction
        ) == true {
            if let bottomOffset = navigationModel.latestSnapshot.history.bottomOffset {
                navigationModel.updateCurrentOffset(bottomOffset)
            }
        }
        Ghostty.moveFocus(to: surfaceView)
    }

    private func addPin() {
        defer { Ghostty.moveFocus(to: surfaceView) }
        guard let snapshot = currentCoreNavigationSnapshot() else {
            navigationModel.removeAllPins()
            return
        }
        _ = navigationModel.addPin(at: snapshot)
    }

    private func scroll(to pin: FlashSurfacePin) {
        defer { Ghostty.moveFocus(to: surfaceView) }
        guard let row = navigationModel.targetRow(
            for: pin.number
        ) else {
            navigationModel.removePin(number: pin.number)
            return
        }

        if surfaceView.surfaceModel?.scrollToHistoryRow(
            row,
            contentGeneration: pin.contentGeneration,
            screenIdentity: pin.screenIdentity
        ) == true {
            navigationModel.updateCurrentOffset(row)
        } else {
            // The core revalidates under the renderer mutex. A rejection means
            // this cached pin lost its content identity between notification
            // delivery and the click, so it must not remain actionable.
            navigationModel.removePin(number: pin.number)
        }
    }

    private var addPinHelp: String {
        if !navigationModel.latestSnapshot.history.hasScrollableHistory {
            return "No Scrollback to Pin Yet"
        }
        if !isPinningAvailable {
            return "Scroll Up to Pin"
        }
        if !navigationModel.canAddPin {
            return "Maximum of 5 Pins Reached"
        }
        return "Pin Current Position"
    }

    private func updatePresentation(from scrollbar: Ghostty.Action.Scrollbar?) {
        guard let scrollbar else {
            navigationModel.setSnapshot(.empty)
            return
        }

        let resolvedSample = resolveSample(from: scrollbar)
        if resolvedSample.identitySource == .unavailable {
            navigationModel.removeAllPins()
        }
        navigationModel.setSnapshot(resolvedSample.sample.snapshot)
    }

    private var isScrollToBottomVisible: Bool {
        navigationModel.presentation.isScrollToBottomVisible
    }

    private var isPinningAvailable: Bool {
        navigationModel.presentation.isPinningAvailable
    }

    private func updateGridSize(from size: ghostty_surface_size_s?) {
        guard let size else { return }
        navigationModel.updateGridSize(
            FlashSurfaceGridSize(columns: size.columns, rows: size.rows)
        )
    }

    private func handleScrollbarUpdate(_ scrollbar: Ghostty.Action.Scrollbar) {
        navigationModel.enqueue(resolveSample(from: scrollbar))
    }

    private func resolveSample(
        from scrollbar: Ghostty.Action.Scrollbar
    ) -> FlashSurfaceNavigationResolvedSample {
        FlashSurfaceNavigationSampleResolver.resolve(
            geometry: FlashSurfaceScrollbarGeometry(
                total: scrollbar.total,
                offset: scrollbar.offset,
                length: scrollbar.len
            ),
            cachedHistory: navigationModel.latestSnapshot.history,
            requiresHistoryIdentity: !navigationModel.pins.isEmpty,
            fetchSnapshot: currentCoreNavigationSnapshot
        )
    }

    private func currentCoreNavigationSnapshot()
        -> FlashSurfaceNavigationSnapshot? {
        guard let scrollbar = surfaceView.surfaceModel?.scrollbarSnapshot() else {
            return nil
        }
        return FlashSurfaceNavigationSnapshot(
            history: historyShape(from: scrollbar),
            offset: scrollbar.offset
        )
    }

    private func historyShape(
        from scrollbar: Ghostty.Surface.ScrollbarSnapshot
    ) -> FlashSurfaceHistoryShape {
        FlashSurfaceHistoryShape(
            total: scrollbar.total,
            length: scrollbar.len,
            contentGeneration: scrollbar.contentGeneration,
            screenIdentity: scrollbar.screenIdentity
        )
    }
}
