import SwiftUI
import TeamTasksCore

/// Every component of the design system with sample data, on four pages (UI tests only: the mock backend with
/// `-uiTestDesignGallery`). The design checks capture it in light and dark mode, so that the components the v2 screens
/// will use can be looked at before those screens exist. Not reachable in the app.
struct DesignGalleryView: View {
    enum Page: Int, CaseIterable, Identifiable {
        case base = 1
        case tasks
        case controls
        case groups

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .base: "Base"
            case .tasks: "Tâches"
            case .controls: "Contrôles"
            case .groups: "Groupes"
            }
        }
    }

    @State private var page = Page.base

    var body: some View {
        VStack(spacing: 12) {
            SegmentedPill(
                Page.allCases,
                selection: $page,
                identifier: { AccessibilityID.Gallery.page($0.rawValue) }
            ) { page in
                page.title
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch page {
                    case .base: GalleryBasePage()
                    case .tasks: GalleryTasksPage()
                    case .controls: GalleryControlsPage()
                    case .groups: GalleryGroupsPage()
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A new scroll view per page: each one starts at its top.
            .id(page)
        }
        .screenBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Gallery.screen)
    }
}

// MARK: - Sample data

private enum GallerySample {
    static let camille = person("Camille", color: .indigo, emoji: nil, initials: "CM", isMe: true)
    static let lucas = person("Lucas", color: .teal, emoji: nil, initials: "LB")
    static let ines = person("Inès", color: .orange, emoji: "\u{1F98A}", initials: "ID")
    static let alex = person("Alex", color: .pink, emoji: nil, initials: "AM")

    static let lilas = AvatarAppearance(color: .coral, emoji: "\u{1F3E0}", initials: "CR")
    static let sport = AvatarAppearance(color: .green, emoji: "\u{26BD}", initials: "PA")
    static let club = AvatarAppearance(color: .violet, emoji: nil, initials: "CL")

    static func person(
        _ name: String,
        color: ColorKey,
        emoji: String?,
        initials: String,
        isMe: Bool = false
    ) -> PersonBadge {
        PersonBadge(
            id: UUID(),
            name: name,
            shortName: name,
            appearance: AvatarAppearance(color: color, emoji: emoji, initials: initials),
            isMe: isMe,
            isMember: true
        )
    }

    static func task(
        _ title: String,
        status: TaskStatus = .todo,
        priority: TeamTasksCore.TaskPriority = .medium,
        recurrence: RecurrenceRule? = nil,
        rotation: [UUID] = [],
        checklist: [ChecklistItem] = [],
        group: (name: String, color: ColorKey, emoji: String?)? = nil
    ) -> TaskItem {
        TaskItem(
            id: UUID(),
            groupId: UUID(),
            title: title,
            status: status,
            priority: priority,
            createdBy: nil,
            createdAt: Date(),
            updatedAt: Date(),
            groupName: group?.name,
            recurrence: recurrence,
            rotation: rotation,
            checklist: checklist,
            groupColor: group?.color,
            groupEmoji: group?.emoji
        )
    }

    static func checklist(done: Int, total: Int) -> [ChecklistItem] {
        (0..<total).map { index in
            ChecklistItem(id: UUID(), title: "Élément \(index + 1)", position: index, isDone: index < done)
        }
    }

    /// « Mes tâches » rows (group chip, no assignees).
    static let myTasksRows: [TaskRow] = [
        TaskRow(
            task: task(
                "Sortir les poubelles",
                recurrence: RecurrenceRule(frequency: .weekly, timeZoneId: "Europe/Paris"),
                rotation: [camille.id, lucas.id],
                group: ("Coloc’ rue des Lilas", .coral, "\u{1F3E0}")
            ),
            dueText: "Aujourd’hui à 20:00", isOverdue: false, assigneesText: nil, groupName: "Coloc’ rue des Lilas",
            isNew: false, canChangeStatus: true, canEdit: true, canDelete: true, isMyTurn: true
        ),
        TaskRow(
            task: task(
                "Préparer le tournoi",
                status: .inProgress,
                checklist: checklist(done: 3, total: 6),
                group: ("Projet Asso Sport", .green, "\u{26BD}")
            ),
            dueText: "Demain à 18:00", isOverdue: false, assigneesText: nil, groupName: "Projet Asso Sport",
            isNew: true, canChangeStatus: true, canEdit: true, canDelete: true
        ),
    ]

    /// Group screen rows (assignees, no group chip).
    static let groupRows: [TaskRow] = [
        TaskRow(
            task: task(
                "Payer le loyer",
                priority: .high,
                recurrence: RecurrenceRule(frequency: .monthly, timeZoneId: "Europe/Paris")
            ),
            dueText: "Hier à 18:00", isOverdue: true, assigneesText: "Inès", groupName: nil,
            isNew: false, canChangeStatus: true, canEdit: true, canDelete: true, assignees: [ines]
        ),
        TaskRow(
            task: task("Réparer la fuite du lavabo", priority: .low, checklist: checklist(done: 0, total: 3)),
            dueText: nil, isOverdue: false, assigneesText: MemberDirectory.unassignedText, groupName: nil,
            isNew: false, canChangeStatus: false, canEdit: false, canDelete: false
        ),
        TaskRow(
            task: task("Faire les courses", checklist: checklist(done: 5, total: 5)),
            dueText: "Samedi à 11:00", isOverdue: false, assigneesText: "Toi, Lucas, Inès, Alex", groupName: nil,
            isNew: false, canChangeStatus: true, canEdit: true, canDelete: true, assignees: [camille, lucas, ines, alex]
        ),
        TaskRow(
            task: task("Nettoyer la cuisine", status: .done),
            dueText: nil, isOverdue: false, assigneesText: "Lucas", groupName: nil,
            isNew: false, canChangeStatus: true, canEdit: true, canDelete: true, assignees: [lucas]
        ),
    ]

    static let podium: [PodiumEntry] = [
        PodiumEntry(person: camille, count: 5, place: 2),
        PodiumEntry(person: ines, count: 6, place: 1),
        PodiumEntry(person: lucas, count: 3, place: 3),
    ]
}

// MARK: - Pages

/// Colors, typography, icon tiles, titles.
private struct GalleryBasePage: View {
    var body: some View {
        SectionTitle("Palette", size: .large)
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(ColorKey.allCases) { key in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(key.fill)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Text("Aa")
                                .font(.rounded(.headline))
                                .foregroundStyle(Theme.onFill)
                        }
                    Chip(key.label, tone: key.tone)
                }
            }
        }
        Card {
            SectionTitle("Neutres", size: .large)
            HStack(spacing: 8) {
                swatch(Theme.background, "background")
                swatch(Theme.card, "card")
                swatch(Theme.track, "track")
                swatch(Theme.accentSoft, "accentSoft")
            }
            Text("Texte principal").foregroundStyle(Theme.textPrimary)
            Text("Texte secondaire").foregroundStyle(Theme.textSecondary)
            Text("Accent").foregroundStyle(Theme.accent).fontWeight(.bold)
            Text("En retard").foregroundStyle(Theme.danger).fontWeight(.bold)
        }
        Card {
            Text("Titre d’écran").font(.rounded(.largeTitle)).foregroundStyle(Theme.textPrimary)
            Text("Titre d’étape").font(.rounded(.title)).foregroundStyle(Theme.textPrimary)
            SectionTitle("À qui le tour\u{00A0}?", size: .large, trailing: "2 tâches tournantes")
            SectionTitle("En retard", color: Theme.danger)
            Text("Titre de carte").font(.headline).foregroundStyle(Theme.textPrimary)
            Text("Texte courant, en SF Pro, qui passe à la ligne sans être coupé.").foregroundStyle(Theme.textPrimary)
            Text("14").font(.roundedNumber(.largeTitle)).foregroundStyle(Theme.accent)
        }
        HStack(spacing: 10) {
            IconTile(systemImage: "calendar")
            IconTile(systemImage: "arrow.triangle.2.circlepath", tone: ColorKey.coral.tone)
            IconTile(systemImage: "checklist", tone: ColorKey.teal.tone, size: 36)
            IconTile(systemImage: "trophy.fill", tone: ColorKey.amber.tone, size: 48)
            IconTile(systemImage: "flag.fill", tone: TeamTasksCore.TaskPriority.medium.tone)
        }
    }

    private func swatch(_ color: Color, _ name: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color)
                .frame(height: 36)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }
            Text(name)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Status controls, chips and task rows.
private struct GalleryTasksPage: View {
    @State private var filter = 1

    var body: some View {
        HStack(spacing: 4) {
            StatusControl(status: .todo, tint: ColorKey.coral.accent) {}
            StatusControl(status: .inProgress) {}
            StatusControl(status: .done) {}
            StatusControl(status: .todo, isBusy: true) {}
            StatusControl(status: .todo, tint: ColorKey.green.accent, isEnabled: false) {}
        }
        FlowLayout(spacing: 8, lineSpacing: 8) {
            Chip("\u{1F3E0} Coloc’", tone: ColorKey.coral.tone)
            Chip(TaskStatus.inProgress.label, tone: TaskStatus.inProgress.tone)
            Chip(TaskStatus.done.label, tone: TaskStatus.done.tone)
            Chip("Haute", systemImage: "flag.fill", tone: TeamTasksCore.TaskPriority.high.tone)
            Chip("Basse", systemImage: "flag.fill", tone: TeamTasksCore.TaskPriority.low.tone)
            Chip("1 en retard", tone: .danger)
            Chip("20:00", systemImage: "clock", tone: .ink(Theme.textSecondary), style: .plain)
            Chip("Ton tour", systemImage: "arrow.triangle.2.circlepath", tone: .ink(Theme.accent), style: .plain, weight: .bold)
            NewBadge()
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChipButton("À faire · 4", isSelected: filter == 1) { filter = 1 }
                FilterChipButton("En cours · 1", isSelected: filter == 2) { filter = 2 }
                FilterChipButton("Terminées · 6", isSelected: filter == 3) { filter = 3 }
            }
        }
        SectionTitle("Aujourd’hui")
        ForEach(GallerySample.myTasksRows) { row in
            TaskRowCard(row: row) {}
        }
        SectionTitle("Groupe")
        ForEach(GallerySample.groupRows) { row in
            TaskRowCard(row: row, tint: ColorKey.coral.accent) {}
        }
    }
}

/// Segmented pills, buttons and progress.
private struct GalleryControlsPage: View {
    @State private var tab = 0
    @State private var status = TaskStatus.inProgress
    @State private var frequency = RepeatFrequency.weekly
    @State private var priority = TeamTasksCore.TaskPriority.medium

    var body: some View {
        SegmentedPill([0, 1], selection: $tab) { $0 == 0 ? "Tâches" : "Activité" }
        SegmentedPill(TaskStatus.allCases, selection: $status, tone: { .soft($0.tone) }) { $0.label }
        Card {
            SegmentedPill(RepeatFrequency.allCases, selection: $frequency, tone: { _ in .filled(Theme.accentFill) },
                          track: Theme.hairline) { $0.label }
        }
        SegmentedPill(
            [TeamTasksCore.TaskPriority.low, .medium, .high],
            selection: $priority,
            tone: { .soft($0.tone) },
            track: Theme.card
        ) { $0.label }
        .cardSurface(radius: Theme.Radius.track)

        PrimaryButton("C’est parti", systemImage: "arrow.right", iconPlacement: .trailing) {}
        PrimaryButton("Activer les notifications", systemImage: "bell.fill", isLoading: true) {}
        PrimaryButton("Créer le groupe") {}
            .disabled(true)
        Button("Plus tard") {}
            .buttonStyle(.secondary)

        HStack(spacing: 12) {
            CircleIconButton(systemImage: "chevron.left", accessibilityLabel: "Retour") {}
            Spacer()
            CircleIconButton(systemImage: "chevron.left", accessibilityLabel: "Retour", style: .translucent) {}
            CircleIconButton(systemImage: "ellipsis", accessibilityLabel: "Plus d’options", style: .translucent) {}
        }
        .padding(12)
        .background(ColorKey.coral.fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

        Card {
            HStack(spacing: 16) {
                ProgressRing(progress: 0.5, text: "2/4", accessibilityLabel: "Ta journée")
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ta journée").font(.rounded(.headline, weight: .heavy)).foregroundStyle(Theme.textPrimary)
                    ProgressBar(value: 0.69, tint: ColorKey.coral.fill, track: Theme.hairline)
                    ProgressBar(value: 0.4, tint: ColorKey.teal.fill, track: ColorKey.teal.tone.background)
                }
            }
        }
        StepProgress(current: 2, total: 4)
        FloatingAddButton(accessibilityLabel: "Nouvelle tâche") {}
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Avatars, group tiles, the podium and the pickers.
private struct GalleryGroupsPage: View {
    @State private var color = ColorKey.coral
    @State private var emoji: String? = "\u{1F3E0}"

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AvatarView(GallerySample.camille.appearance, size: 26)
            AvatarView(GallerySample.lucas.appearance, size: 32)
            AvatarView(GallerySample.ines.appearance, size: 40)
            AvatarView(GallerySample.alex.appearance, size: 48, ring: Theme.card, highlight: Theme.accent)
            AvatarStack(people: [GallerySample.camille, GallerySample.lucas, GallerySample.ines, GallerySample.alex])
            UnassignedAvatar()
        }
        HStack(spacing: 12) {
            GroupTile(GallerySample.lilas)
            GroupTile(GallerySample.sport, size: 40)
            GroupTile(GallerySample.club)
            HStack(spacing: 10) {
                GroupTile(GallerySample.lilas, size: 48, style: .onColor)
                AvatarStack(
                    avatars: [GallerySample.camille.appearance, GallerySample.lucas.appearance],
                    overflowText: "+2",
                    size: 26,
                    surface: ColorKey.coral.fill
                )
            }
            .padding(10)
            .background(ColorKey.coral.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        Card {
            SectionTitle("Cette semaine", size: .large, trailing: "14 tâches faites")
            PodiumView(entries: GallerySample.podium)
        }
        Card {
            PickerSection("Couleur") {
                SwatchGrid(isSelected: { $0 == color }, onSelect: { color = $0 })
            }
            PickerSection("Emoji") {
                EmojiGrid(options: Array(EmojiChoices.groups.prefix(12)), selection: emoji) { option in
                    emoji = option == emoji ? nil : option
                }
            }
        }
    }
}
