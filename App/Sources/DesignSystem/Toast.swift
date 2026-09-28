import SwiftUI
import TeamTasksCore

/// A confirmation of a few seconds (« Relance envoyée à Inès », docs/CONTRACTS-V3.md §1): a capsule in `textPrimary`
/// (dark in light mode, light in dark mode) with a green check and the message in bold, at least 44 pt tall. VoiceOver
/// reads the message (`AccessibilityID.Social.toast`).
struct ToastView: View {
    let notice: ToastNotice

    init(notice: ToastNotice) {
        self.notice = notice
    }

    /// The check: the bright green of the dark fills on the dark capsule, the green fill on the light one.
    private static var iconColor: Color { Theme.dynamic(light: 0x6EE7A8, dark: 0x15803D) }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: notice.systemImage)
                .font(Font.subheadline.weight(.heavy))
                .foregroundStyle(Self.iconColor)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(Font.subheadline.weight(.bold))
                .foregroundStyle(Theme.background)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .background(Theme.textPrimary, in: Capsule())
        .shadow(color: Theme.shadow.opacity(0.18), radius: 16, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice.message)
        .accessibilityIdentifier(AccessibilityID.Social.toast)
    }
}

/// Shows `notice` over the bottom of the view for a few seconds, then clears it; a tap clears it at once. VoiceOver
/// announces the message.
private struct ToastModifier: ViewModifier {
    @Binding var notice: ToastNotice?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isUITesting) private var isUITesting

    init(notice: Binding<ToastNotice?>) {
        _notice = notice
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let notice {
                    ToastView(notice: notice)
                        .padding(.horizontal, Theme.Spacing.page)
                        .padding(.bottom, 12)
                        .onTapGesture {
                            self.notice = nil
                        }
                        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
                        .id(notice.id)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35), value: notice?.id)
            .task(id: notice?.id) {
                await ToastTiming.expire(notice, isUITesting: isUITesting) { expired in
                    if notice?.id == expired.id {
                        notice = nil
                    }
                }
            }
    }
}

/// The same confirmation in the flow of a list (« Mes tâches »), where it takes its own room while it shows.
struct InlineToast: View {
    @Binding var notice: ToastNotice?

    @Environment(\.isUITesting) private var isUITesting

    init(notice: Binding<ToastNotice?>) {
        _notice = notice
    }

    var body: some View {
        if let notice {
            ToastView(notice: notice)
                .frame(maxWidth: .infinity)
                .onTapGesture {
                    self.notice = nil
                }
                .transition(.opacity)
                .task(id: notice.id) {
                    await ToastTiming.expire(notice, isUITesting: isUITesting) { expired in
                        if self.notice?.id == expired.id {
                            self.notice = nil
                        }
                    }
                }
        }
    }
}

/// How long a confirmation stays, and its VoiceOver announcement.
enum ToastTiming {
    /// On screen; longer in the UI tests, which capture it.
    static func duration(isUITesting: Bool) -> Duration {
        isUITesting ? .seconds(10) : .milliseconds(3500)
    }

    /// Announces `notice`, waits, then hands it to `clear` (unless the view went away meanwhile).
    @MainActor
    static func expire(_ notice: ToastNotice?, isUITesting: Bool, clear: (ToastNotice) -> Void) async {
        guard let notice else { return }
        AccessibilityNotification.Announcement(notice.message).post()
        do {
            try await Task.sleep(for: duration(isUITesting: isUITesting))
        } catch {
            return
        }
        clear(notice)
    }
}

extension View {
    /// Shows the confirmation `notice` over the bottom of the view for a few seconds (`ToastView`), then sets it back
    /// to nil.
    func toast(_ notice: Binding<ToastNotice?>) -> some View {
        modifier(ToastModifier(notice: notice))
    }
}
