import SwiftUI
import TeamTasksCore

// The v3 parts of the task screen (docs/CONTRACTS-V3.md), as sections of its `List`: the social actions under the
// header (« Relancer », « Échanger mon tour », « Ajouter une photo ? »), the photos and the comments.

/// Under the header, on the screen's ground: « Relancer Inès » (a soft red button), « Proposer mon tour à… » (a menu of
/// the rotation's members) or the proposal waiting for an answer (« Annuler »), the proposal made to the user
/// (« Accepter » / « Refuser »), and « Ajouter une photo ? » after the user completed the task. Nothing when none
/// applies.
struct TaskDetailSocialActions: View {
    @Bindable var model: TaskDetailViewModel
    /// Opens the photo picker (« Ajouter une photo ? »).
    let onAddPhoto: () -> Void

    init(model: TaskDetailViewModel, onAddPhoto: @escaping () -> Void) {
        self.model = model
        self.onAddPhoto = onAddPhoto
    }

    private var hasContent: Bool {
        model.canNudge || model.canProposeSwap || model.outgoingSwapText != nil || model.incomingSwapRequest != nil
            || model.showsPhotoPrompt
    }

    var body: some View {
        if hasContent {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    if let request = model.incomingSwapRequest {
                        TurnSwapRequestCard(request: request, isBusy: model.isChangingSwap) { accept in
                            Task { await model.respondToSwap(accept: accept) }
                        }
                    }
                    if model.showsPhotoPrompt {
                        TaskPhotoPromptCard(onAdd: onAddPhoto) {
                            model.dismissPhotoPrompt()
                        }
                    }
                    if model.canNudge {
                        nudgeButton
                    }
                    if model.canProposeSwap {
                        proposeMenu
                    } else if let waiting = model.outgoingSwapText {
                        outgoingSwap(waiting)
                    }
                }
                .padding(.bottom, 4)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
        }
    }

    /// « Relancer Inès », then « Relance envoyée » (disabled).
    private var nudgeButton: some View {
        Button {
            Task { await model.nudge() }
        } label: {
            HStack(spacing: 8) {
                if model.isNudging {
                    ProgressView()
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: model.hasNudged ? "checkmark" : "bell.badge.fill")
                        .accessibilityHidden(true)
                }
                Text(model.nudgeButtonTitle)
            }
        }
        .buttonStyle(.soft(.danger))
        .disabled(model.isNudging || model.hasNudged)
        .accessibilityHint(model.hasNudged ? "" : NudgeText.hint)
        .accessibilityIdentifier(AccessibilityID.Social.nudgeButton)
    }

    /// « Proposer mon tour à… »: the rotation's other members.
    private var proposeMenu: some View {
        Menu {
            ForEach(model.swapCandidates) { person in
                Button {
                    Task { await model.proposeSwap(to: person.id) }
                } label: {
                    Text(person.shortName)
                }
                .accessibilityIdentifier(AccessibilityID.Social.proposeSwapOption(person.shortName))
            }
        } label: {
            Label(TurnSwapText.proposeTitle, systemImage: "arrow.left.arrow.right")
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.button)
        .buttonStyle(.soft(ColorKey.teal.tone))
        .disabled(model.isChangingSwap)
        .accessibilityIdentifier(AccessibilityID.Social.proposeSwapMenu)
    }

    /// « En attente de la réponse de Lucas » and « Annuler ».
    private func outgoingSwap(_ text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            IconTile(systemImage: "hourglass", tone: ColorKey.teal.tone, size: 32)
            Text(text)
                .font(Font.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await model.cancelSwap() }
            } label: {
                Text("Annuler")
            }
            .buttonStyle(SoftButtonStyle(tone: SoftTone.neutral, isFullWidth: false))
            .disabled(model.isChangingSwap)
            .accessibilityLabel(TurnSwapText.cancelTitle)
            .accessibilityIdentifier(AccessibilityID.Social.cancelSwapButton)
        }
        .padding(12)
        .cardSurface(radius: Theme.Radius.row)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Social.outgoingSwap)
    }
}

/// « Ajouter une photo ? » after the user completed the task: a light card with « Ajouter une photo » and « Non merci ».
struct TaskPhotoPromptCard: View {
    let onAdd: () -> Void
    let onDismiss: () -> Void

    init(onAdd: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onAdd = onAdd
        self.onDismiss = onDismiss
    }

    var body: some View {
        Card(padding: 14, spacing: 12, radius: Theme.Radius.row) {
            HStack(alignment: .center, spacing: 12) {
                IconTile(systemImage: "camera.fill", tone: ColorKey.green.tone, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PhotoText.promptTitle)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text(PhotoText.promptMessage)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    dismissButton
                    addButton
                }
                VStack(spacing: 8) {
                    addButton
                    dismissButton
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Social.photoPrompt)
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Label(PhotoText.addTitle, systemImage: "plus")
        }
        .buttonStyle(.soft(ColorKey.green.tone))
        .accessibilityIdentifier(AccessibilityID.Social.photoPromptAdd)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Text(PhotoText.promptDismissTitle)
        }
        .buttonStyle(.soft(SoftTone.neutral))
        .accessibilityIdentifier(AccessibilityID.Social.photoPromptDismiss)
    }
}

// MARK: - Photos

/// « Photos »: the thumbnails, oldest first (a tap opens the photo), and « Ajouter une photo » (a dashed tile) while the
/// user may add one. Shown when there is a photo or the right to add one.
struct TaskDetailPhotosSection: View {
    let model: TaskDetailViewModel
    let onAddPhoto: () -> Void
    let onOpen: (TaskPhoto) -> Void

    @ScaledMetric(relativeTo: .body) private var tileSide: CGFloat = 96

    init(model: TaskDetailViewModel, onAddPhoto: @escaping () -> Void, onOpen: @escaping (TaskPhoto) -> Void) {
        self.model = model
        self.onAddPhoto = onAddPhoto
        self.onOpen = onOpen
    }

    var body: some View {
        if model.showsPhotos {
            Section {
                let photos = model.photos
                LazyVGrid(columns: [GridItem(.adaptive(minimum: min(tileSide, 160)), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        Button {
                            onOpen(photo)
                        } label: {
                            // A square tile, the photo filling it.
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    TaskPhotoImage(photo: photo, model: model, contentMode: .fill)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel(model.accessibilityLabel(of: photo))
                        .accessibilityHint("Affiche la photo")
                        .accessibilityIdentifier(AccessibilityID.Social.photoThumbnail(index))
                    }
                    if model.canAddPhoto || model.isUploadingPhoto {
                        addTile
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.Social.photos)
                if photos.isEmpty && !model.isUploadingPhoto {
                    Text(PhotoText.emptyText)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            } header: {
                HStack {
                    Text(PhotoText.title)
                    Spacer()
                    if !model.photos.isEmpty {
                        Text(PhotoText.countText(model.photos.count))
                            .textCase(nil)
                    }
                }
            }
            .listRowBackground(Theme.card)
        }
    }

    /// « Ajouter une photo »: a dashed tile, a spinner while uploading.
    private var addTile: some View {
        Button(action: onAddPhoto) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.trackStrong, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                if model.isUploadingPhoto {
                    ProgressView()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                            .font(.title3.weight(.bold))
                        Text("Ajouter")
                            .font(Font.footnote.weight(.bold))
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.pressable)
        .disabled(model.isUploadingPhoto || !model.canAddPhoto)
        .accessibilityLabel(model.isUploadingPhoto ? "Envoi de la photo en cours" : PhotoText.addTitle)
        .accessibilityIdentifier(AccessibilityID.Social.addPhotoButton)
    }
}

// MARK: - Comments

/// « Commentaires »: the comments as bubbles (the user's on the right, in the accent), the mentions in bold, a long
/// press or a swipe deleting one when allowed; then the composer with the suggestions of the mention being typed
/// (« @Ca » → « Camille »).
struct TaskDetailCommentsSection: View {
    @Bindable var model: TaskDetailViewModel

    @FocusState private var isComposerFocused: Bool
    /// The UI tests type « @Lu » and pick « @Lucas »: no correction may change what they type.
    @Environment(\.isUITesting) private var isUITesting

    init(model: TaskDetailViewModel) {
        self.model = model
    }

    var body: some View {
        Section {
            let rows = model.commentRows
            if rows.isEmpty {
                Text(CommentText.emptyText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rows) { row in
                TaskCommentBubble(row: row, isDeleting: model.deletingCommentIds.contains(row.id))
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        if row.canDelete {
                            Button(role: .destructive) {
                                Task { await model.deleteComment(row.id) }
                            } label: {
                                Label(CommentText.deleteTitle, systemImage: "trash")
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if row.canDelete {
                            Button(role: .destructive) {
                                Task { await model.deleteComment(row.id) }
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                    }
                    .accessibilityActions {
                        if row.canDelete {
                            Button(CommentText.deleteTitle) {
                                Task { await model.deleteComment(row.id) }
                            }
                        }
                    }
            }
            if model.canComment {
                composer
                    .listRowSeparator(.hidden)
            }
        } header: {
            HStack {
                Text(CommentText.title)
                Spacer()
                if !model.comments.isEmpty {
                    Text("\(model.comments.count)")
                        .accessibilityLabel(model.commentsCountText)
                }
            }
        }
        .listRowBackground(Theme.card)
    }

    /// The suggestions of the mention being typed, the field and « Envoyer »; the refused text's message under them.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            let suggestions = model.mentionSuggestions
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions) { person in
                            Button {
                                model.insertMention(person)
                            } label: {
                                HStack(spacing: 6) {
                                    AvatarView(person.appearance, size: 24)
                                    Text("@\(person.shortName)")
                                        .font(Font.subheadline.weight(.bold))
                                        .foregroundStyle(Theme.accentSoftText)
                                }
                                .padding(.leading, 4)
                                .padding(.trailing, 12)
                                .frame(minHeight: 44)
                                .background(Theme.accentSoft, in: Capsule())
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel("Mentionner \(person.name)")
                            .accessibilityIdentifier(AccessibilityID.Social.mentionSuggestion(person.shortName))
                        }
                    }
                }
                .scrollClipDisabled()
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(CommentText.placeholder, text: $model.commentDraft, axis: .vertical)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(isUITesting)
                    .focused($isComposerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(minHeight: 44)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityLabel("Commentaire")
                    .accessibilityIdentifier(AccessibilityID.Social.commentField)
                Button {
                    send()
                } label: {
                    Group {
                        if model.isSendingComment {
                            ProgressView()
                                .tint(Theme.onFill)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.heavy))
                        }
                    }
                    .foregroundStyle(Theme.onFill)
                    .frame(width: 44, height: 44)
                    .background(model.canSendComment ? Theme.accentFill : Theme.trackStrong, in: Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.pressable)
                .disabled(!model.canSendComment)
                .accessibilityLabel(CommentText.sendTitle)
                .accessibilityIdentifier(AccessibilityID.Social.commentSendButton)
            }
            if let message = model.commentError {
                TaskEditorErrorText(message: message)
                    .font(.footnote)
            }
        }
        .padding(.vertical, 6)
    }

    private func send() {
        Task {
            if await model.sendComment() {
                isComposerFocused = false
            }
        }
    }
}

/// A comment as a bubble: the others' on the left under their avatar, name and time, on the ground's gray; the user's
/// on the right in the accent. The mentions in bold. One VoiceOver element: « Lucas, aujourd’hui à 14:32 : … ».
struct TaskCommentBubble: View {
    let row: CommentRow
    let isDeleting: Bool

    init(row: CommentRow, isDeleting: Bool) {
        self.row = row
        self.isDeleting = isDeleting
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if row.isMine {
                Spacer(minLength: 40)
            } else if let author = row.author {
                AvatarView(author.appearance, size: 32)
            } else {
                UnassignedAvatar(size: 32)
            }
            VStack(alignment: row.isMine ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if !row.isMine {
                        Text(row.authorName)
                            .font(Font.footnote.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text(row.timeText)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(Self.attributed(row.body, isMine: row.isMine))
                    .font(.subheadline)
                    .foregroundStyle(row.isMine ? Theme.onFill : Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        row.isMine ? Theme.accentFill : Theme.background,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 16,
                            bottomLeadingRadius: row.isMine ? 16 : 4,
                            bottomTrailingRadius: row.isMine ? 4 : 16,
                            topTrailingRadius: 16,
                            style: .continuous
                        )
                    )
                    .opacity(isDeleting ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity, alignment: row.isMine ? .trailing : .leading)
            if !row.isMine {
                Spacer(minLength: 24)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.authorName), \(row.timeText.lowercased())\u{00A0}: \(row.body.plainText)")
        .accessibilityIdentifier(AccessibilityID.Social.comment)
    }

    /// The text with its mentions in bold (and in the accent on the others' bubbles).
    static func attributed(_ text: EmphasizedText, isMine: Bool) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            var part = AttributedString(run.text)
            if run.isEmphasized {
                part.inlinePresentationIntent = .stronglyEmphasized
                if !isMine {
                    part.foregroundColor = Theme.accent
                }
            }
            result.append(part)
        }
        return result
    }
}
