import SwiftUI
import TeamTasksCore

/// « Mode absent » (docs/CONTRACTS-V3.md §2, the v3 mockup), a standalone sheet: a blue plane, the title and what it
/// does; the card of the dates (« Du », « Au ») and « Prévenir mes groupes »; « Tes tours pendant ce temps », the turns
/// the absence hands over and who takes each; then « Activer le mode absent » pinned at the bottom (« Modifier mon
/// absence » and « Terminer mon absence » while an absence is set). It closes once saved and hands the confirmation to
/// `onFinish` (« Mode absent activé du 12 au 19 octobre »).
///
/// The date pickers use the session's calendar and time zone, like the view model's dates.
struct AwayModeSheet: View {
    @State private var model: AwayModeViewModel
    let onFinish: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    init(model: AwayModeViewModel, onFinish: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.onFinish = onFinish
    }

    private var calendar: Calendar { model.session.platform.calendar }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    content
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
            .accessibilityIdentifier(AccessibilityID.Social.awaySheet)
            .screenBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.loadState.isLoaded {
                    buttons
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier(AccessibilityID.Social.awayCancelButton)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.isSaving)
        .task {
            await model.load()
        }
        .onChange(of: model.resultMessage) { _, message in
            guard let message else { return }
            onFinish(message)
            dismiss()
        }
        .shellErrorAlert(model)
    }

    // MARK: - Parts

    /// The plane, « Mode absent », what it does, and the current absence.
    private var header: some View {
        VStack(spacing: 10) {
            IconTile(systemImage: "airplane", tone: ColorKey.blue.tone, size: 64)
            Text(AwayModeViewModel.title)
                .font(.rounded(.title))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(AwayModeViewModel.message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let current = model.currentAwayText {
                Chip(current, systemImage: "airplane", tone: ColorKey.blue.tone, weight: .bold)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch model.loadState {
        case .idle, .loading:
            ProgressView("Chargement…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        case let .failed(message):
            GroupsStateView(
                systemImage: "wifi.exclamationmark",
                title: "Impossible de charger ton absence",
                message: message
            ) {
                Button("Réessayer") {
                    Task { await model.reload() }
                }
                .buttonStyle(.secondary)
            }
        case .loaded:
            datesCard
            handoversSection
        }
    }

    /// « Du », « Au » and « Prévenir mes groupes ».
    private var datesCard: some View {
        VStack(spacing: 0) {
            DatePicker(
                AwayModeViewModel.fromTitle,
                selection: $model.fromDate,
                in: model.earliestDate...,
                displayedComponents: .date
            )
            .font(Font.body.weight(.bold))
            .frame(minHeight: 56)
            .accessibilityIdentifier(AccessibilityID.Social.awayFromPicker)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .accessibilityHidden(true)
            DatePicker(
                AwayModeViewModel.untilTitle,
                selection: $model.untilDate,
                in: model.fromDate...model.latestUntilDate,
                displayedComponents: .date
            )
            .font(Font.body.weight(.bold))
            .frame(minHeight: 56)
            .accessibilityIdentifier(AccessibilityID.Social.awayUntilPicker)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .accessibilityHidden(true)
            Toggle(isOn: $model.announce) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AwayModeViewModel.announceTitle)
                        .font(Font.body.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(AwayModeViewModel.announceMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.accentFill)
            .frame(minHeight: 60)
            .accessibilityIdentifier(AccessibilityID.Social.awayAnnounceToggle)
        }
        .padding(.horizontal, Theme.Spacing.cardPadding)
        .padding(.vertical, 4)
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .cardSurface()
    }

    /// « Tes tours pendant ce temps »: each turn handed over, and who takes it.
    private var handoversSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(AwayModeViewModel.handoversTitle)
            let handovers = model.handovers
            VStack(spacing: 0) {
                if handovers.isEmpty {
                    Text(AwayModeViewModel.noHandoverText)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                } else {
                    ForEach(Array(handovers.enumerated()), id: \.element.id) { index, handover in
                        if index > 0 {
                            Rectangle()
                                .fill(Theme.hairline)
                                .frame(height: 1)
                                .accessibilityHidden(true)
                        }
                        HStack(alignment: .center, spacing: 12) {
                            IconTile(systemImage: "arrow.triangle.2.circlepath", tone: ColorKey.coral.tone, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(handover.title)
                                    .font(Font.subheadline.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(handover.text)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if let taker = handover.taker {
                                AvatarView(taker.appearance, size: 28)
                            }
                        }
                        .frame(minHeight: 60)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.cardPadding)
            .padding(.vertical, 4)
            .cardSurface()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Social.awayHandovers)
        }
    }

    /// « Activer le mode absent » (or « Modifier mon absence »), and « Terminer mon absence » while one is set.
    private var buttons: some View {
        VStack(spacing: 8) {
            if let message = model.rangeError {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PrimaryButton(model.saveTitle, systemImage: "airplane", isLoading: model.isSaving) {
                Task { await model.activate() }
            }
            .disabled(!model.canSave)
            .accessibilityIdentifier(AccessibilityID.Social.awaySaveButton)
            if model.isAway {
                Button(role: .destructive) {
                    Task { await model.endAbsence() }
                } label: {
                    Text(AwayModeViewModel.endTitle)
                }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.danger))
                .disabled(model.isSaving)
                .accessibilityIdentifier(AccessibilityID.Social.awayEndButton)
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Shell.pinnedBottomBar)
    }
}

/// A « Mode absent » sheet to present (`.sheet(item:)`).
struct AwayModeSheetItem: Identifiable {
    let id = UUID()
    let model: AwayModeViewModel

    init(model: AwayModeViewModel) {
        self.model = model
    }
}
