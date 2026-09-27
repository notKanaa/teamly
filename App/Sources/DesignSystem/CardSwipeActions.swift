import SwiftUI

/// An action revealed by swiping a card (`.cardSwipeActions(leading:trailing:)`): a colored button with a symbol and a
/// short title, white on `tint`. Its identifier goes on the button.
struct CardSwipeAction: Identifiable {
    let title: String
    let systemImage: String
    let tint: Color
    let identifier: String
    let action: () -> Void

    var id: String { identifier }

    init(_ title: String, systemImage: String, tint: Color, identifier: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.identifier = identifier
        self.action = action
    }
}

/// Swipe actions for the cards of a scroll view (a `List` has `.swipeActions`; the lists of the app are lazy stacks of
/// cards). Swiping right reveals the `leading` actions, swiping left the `trailing` ones, as buttons behind the card with
/// its corners; a tap on one runs it and closes the card, a tap on the open card closes it. A vertical drag scrolls as
/// usual. Every action is also a VoiceOver action of the card. With Reduce Motion the card moves without a spring.
struct CardSwipeActionsModifier: ViewModifier {
    let leading: [CardSwipeAction]
    let trailing: [CardSwipeAction]
    let cornerRadius: CGFloat

    /// The settled position: > 0 when the leading actions show, < 0 for the trailing ones.
    @State private var offset: CGFloat = 0
    /// The horizontal part of the drag in progress.
    @State private var translation: CGFloat = 0
    /// The direction of the drag in progress, known after its first points.
    @State private var direction = DragDirection.undecided
    /// True while a finger drags (reset by SwiftUI when the drag ends or is cancelled).
    @GestureState private var isDragging = false
    /// The card's own buttons are disabled from the moment a drag turns out horizontal until a little after it ends: a
    /// `NavigationLink` would otherwise open when the finger is lifted inside it (a scroll view only cancels its
    /// buttons for vertical drags).
    @State private var suppressesTaps = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var buttonWidth: CGFloat = 84

    enum DragDirection {
        case undecided
        case horizontal
        case vertical
    }

    init(leading: [CardSwipeAction], trailing: [CardSwipeAction], cornerRadius: CGFloat) {
        self.leading = leading
        self.trailing = trailing
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        if leading.isEmpty && trailing.isEmpty {
            content
        } else {
            let position = currentPosition
            content
                .disabled(suppressesTaps)
                .overlay {
                    if offset != 0 {
                        // The open card closes on a tap instead of opening.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                close()
                            }
                    }
                }
                .offset(x: position)
                .background {
                    actionButtons(position)
                }
                .simultaneousGesture(dragGesture)
                .onChange(of: isDragging) { _, dragging in
                    // A drag cancelled (the scroll view took it over): the card settles where it was left.
                    guard !dragging, direction != .undecided || translation != 0 else { return }
                    direction = .undecided
                    settle(from: offset + translation)
                    releaseTaps()
                }
                .accessibilityActions {
                    ForEach(leading + trailing) { action in
                        Button(action.title) {
                            action.action()
                        }
                    }
                }
        }
    }

    // MARK: - Position

    private var leadingWidth: CGFloat { CGFloat(leading.count) * buttonWidth }
    private var trailingWidth: CGFloat { CGFloat(trailing.count) * buttonWidth }

    /// The settled position plus the drag in progress, a little beyond the buttons at most.
    private var currentPosition: CGFloat {
        let dragged = offset + translation
        let upper = leading.isEmpty ? 0 : leadingWidth + 24
        let lower = trailing.isEmpty ? 0 : -(trailingWidth + 24)
        return min(max(dragged, lower), upper)
    }

    private var dragGesture: some Gesture {
        // Global coordinates: the card moves with the finger, its own space would move too.
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .updating($isDragging) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if direction == .undecided {
                    direction = Self.isHorizontal(value.translation) ? .horizontal : .vertical
                    if direction == .horizontal {
                        suppressesTaps = true
                    }
                }
                if direction == .horizontal {
                    translation = value.translation.width
                }
            }
            .onEnded { value in
                let wasHorizontal = direction == .horizontal
                direction = .undecided
                if wasHorizontal {
                    settle(from: offset + value.predictedEndTranslation.width)
                    releaseTaps()
                } else {
                    translation = 0
                }
            }
    }

    /// The card's buttons work again once the lifted finger's tap has been dropped.
    private func releaseTaps() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            if direction == .undecided {
                suppressesTaps = false
            }
        }
    }

    private static func isHorizontal(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * 1.2
    }

    /// Opens the side the card was thrown far enough towards, or closes it, moving on from where the finger left it.
    private func settle(from target: CGFloat) {
        let position: CGFloat
        if target > leadingWidth / 2, !leading.isEmpty {
            position = leadingWidth
        } else if target < -trailingWidth / 2, !trailing.isEmpty {
            position = -trailingWidth
        } else {
            position = 0
        }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            offset = position
            translation = 0
        }
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            offset = 0
        }
    }

    // MARK: - Buttons

    /// The buttons of the side being revealed, behind the card (only while it is moved: hidden ones do not exist).
    @ViewBuilder
    private func actionButtons(_ position: CGFloat) -> some View {
        if position > 0 {
            HStack(spacing: 0) {
                ForEach(leading) { action in
                    actionButton(action)
                }
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else if position < 0 {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach(trailing) { action in
                    actionButton(action)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    private func actionButton(_ action: CardSwipeAction) -> some View {
        Button {
            close()
            action.action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: action.systemImage)
                    .font(Font.body.weight(.bold))
                    .accessibilityHidden(true)
                Text(action.title)
                    .font(Font.caption.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Theme.onFill)
            .padding(.horizontal, 4)
            .frame(width: buttonWidth)
            .frame(maxHeight: .infinity)
            .background(action.tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.identifier)
    }
}

extension View {
    /// Swipe actions on a card of a scroll view (see `CardSwipeActionsModifier`): `leading` revealed by swiping right,
    /// `trailing` by swiping left. No action on either side: the card does not move.
    func cardSwipeActions(
        leading: [CardSwipeAction] = [],
        trailing: [CardSwipeAction] = [],
        cornerRadius: CGFloat = Theme.Radius.row
    ) -> some View {
        modifier(CardSwipeActionsModifier(leading: leading, trailing: trailing, cornerRadius: cornerRadius))
    }
}
