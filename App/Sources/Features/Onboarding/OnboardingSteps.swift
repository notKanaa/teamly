import SwiftUI
import TeamTasksCore

// The four steps of the onboarding (docs/DESIGN-V2.md §7.1). Each one shows its own fixed texts (not
// `OnboardingViewModel.title`, which already names the next step while the previous one slides away).

/// 1. « Bienvenue, Camille ! »: stacked task cards, the message and the three highlights.
struct OnboardingWelcomeStep: View {
    /// `OnboardingViewModel.welcomeTitle`.
    let title: String

    var body: some View {
        OnboardingStepContainer(step: .welcome, spacing: 26) {
            OnboardingTaskCardsIllustration()
                .padding(.top, 4)
            OnboardingStepHeader(title: title, message: OnboardingViewModel.welcomeMessage, isLarge: true)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(OnboardingViewModel.highlights) { highlight in
                    OnboardingHighlightRow(highlight: highlight)
                }
            }
        }
    }
}

/// A highlight of the welcome step: a 48 pt icon tile, its title and its message. One VoiceOver element.
struct OnboardingHighlightRow: View {
    let highlight: OnboardingViewModel.Highlight

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(systemImage: highlight.systemImage, tone: tone, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.title)
                    .font(Font.callout.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(highlight.message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// Coral for the rotation, teal for the checklists, amber for the recap (the mockup).
    private var tone: SoftTone {
        switch highlight.systemImage {
        case "arrow.triangle.2.circlepath": ColorKey.coral.tone
        case "checklist": ColorKey.teal.tone
        case "trophy", "trophy.fill": ColorKey.amber.tone
        default: SoftTone.accent
        }
    }
}

/// 2. « Choisis ton avatar »: the preview, the color and the initials or an emoji. « Continuer » saves a change.
struct OnboardingAvatarStep: View {
    let avatar: AvatarEditorViewModel

    var body: some View {
        OnboardingStepContainer(step: .avatar) {
            OnboardingStepHeader(title: OnboardingViewModel.avatarTitle, message: OnboardingViewModel.avatarMessage)
            AvatarEditorContent(model: avatar)
        }
    }
}

/// 3. « Ton premier groupe »: « Créer » (the tile preview, the name, the emoji and the color) or « Rejoindre » (the
/// invite code). Once the group is created or joined, coming back to the step shows it done.
struct OnboardingFirstGroupStep: View {
    @Bindable var model: OnboardingViewModel
    let focus: FocusState<OnboardingField?>.Binding

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingStepContainer(step: .firstGroup, spacing: 22) {
            OnboardingStepHeader(title: OnboardingViewModel.firstGroupTitle, message: OnboardingViewModel.firstGroupMessage)
            if let done = model.firstGroupDoneMessage {
                Card(radius: 24) {
                    HStack(spacing: 14) {
                        IconTile(systemImage: "checkmark", tone: SoftTone.done, size: 44)
                        Text(done)
                            .font(Font.body.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.Onboarding.firstGroupDone)
            } else {
                SegmentedPill(
                    OnboardingViewModel.FirstGroupMode.allCases,
                    selection: $model.firstGroupMode,
                    identifier: { AccessibilityID.Onboarding.mode($0.rawValue) }
                ) { mode in
                    mode.label
                }
                .disabled(model.isBusy)

                switch model.firstGroupMode {
                case .create:
                    OnboardingCreateGroupCard(model: model.createGroup, focus: focus)
                        .transition(.opacity)
                case .join:
                    OnboardingJoinGroupCard(model: model.joinGroup, focus: focus)
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: model.firstGroupMode)
    }
}

/// « Créer » of the first group step: the live tile, « Nom du groupe », « Emoji » (tap the chosen one again for none:
/// the initials) and « Couleur ».
struct OnboardingCreateGroupCard: View {
    @Bindable var model: CreateGroupViewModel
    let focus: FocusState<OnboardingField?>.Binding

    var body: some View {
        Card(padding: 18, spacing: 16, radius: 24) {
            HStack(alignment: .center, spacing: 14) {
                GroupTile(model.preview, size: 60)
                    .animation(.snappy, value: model.preview)
                VStack(alignment: .leading, spacing: 4) {
                    Text(OnboardingViewModel.groupNameLabel)
                        .font(Font.footnote.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                    TextField(CreateGroupViewModel.namePlaceholder, text: $model.name)
                        .font(.rounded(.title3, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .textInputAutocapitalization(.sentences)
                        // A name, not a sentence: no corrections (« Coloc » stays « Coloc »).
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused(focus, equals: .groupName)
                        .accessibilityLabel(OnboardingViewModel.groupNameLabel)
                        .accessibilityIdentifier(AccessibilityID.Onboarding.groupNameField)
                    Rectangle()
                        .fill(model.nameError == nil ? Theme.track : Theme.danger)
                        .frame(height: 2)
                        .accessibilityHidden(true)
                }
            }
            if let error = model.nameError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.Onboarding.groupNameError)
            }
            PickerSection(OnboardingViewModel.emojiSectionTitle) {
                EmojiGrid(options: model.emojiOptions, selection: model.emoji) { emoji in
                    model.selectEmoji(emoji)
                }
            }
            PickerSection(OnboardingViewModel.colorSectionTitle) {
                SwatchGrid(
                    options: model.colorOptions,
                    isSelected: { $0 == model.color },
                    onSelect: { model.selectColor($0) }
                )
            }
        }
    }
}

/// « Rejoindre » of the first group step: the big invite code field (formatted live as ABCD-EFGH) and the hint.
struct OnboardingJoinGroupCard: View {
    @Bindable var model: JoinGroupViewModel
    let focus: FocusState<OnboardingField?>.Binding

    var body: some View {
        Card(padding: 18, spacing: 12, radius: 24) {
            Text(OnboardingViewModel.inviteCodeLabel)
                .font(Font.footnote.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            TextField(JoinGroupViewModel.placeholder, text: $model.code)
                .font(.system(.title, design: .monospaced, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
                .focused(focus, equals: .inviteCode)
                .padding(.horizontal, 12)
                .frame(minHeight: 64)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .accessibilityLabel(OnboardingViewModel.inviteCodeLabel)
                .accessibilityIdentifier(AccessibilityID.Onboarding.inviteCodeField)
            Text(OnboardingViewModel.joinHint)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 4. « Ne rate plus ton tour »: three sample notifications, then the message.
struct OnboardingNotificationsStep: View {
    var body: some View {
        OnboardingStepContainer(step: .notifications, spacing: 26) {
            OnboardingNotificationSamples()
                .padding(.top, 4)
            OnboardingStepHeader(
                title: OnboardingViewModel.notificationsTitle,
                message: OnboardingViewModel.notificationsMessage
            )
        }
    }
}
