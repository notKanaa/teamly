import Observation
import SwiftUI
import UIKit

/// A burst of confetti (docs/DESIGN-V2.md §5, v3): about 70 small pieces in the palette's colors, thrown up from the
/// upper third of the frame, then falling and spinning for 2 s, fading at the end. Each change of `trigger` starts a
/// new burst. Nothing is drawn with Reduce Motion. Decorative: no hit testing, hidden from VoiceOver.
///
/// The app draws one over everything (`TeamTasksApp`) and starts it through `\.celebrate` when the user completes a
/// task, if « Confettis » is on (Réglages › Apparence).
struct ConfettiBurst: View {
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate: Date?
    @State private var pieces: [ConfettiPiece] = []

    init(trigger: Int) {
        self.trigger = trigger
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: startDate == nil)) { timeline in
            Canvas { context, size in
                guard let startDate else { return }
                let elapsed = timeline.date.timeIntervalSince(startDate)
                guard elapsed >= 0, elapsed < ConfettiPiece.lifetime else { return }
                for piece in pieces {
                    piece.draw(in: context, size: size, elapsed: elapsed)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in
            start()
        }
    }

    private func start() {
        guard !reduceMotion else { return }
        let started = Date()
        pieces = ConfettiPiece.burst()
        startDate = started
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(ConfettiPiece.lifetime))
            // A newer burst keeps running.
            if startDate == started {
                startDate = nil
                pieces = []
            }
        }
    }
}

/// One piece of a `ConfettiBurst`: a small rounded rectangle or a dot, thrown from the burst point.
struct ConfettiPiece {
    /// Start, as fractions of the frame's width and height.
    var originX: Double
    var originY: Double
    /// Initial velocity, in points per second.
    var velocityX: Double
    var velocityY: Double
    var color: Color
    var width: Double
    var height: Double
    var isDot: Bool
    /// Rotation speed (radians per second) and the flip speed of the 3D-like wobble.
    var spin: Double
    var flip: Double

    /// How long a burst lasts, in seconds.
    static let lifetime: Double = 2.2
    /// Gravity, in points per second squared.
    static let gravity: Double = 500

    /// The palette's bright fills (docs/DESIGN-V2.md §3) and the icon's warm colors.
    static let colors: [Color] = [
        Color(uiColor: UIColor(rgb: 0xFF5D73)), Color(uiColor: UIColor(rgb: 0xFFB938)),
        Color(uiColor: UIColor(rgb: 0x2CCDBA)), Color(uiColor: UIColor(rgb: 0x4B3BE6)),
        Color(uiColor: UIColor(rgb: 0x7C3AED)), Color(uiColor: UIColor(rgb: 0xFF9F2E)),
        Color(uiColor: UIColor(rgb: 0xBE185D)), Color(uiColor: UIColor(rgb: 0x2563EB)),
    ]

    /// A new burst of `count` pieces, thrown upwards in a wide cone.
    static func burst(count: Int = 70) -> [ConfettiPiece] {
        (0..<count).map { _ -> ConfettiPiece in
            let angle = Double.random(in: -Double.pi * 0.85 ... -Double.pi * 0.15)
            let speed = Double.random(in: 380...820)
            let isDot = Double.random(in: 0...1) < 0.25
            let side = Double.random(in: 6...10)
            return ConfettiPiece(
                originX: Double.random(in: 0.42...0.58),
                originY: Double.random(in: 0.3...0.36),
                velocityX: cos(angle) * speed,
                velocityY: sin(angle) * speed,
                color: colors.randomElement() ?? .pink,
                width: side,
                height: isDot ? side : side * 1.6,
                isDot: isDot,
                spin: Double.random(in: -8...8),
                flip: Double.random(in: 4...11)
            )
        }
    }

    func draw(in context: GraphicsContext, size frame: CGSize, elapsed time: Double) {
        // Air drag slows the throw; gravity wins after a few tenths of a second.
        let drag = 1.6
        let damping: Double = (1 - exp(-drag * time)) / drag
        let x: Double = originX * Double(frame.width) + velocityX * damping
        let y: Double = originY * Double(frame.height) + velocityY * damping + 0.5 * Self.gravity * time * time
        guard y < Double(frame.height) + 40 else { return }
        var piece = context
        piece.opacity = min(1, max(0, (Self.lifetime - time) / 0.5))
        piece.translateBy(x: CGFloat(x), y: CGFloat(y))
        piece.rotate(by: .radians(spin * time))
        if !isDot {
            piece.scaleBy(x: CGFloat(max(0.15, abs(cos(flip * time)))), y: 1)
        }
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let path = isDot ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 2)
        piece.fill(path, with: .color(color))
    }
}

/// Starts the app's confetti burst: `celebrate()` after the user completed a task (status → « Terminée »). It checks
/// « Confettis » itself. The default does nothing (previews, the design gallery).
struct CelebrateAction: Sendable {
    let action: @MainActor @Sendable () -> Void

    init(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    @MainActor
    func callAsFunction() {
        action()
    }
}

/// The counter of the app's bursts (`ConfettiBurst(trigger:)`).
@MainActor
@Observable
final class CelebrationCenter {
    private(set) var burst = 0

    func celebrate() {
        burst &+= 1
    }
}

private struct CelebrateKey: EnvironmentKey {
    static let defaultValue = CelebrateAction {}
}

extension EnvironmentValues {
    /// Confetti when the user completes a task (see `CelebrateAction`).
    var celebrate: CelebrateAction {
        get { self[CelebrateKey.self] }
        set { self[CelebrateKey.self] = newValue }
    }
}
