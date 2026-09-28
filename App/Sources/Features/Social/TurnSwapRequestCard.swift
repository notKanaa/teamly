import SwiftUI
import TeamTasksCore

/// A turn proposed to the user (docs/CONTRACTS-V3.md §3): the proposer's avatar, « **Lucas** te propose son tour pour
/// « Ranger le matériel » », the task's due date and group (« Mes tâches »), then « Refuser » and « Accepter ». The
/// buttons wait while the answer is sent (`isBusy`). Used by « Mes tâches », the group screen and the task screen.
struct TurnSwapRequestCard: View {
    let request: TurnSwapRequest
    let isBusy: Bool
    let onAnswer: (Bool) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(request: TurnSwapRequest, isBusy: Bool, onAnswer: @escaping (Bool) -> Void) {
        self.request = request
        self.isBusy = isBusy
        self.onAnswer = onAnswer
    }

    private var title: String { request.taskTitle ?? "" }

    var body: some View {
        Card(padding: 14, spacing: 12, radius: Theme.Radius.row) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(request.from.appearance, size: 40)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Theme.onFill)
                            .frame(width: 20, height: 20)
                            .background(ColorKey.teal.fill, in: Circle())
                            .background {
                                Circle()
                                    .fill(Theme.card)
                                    .padding(-2)
                            }
                            .offset(x: 5, y: 5)
                            .accessibilityHidden(true)
                    }
                    .padding(.trailing, 5)
                VStack(alignment: .leading, spacing: 6) {
                    Text(GroupActivityText.attributed(request.text))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if request.dueText != nil || request.groupName != nil {
                        FlowLayout(spacing: 8, lineSpacing: 4) {
                            if let group = request.groupAppearance, let name = request.groupName {
                                Chip(group.emoji.map { "\($0) \(GroupShortName.of(name))" } ?? GroupShortName.of(name), tone: group.color.tone)
                            }
                            if let due = request.dueText {
                                Chip(due, systemImage: "clock", tone: .ink(Theme.textSecondary), style: .plain)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            buttons
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Social.swapRequest(title))
    }

    @ViewBuilder private var buttons: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Button {
                onAnswer(false)
            } label: {
                Text(TurnSwapText.declineTitle)
            }
            .buttonStyle(.soft(SoftTone.neutral))
            .accessibilityIdentifier(AccessibilityID.Social.declineSwap(title))
            Button {
                onAnswer(true)
            } label: {
                if isBusy {
                    ProgressView()
                        .tint(Theme.onFill)
                        .accessibilityLabel("En cours")
                } else {
                    Label(TurnSwapText.acceptTitle, systemImage: "checkmark")
                }
            }
            .buttonStyle(SoftButtonStyle(tone: SoftTone(background: Theme.accentFill, foreground: Theme.onFill, fill: Theme.accentFill)))
            .accessibilityIdentifier(AccessibilityID.Social.acceptSwap(title))
        }
        .disabled(isBusy)
    }
}

/// The turns proposed to the user in the list of a screen (« Mes tâches », the group screen): one card per proposal,
/// then the confirmation of the last answer in the flow. Show it while `model.hasContent`; the screen loads the model
/// (`.task(id: model.refreshKey) { await model.load() }`), so that nothing takes room when there is no proposal.
struct TurnSwapRequestsList: View {
    let model: TurnSwapRequestsViewModel

    init(model: TurnSwapRequestsViewModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.requests.isEmpty {
                SectionTitle(TurnSwapRequestsViewModel.title)
                ForEach(model.requests) { request in
                    TurnSwapRequestCard(request: request, isBusy: model.busySwapIds.contains(request.id)) { accept in
                        Task { await model.respond(to: request, accept: accept) }
                    }
                }
            }
            InlineToast(notice: toastBinding)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Social.swapRequests)
        .shellErrorAlert(model)
    }

    private var toastBinding: Binding<ToastNotice?> {
        Binding(
            get: { model.toast },
            set: { model.toast = $0 }
        )
    }
}
