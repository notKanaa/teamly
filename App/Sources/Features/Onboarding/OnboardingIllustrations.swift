import SwiftUI
import TeamTasksCore

/// The illustration of the welcome step (docs/DESIGN-V2.md §7.1): three task cards stacked at slight angles over soft
/// shapes, drawn with the design system (no image). Drawn on a 342 × 200 canvas scaled to the available width.
/// Decorative: hidden from VoiceOver.
struct OnboardingTaskCardsIllustration: View {
    private static let canvasSize = CGSize(width: 342, height: 200)

    var body: some View {
        Color.clear
            .aspectRatio(Self.canvasSize.width / Self.canvasSize.height, contentMode: .fit)
            .frame(maxWidth: Self.canvasSize.width)
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    canvas
                        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height, alignment: .topLeading)
                        .scaleEffect(proxy.size.width / Self.canvasSize.width, anchor: .topLeading)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(ColorKey.coral.tone.background)
                .frame(width: 96, height: 96)
                .offset(x: 242, y: 0)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(ColorKey.amber.tone.background)
                .frame(width: 64, height: 64)
                .rotationEffect(.degrees(12))
                .offset(x: 0, y: 132)
            Circle()
                .fill(ColorKey.teal.tone.background)
                .frame(width: 40, height: 40)
                .offset(x: 266, y: 160)

            SampleTaskCard(
                title: "Arroser les plantes",
                status: .done,
                tint: ColorKey.green.accent,
                person: AvatarAppearance(color: .orange, emoji: nil, initials: "I")
            )
            .frame(width: 262, height: 60)
            .rotationEffect(.degrees(-5))
            .offset(x: 30, y: 14)

            SampleTaskCard(
                title: "Sortir les poubelles",
                status: .todo,
                tint: ColorKey.coral.accent,
                person: AvatarAppearance(color: .indigo, emoji: nil, initials: "C"),
                symbol: "arrow.triangle.2.circlepath"
            )
            .frame(width: 270, height: 60)
            .rotationEffect(.degrees(3))
            .offset(x: 62, y: 76)

            SampleTaskCard(
                title: "Faire les courses",
                status: .todo,
                tint: ColorKey.amber.accent,
                person: AvatarAppearance(color: .teal, emoji: nil, initials: "L"),
                chip: "2/5"
            )
            .frame(width: 282, height: 60)
            .rotationEffect(.degrees(-2))
            .offset(x: 16, y: 136)
        }
    }
}

/// One card of the welcome illustration: a status glyph, a title, an optional symbol or chip, and an avatar.
private struct SampleTaskCard: View {
    let title: String
    let status: TaskStatus
    let tint: Color
    let person: AvatarAppearance
    var symbol: String?
    var chip: String?

    var body: some View {
        HStack(spacing: 12) {
            StatusGlyph(status, tint: tint, size: 24)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .strikethrough(status == .done)
                .foregroundStyle(status == .done ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            if let chip {
                Text(chip)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(ColorKey.teal.tone.foreground)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(ColorKey.teal.tone.background, in: Capsule())
            }
            AvatarView(person, size: 28)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardSurface(radius: 18, elevation: .raised)
    }
}

/// The illustration of the notifications step (docs/DESIGN-V2.md §7.1): three sample notifications of « Équipe »
/// (a turn, an assignment, the weekly recap), as cards with the app icon. Text capped at the xxLarge size. Decorative:
/// hidden from VoiceOver.
struct OnboardingNotificationSamples: View {
    private struct Sample {
        let time: String
        let text: String
    }

    private let samples = [
        Sample(
            time: "maintenant",
            text: "C’est ton tour\u{00A0}: «\u{00A0}Sortir les poubelles\u{00A0}», ce soir à 20:00."
        ),
        Sample(
            time: "il y a 5 min",
            text: "Lucas t’a confié «\u{00A0}Faire les courses\u{00A0}» pour demain."
        ),
        Sample(
            time: "lundi",
            text: "Le récap de la semaine est prêt\u{00A0}: 14 tâches faites dans ta coloc."
        ),
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                card(sample)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityHidden(true)
    }

    private func card(_ sample: Sample) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(decorative: "AppLogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Équipe")
                        .font(Font.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 8)
                    Text(sample.time)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(sample.text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 22, elevation: .raised)
    }
}
