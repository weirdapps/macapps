import SwiftUI

// The deck is drawn here from scratch: suit outlines, pip layouts, court panels and the back.

enum SuitPath {
    /// The suit's outline in `rect`. Drawn in a unit square with y down; `flipped` maps it into a y-up context (the icon).
    static func cgPath(_ suit: Suit, in rect: CGRect, flipped: Bool = false) -> CGPath {
        let path = CGMutablePath()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: flipped ? rect.maxY - y * rect.height : rect.minY + y * rect.height)
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: rect.minX + (x - r) * rect.width,
                                       y: flipped ? rect.maxY - (y + r) * rect.height : rect.minY + (y - r) * rect.height,
                                       width: 2 * r * rect.width, height: 2 * r * rect.height))
        }
        func stem(top: CGFloat) {
            path.move(to: p(0.46, top))
            path.addQuadCurve(to: p(0.27, 1.0), control: p(0.45, 0.9))
            path.addLine(to: p(0.73, 1.0))
            path.addQuadCurve(to: p(0.54, top), control: p(0.55, 0.9))
            path.closeSubpath()
        }
        switch suit {
        case .hearts:
            path.move(to: p(0.5, 0.97))
            path.addCurve(to: p(0.0, 0.33), control1: p(0.3, 0.8), control2: p(0.0, 0.6))
            path.addCurve(to: p(0.5, 0.2), control1: p(0.0, 0.02), control2: p(0.42, -0.02))
            path.addCurve(to: p(1.0, 0.33), control1: p(0.58, -0.02), control2: p(1.0, 0.02))
            path.addCurve(to: p(0.5, 0.97), control1: p(1.0, 0.6), control2: p(0.7, 0.8))
            path.closeSubpath()
        case .diamonds:
            path.move(to: p(0.5, 0.0))
            path.addQuadCurve(to: p(0.9, 0.5), control: p(0.68, 0.28))
            path.addQuadCurve(to: p(0.5, 1.0), control: p(0.68, 0.72))
            path.addQuadCurve(to: p(0.1, 0.5), control: p(0.32, 0.72))
            path.addQuadCurve(to: p(0.5, 0.0), control: p(0.32, 0.28))
            path.closeSubpath()
        case .spades:
            path.move(to: p(0.5, 0.0))
            path.addCurve(to: p(0.0, 0.56), control1: p(0.32, 0.22), control2: p(0.0, 0.34))
            path.addCurve(to: p(0.5, 0.66), control1: p(0.0, 0.84), control2: p(0.36, 0.86))
            path.addCurve(to: p(1.0, 0.56), control1: p(0.64, 0.86), control2: p(1.0, 0.84))
            path.addCurve(to: p(0.5, 0.0), control1: p(1.0, 0.34), control2: p(0.68, 0.22))
            path.closeSubpath()
            stem(top: 0.6)
        case .clubs:
            circle(0.5, 0.25, 0.22)
            circle(0.25, 0.56, 0.22)
            circle(0.75, 0.56, 0.22)
            circle(0.5, 0.5, 0.14)
            stem(top: 0.55)
        }
        return path
    }
}

struct SuitShape: Shape {
    let suit: Suit
    func path(in rect: CGRect) -> Path { Path(SuitPath.cgPath(suit, in: rect)) }
}

enum Ink {
    static let red = Color(hex: 0xC6283B)
    static let black = Color(hex: 0x1D2229)
    static let gold = Color(hex: 0xD6A13A)
    static let paper = LinearGradient(colors: [Color(hex: 0xFFFFFF), Color(hex: 0xF4F1EA)], startPoint: .top, endPoint: .bottom)

    static func color(_ card: Card) -> Color { card.isRed ? red : black }
}

/// The face of a card, laid out in proportion to its width.
struct CardFace: View {
    let card: Card
    let width: CGFloat

    private var height: CGFloat { width * 1.4 }
    private var ink: Color { Ink.color(card) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.08, style: .continuous).fill(Ink.paper)
            centre
            index.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            index.rotationEffect(.degrees(180)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .overlay {
            RoundedRectangle(cornerRadius: width * 0.08, style: .continuous).strokeBorder(.black.opacity(0.16), lineWidth: 0.6)
        }
        .frame(width: width, height: height)
    }

    private var index: some View {
        VStack(spacing: width * 0.012) {
            Text(card.rankLabel)
                .font(.system(size: width * 0.19, weight: .bold, design: .rounded))
                .kerning(card.rank == 10 ? -width * 0.012 : 0)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            SuitShape(suit: card.suit).frame(width: width * 0.12, height: width * 0.12)
        }
        .foregroundStyle(ink)
        .frame(width: width * 0.2)
        .padding(.vertical, width * 0.05)
        .padding(.horizontal, width * 0.025)
    }

    @ViewBuilder private var centre: some View {
        switch card.rank {
        case 1:
            ZStack {
                if card.suit == .spades {
                    Circle().strokeBorder(ink.opacity(0.18), lineWidth: width * 0.02).frame(width: width * 0.62)
                }
                SuitShape(suit: card.suit).fill(ink).frame(width: width * 0.4, height: width * 0.4)
            }
        case 11...13:
            CourtPanel(card: card, width: width)
        default:
            pips
        }
    }

    private var pips: some View {
        let area = CGRect(x: width * 0.33, y: height * 0.17, width: width * 0.34, height: height * 0.66)
        let size = width * 0.17
        return ZStack {
            ForEach(Array(CardFace.pipLayout(card.rank).enumerated()), id: \.offset) { _, pip in
                SuitShape(suit: card.suit)
                    .fill(ink)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(pip.y > 0.5 ? 180 : 0))
                    .position(x: area.minX + pip.x * area.width, y: area.minY + pip.y * area.height)
            }
        }
        .frame(width: width, height: height)
    }

    /// Pip centres for two to ten, in a unit rect: three columns, top to bottom.
    static func pipLayout(_ rank: Int) -> [CGPoint] {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
        let sides = [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)]
        let thirds = [CGPoint(x: 0, y: 1.0 / 3), CGPoint(x: 1, y: 1.0 / 3), CGPoint(x: 0, y: 2.0 / 3), CGPoint(x: 1, y: 2.0 / 3)]
        switch rank {
        case 2: return [CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)]
        case 3: return [CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 1)]
        case 4: return corners
        case 5: return corners + [CGPoint(x: 0.5, y: 0.5)]
        case 6: return corners + sides
        case 7: return corners + sides + [CGPoint(x: 0.5, y: 0.25)]
        case 8: return corners + sides + [CGPoint(x: 0.5, y: 0.25), CGPoint(x: 0.5, y: 0.75)]
        case 9: return corners + thirds + [CGPoint(x: 0.5, y: 0.5)]
        case 10: return corners + thirds + [CGPoint(x: 0.5, y: 1.0 / 6), CGPoint(x: 0.5, y: 5.0 / 6)]
        default: return []
        }
    }
}

/// Jack, queen and king: a framed panel with a crown, the letter and the suit, mirrored like a court card.
struct CourtPanel: View {
    let card: Card
    let width: CGFloat

    var body: some View {
        let ink = Ink.color(card)
        let panel = CGSize(width: width * 0.6, height: width * 1.4 * 0.66)
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.05, style: .continuous)
                .fill(LinearGradient(colors: [ink.opacity(0.10), ink.opacity(0.04)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: width * 0.05, style: .continuous)
                .strokeBorder(ink.opacity(0.55), lineWidth: max(1, width * 0.012))
            RoundedRectangle(cornerRadius: width * 0.035, style: .continuous)
                .strokeBorder(Ink.gold.opacity(0.7), lineWidth: max(0.6, width * 0.008))
                .padding(width * 0.03)
            half(ink: ink, panel: panel)
            half(ink: ink, panel: panel).rotationEffect(.degrees(180))
            Text(card.rankLabel)
                .font(.system(size: width * 0.3, weight: .heavy, design: .serif))
                .foregroundStyle(ink)
        }
        .frame(width: panel.width, height: panel.height)
    }

    private func half(ink: Color, panel: CGSize) -> some View {
        VStack(spacing: width * 0.03) {
            Crown(rank: card.rank)
                .fill(LinearGradient(colors: [Ink.gold, Color(hex: 0xB07A1E)], startPoint: .top, endPoint: .bottom))
                .frame(width: width * 0.3, height: width * 0.15)
            SuitShape(suit: card.suit).fill(ink).frame(width: width * 0.11, height: width * 0.11)
        }
        .padding(.top, width * 0.07)
        .frame(width: panel.width, height: panel.height, alignment: .top)
    }
}

/// A different headpiece for each court rank: three points for the king, a five-point coronet for the queen, a cap for the jack.
struct Crown: Shape {
    let rank: Int

    func path(in r: CGRect) -> Path {
        var path = Path()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        switch rank {
        case 13:
            path.move(to: p(0.05, 1))
            path.addLine(to: p(0.0, 0.25))
            path.addLine(to: p(0.28, 0.55))
            path.addLine(to: p(0.5, 0.0))
            path.addLine(to: p(0.72, 0.55))
            path.addLine(to: p(1.0, 0.25))
            path.addLine(to: p(0.95, 1))
            path.closeSubpath()
        case 12:
            path.move(to: p(0.08, 1))
            for (i, x) in [0.0, 0.25, 0.5, 0.75, 1.0].enumerated() {
                path.addLine(to: p(x, i % 2 == 0 ? 0.35 : 0.5))
                if i < 4 { path.addQuadCurve(to: p(x + 0.25, i % 2 == 0 ? 0.5 : 0.35), control: p(x + 0.125, 0.75)) }
            }
            path.addLine(to: p(0.92, 1))
            path.closeSubpath()
            for x in [0.0, 0.5, 1.0] { path.addEllipse(in: CGRect(x: r.minX + x * r.width - r.height * 0.13, y: r.minY + r.height * 0.08,
                                                                 width: r.height * 0.26, height: r.height * 0.26)) }
        default:
            path.move(to: p(0.15, 1))
            path.addQuadCurve(to: p(0.5, 0.15), control: p(0.12, 0.2))
            path.addQuadCurve(to: p(0.85, 1), control: p(0.88, 0.2))
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: r.midX - r.height * 0.15, y: r.minY, width: r.height * 0.3, height: r.height * 0.3))
        }
        return path
    }
}

/// The back of every card: an indigo field with a lattice, an inner frame and a small four-point star.
struct CardBack: View {
    let width: CGFloat

    var body: some View {
        let radius = width * 0.08
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white)
            RoundedRectangle(cornerRadius: radius * 0.7, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x4555B0), Color(hex: 0x252E72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Lattice(step: width * 0.11)
                        .stroke(.white.opacity(0.16), lineWidth: max(0.6, width * 0.01))
                        .clipShape(RoundedRectangle(cornerRadius: radius * 0.7, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: radius * 0.45, style: .continuous)
                        .strokeBorder(.white.opacity(0.45), lineWidth: max(0.6, width * 0.012))
                        .padding(width * 0.06)
                }
                .overlay {
                    Star().fill(.white.opacity(0.85)).frame(width: width * 0.22, height: width * 0.22)
                        .shadow(color: .black.opacity(0.25), radius: 2)
                }
                .padding(width * 0.045)
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.black.opacity(0.18), lineWidth: 0.6)
        }
        .frame(width: width, height: width * 1.4)
    }
}

struct Lattice: Shape {
    let step: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
            path.move(to: CGPoint(x: x + rect.height, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += step
        }
        return path
    }
}

struct Star: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: r.midX, y: r.midY), s = r.width / 2, k = s * 0.14
        path.move(to: CGPoint(x: c.x, y: c.y - s))
        path.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: CGPoint(x: c.x + k, y: c.y + k))
        path.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: CGPoint(x: c.x - k, y: c.y - k))
        return path
    }
}

/// A card that turns over with a quick 3D flip when `faceUp` changes inside an animation.
struct CardView: View, Animatable {
    let card: Card
    let width: CGFloat
    var angle: Double // 0 is face up, 180 face down.

    init(card: Card, faceUp: Bool, width: CGFloat) {
        self.card = card
        self.width = width
        angle = faceUp ? 0 : 180
    }

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        Group {
            if angle < 90 { CardFace(card: card, width: width) } else { CardBack(width: width).scaleEffect(x: -1) }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .accessibilityLabel(angle < 90 ? "\(card.rankLabel) of \(String(describing: card.suit))" : "Face down card")
    }
}
