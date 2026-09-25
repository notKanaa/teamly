import SwiftUI

/// Lays its subviews out in lines, left to right, starting a new line when the next one does not fit (the chips of a
/// task row, of a « Ta journée » card). The items of a line are centered vertically. An item wider than the whole width
/// is proposed that width (its text wraps). Survives the largest Dynamic Type sizes: nothing is cut.
///
/// ```swift
/// FlowLayout(spacing: 10, lineSpacing: 6) {
///     Chip("🏠 Coloc’", tone: ColorKey.coral.tone)
///     Chip("20:00", systemImage: "clock", tone: .ink(Theme.textSecondary), style: .plain)
/// }
/// ```
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    init(spacing: CGFloat = 8, lineSpacing: CGFloat = 6) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = arrange(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Item {
        var index: Int
        var size: CGSize
    }

    private struct Line {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width proposedWidth: CGFloat?, subviews: Subviews) -> [Line] {
        let maxWidth = proposedWidth ?? .infinity
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            if !line.items.isEmpty && line.width + spacing + size.width > maxWidth {
                lines.append(line)
                line = Line()
            }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append(Item(index: index, size: size))
        }
        if !line.items.isEmpty {
            lines.append(line)
        }
        return lines
    }
}
