import SwiftUI
import TeamTasksCore

/// Focusable fields of the onboarding.
enum OnboardingField: Hashable {
    case groupName
    case inviteCode
}

/// The onboarding of a new account (docs/DESIGN-V2.md §7.1, `AppPhase.onboarding`), full screen:
/// - a header: the round back button (from the second step), the step progress « 2 sur 4 », « Passer »;
/// - the step, which scrolls (slides in from the side it comes from; a crossfade with Reduce Motion);
/// - its buttons, pinned at the bottom: the primary one (`advance()`, a spinner while a request runs) and « Plus tard »
///   (`skipStep()`) on the steps that have it.
///
/// A failed step shows its error in an alert (the group name's own message under its field) and stays; « Passer » and
/// « Plus tard » remain available. When the onboarding ends (last step, or « Passer »), `AppModel` opens the tabs.
struct OnboardingView: View {
    @Bindable var model: OnboardingViewModel

    /// The direction of the last move, for the slide of the steps.
    @State private var isMovingForward = true
    @FocusState private var focusedField: OnboardingField?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: OnboardingViewModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                stepView(model.step)
                    .id(model.stepIndex)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
        }
        .background(Theme.background)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.35), value: model.stepIndex)
        .shellErrorAlert(model)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Onboarding.screen)
    }

    // MARK: - Header

    private var header: some View {
        // On one line while it fits; at large text sizes, the progress goes under the buttons.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                backButton
                progress
                skipButton
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    backButton
                    Spacer(minLength: 0)
                    skipButton
                }
                progress
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var backButton: some View {
        if model.stepIndex > 0 {
            CircleIconButton(systemImage: "chevron.left", accessibilityLabel: "Retour") {
                goBack()
            }
            .disabled(!model.canGoBack)
            .accessibilityIdentifier(AccessibilityID.Onboarding.backButton)
        }
    }

    private var progress: some View {
        StepProgress(current: model.stepNumber, total: model.stepCount, text: model.progressText)
            .frame(minHeight: 44)
            .accessibilityIdentifier(AccessibilityID.Onboarding.progress)
    }

    private var skipButton: some View {
        Button(OnboardingViewModel.skipButtonTitle) {
            skip()
        }
        .buttonStyle(SecondaryButtonStyle(isFullWidth: false))
        .fixedSize()
        .accessibilityHint("Termine l’accueil et ouvre l’app")
        .accessibilityIdentifier(AccessibilityID.Onboarding.skipButton)
    }

    // MARK: - Steps

    @ViewBuilder
    private func stepView(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            OnboardingWelcomeStep(title: model.welcomeTitle)
        case .avatar:
            OnboardingAvatarStep(avatar: model.avatar)
        case .firstGroup:
            OnboardingFirstGroupStep(model: model, focus: $focusedField)
        case .notifications:
            OnboardingNotificationsStep()
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: isMovingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isMovingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    // MARK: - Buttons

    private var actions: some View {
        VStack(spacing: 4) {
            PrimaryButton(
                model.primaryButtonTitle,
                systemImage: primarySymbol,
                iconPlacement: model.step == .welcome ? .trailing : .leading,
                isLoading: model.isBusy
            ) {
                advance()
            }
            .disabled(!model.canAdvance)
            .accessibilityIdentifier(AccessibilityID.Onboarding.primaryButton)

            if let later = model.secondaryButtonTitle {
                Button(later) {
                    skipStep()
                }
                .buttonStyle(.secondary)
                .disabled(model.isBusy)
                .accessibilityIdentifier(AccessibilityID.Onboarding.laterButton)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Shell.pinnedBottomBar)
    }

    /// « C’est parti → », « 🔔 Activer les notifications ».
    private var primarySymbol: String? {
        switch model.step {
        case .welcome: "arrow.right"
        case .notifications: "bell.fill"
        case .avatar, .firstGroup: nil
        }
    }

    // MARK: - Actions

    private func advance() {
        focusedField = nil
        isMovingForward = true
        Task {
            await model.advance()
        }
    }

    private func skipStep() {
        focusedField = nil
        isMovingForward = true
        Task {
            await model.skipStep()
        }
    }

    private func skip() {
        focusedField = nil
        Task {
            await model.skip()
        }
    }

    private func goBack() {
        focusedField = nil
        isMovingForward = false
        model.goBack()
    }
}

/// The scrolling column of a step: 24 pt margins, the keyboard dismissed by a drag, identified by its step for the UI
/// tests (`AccessibilityID.Onboarding.step(_:)`).
struct OnboardingStepContainer<Content: View>: View {
    let step: OnboardingStep
    var spacing: CGFloat
    let content: Content

    init(step: OnboardingStep, spacing: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.step = step
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Onboarding.step(step.rawValue))
    }
}

/// The title (rounded heavy, a header for VoiceOver) and the message of a step.
struct OnboardingStepHeader: View {
    let title: String
    let message: String
    var isLarge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.rounded(isLarge ? .largeTitle : .title))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
