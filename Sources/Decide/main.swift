import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusPopover!
    let model = Decider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "dice", accessibilityLabel: "Decide") {
            DecideView().environmentObject(self.model)
        }
    }
}

// MARK: - Model

enum Mode: String, CaseIterable {
    case coin = "Coin", dice = "Dice", pick = "Pick One"

    var symbol: String {
        switch self {
        case .coin: "circle.lefthalf.filled"
        case .dice: "dice.fill"
        case .pick: "list.bullet"
        }
    }
}

@MainActor
final class Decider: ObservableObject {
    /// Snapshots read throwaway keys, so a README image never shows the owner's own list and never saves demo values.
    static func key(_ name: String) -> String { StatusPopover.isSnapshot ? "snapshotDemo.\(name)" : name }

    @AppStorage(Decider.key("mode")) var mode: Mode = .coin { willSet { objectWillChange.send() } }
    @AppStorage(Decider.key("sides")) var sides = 6 { willSet { objectWillChange.send() } }
    @AppStorage(Decider.key("diceCount")) var diceCount = 2 { willSet { objectWillChange.send() } }
    @AppStorage(Decider.key("choices")) var choicesText = "Pizza\nSushi\nTacos\nRamen" { willSet { objectWillChange.send() } }

    @Published private(set) var heads = true
    @Published private(set) var coinTurns = 0.0
    @Published private(set) var flips = (heads: 0, tails: 0)
    @Published private(set) var dice: [Int] = []
    var clampedCount: Int { max(1, min(6, diceCount)) }

    init() {
        dice = (0..<clampedCount).map { _ in Int.random(in: 1...sides) }
    }
    @Published private(set) var rolling = false
    @Published private(set) var picked: Int?
    @Published private(set) var highlight: Int?

    static let sideOptions = [4, 6, 8, 10, 12, 20]

    var choices: [String] {
        choicesText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func flip() {
        guard !rolling else { return }
        rolling = true
        let result = Bool.random()
        // Whole turns; the face swaps while the coin spins fastest, so the change is never seen.
        withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 1.1)) { coinTurns += 4 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.heads = result }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            self.rolling = false
            if result { self.flips.heads += 1 } else { self.flips.tails += 1 }
        }
    }

    func roll() {
        guard !rolling else { return }
        rolling = true
        let count = clampedCount, sides = self.sides
        Task {
            // Tumble through random faces, slowing down, then settle.
            for step in 0..<12 {
                dice = (0..<count).map { _ in Int.random(in: 1...sides) }
                try? await Task.sleep(nanoseconds: UInt64(40_000_000 + step * step * 1_800_000))
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                dice = (0..<count).map { _ in Int.random(in: 1...sides) }
            }
            rolling = false
            // The count or the die changed mid-roll: roll again so the dice match the controls.
            if count != clampedCount || sides != self.sides { roll() }
        }
    }

    func pick() {
        let items = choices
        guard !rolling, items.count > 1 else { return }
        rolling = true
        picked = nil
        let winner = Int.random(in: 0..<items.count)
        // Walk the highlight around the list a couple of times, slowing into the winner.
        let steps = items.count * 2 + winner + 1
        Task {
            for step in 0..<steps {
                withAnimation(.easeOut(duration: 0.08)) { highlight = step % items.count }
                let progress = Double(step) / Double(steps)
                try? await Task.sleep(nanoseconds: UInt64((0.05 + progress * progress * 0.25) * 1_000_000_000))
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { picked = winner }
            rolling = false
        }
    }

    func clearPick() { picked = nil; highlight = nil }
}

extension Color {
    static let decide = [Color(red: 0.2, green: 0.78, blue: 0.5), Color(red: 0.03, green: 0.45, blue: 0.3)]
}

// MARK: - Views

struct DecideView: View {
    @EnvironmentObject var model: Decider
    @Namespace private var namespace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(.snappy) { model.mode = mode }
                    } label: {
                        Label(mode.rawValue, systemImage: mode.symbol)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(model.mode == mode ? .white : .secondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background {
                                if model.mode == mode {
                                    Capsule().fill(LinearGradient(colors: Color.decide, startPoint: .top, endPoint: .bottom))
                                        .matchedGeometryEffect(id: "pill", in: namespace)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
            .padding(.top, 14)

            Group {
                switch model.mode {
                case .coin: CoinPane()
                case .dice: DicePane()
                case .pick: PickPane()
                }
            }
            .frame(height: 330)
            .transition(.opacity)

            Divider().opacity(0.5)
            PanelFooter(name: "Decide") {
                Button("Coin") { model.mode = .coin }
                Button("Dice") { model.mode = .dice }
                Button("Pick One") { model.mode = .pick }
            }
        }
        .frame(width: 340)
    }
}

struct CoinPane: View {
    @EnvironmentObject var model: Decider

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: model.heads
                                         ? [Color(red: 1, green: 0.86, blue: 0.4), Color(red: 0.86, green: 0.6, blue: 0.1)]
                                         : [Color(red: 0.86, green: 0.88, blue: 0.92), Color(red: 0.55, green: 0.58, blue: 0.65)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle().strokeBorder(.white.opacity(0.45), lineWidth: 5).padding(8)
                Image(systemName: model.heads ? "crown.fill" : "leaf.fill")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            .frame(width: 140, height: 140)
            .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
            .rotation3DEffect(.degrees(model.coinTurns * 360), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
            .onTapGesture { model.flip() }
            Text(model.rolling ? "..." : (model.heads ? "Heads" : "Tails"))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .contentTransition(.opacity)
            Button("Flip") { model.flip() }
                .buttonStyle(PillButtonStyle(Color.decide))
                .keyboardShortcut(.space, modifiers: [])
            Text("Heads \(model.flips.heads)  ·  Tails \(model.flips.tails)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
        }
    }
}

struct DicePane: View {
    @EnvironmentObject var model: Decider

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Picker("", selection: $model.sides) {
                    ForEach(Decider.sideOptions, id: \.self) { Text("d\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                Stepper("\(model.diceCount)×", value: $model.diceCount, in: 1...6)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .padding(.top, 16)
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                ForEach(Array(stride(from: 0, to: model.dice.count, by: 3)), id: \.self) { start in
                    HStack(spacing: 12) {
                        ForEach(start..<min(start + 3, model.dice.count), id: \.self) { i in
                            let value = model.dice[i]
                            Die(value: value, sides: model.sides)
                                .rotationEffect(.degrees(model.rolling ? Double((value * 37 + i * 53) % 40) - 20 : 0))
                                .offset(y: model.rolling ? CGFloat((value + i) % 3) * -4 : 0)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text(model.dice.count > 1 ? "Total \(model.dice.reduce(0, +))" : " ")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Button("Roll") { model.roll() }
                .buttonStyle(PillButtonStyle(Color.decide))
                .keyboardShortcut(.space, modifiers: [])
                .padding(.bottom, 18)
        }
        .onChange(of: model.diceCount) { _, _ in model.roll() }
        .onChange(of: model.sides) { _, _ in model.roll() }
    }
}

struct Die: View {
    let value: Int
    let sides: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.22), radius: 5, y: 3)
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.black.opacity(0.08))
            if sides == 6 {
                Pips(value: value)
            } else {
                Text("\(value)")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.decide[1])
                    .contentTransition(.numericText())
            }
        }
        .frame(width: 74, height: 74)
    }
}

/// The classic pip layout of a six-sided die, on a 3 by 3 grid.
struct Pips: View {
    let value: Int

    private var spots: [(Int, Int)] {
        switch value {
        case 1: [(1, 1)]
        case 2: [(0, 0), (2, 2)]
        case 3: [(0, 0), (1, 1), (2, 2)]
        case 4: [(0, 0), (2, 0), (0, 2), (2, 2)]
        case 5: [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)]
        default: [(0, 0), (2, 0), (0, 1), (2, 1), (0, 2), (2, 2)]
        }
    }

    var body: some View {
        ZStack {
            ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
                Circle()
                    .fill(Color.decide[1])
                    .frame(width: 13, height: 13)
                    .offset(x: CGFloat(spot.0 - 1) * 19, y: CGFloat(spot.1 - 1) * 19)
            }
        }
    }
}

struct PickPane: View {
    @EnvironmentObject var model: Decider
    @State private var editing = false

    var body: some View {
        VStack(spacing: 10) {
            let items = model.choices
            HStack {
                Text(items.count < 2 ? "Add at least two options" : "\(items.count) options")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button(editing ? "Done" : "Edit List") { withAnimation(.snappy) { editing = !editing || model.choices.count < 2; model.clearPick() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.decide[1])
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            if editing {
                TextEditor(text: $model.choicesText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
                    .padding(.horizontal, 14)
                    .overlay(alignment: .bottomTrailing) {
                        Text("One option per line").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.trailing, 24).padding(.bottom, 8)
                    }
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            ChoiceRow(text: item, lit: (model.picked ?? model.highlight) == i, won: model.picked == i)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }

            Button(model.picked == nil ? "Pick One" : "Pick Again") { editing = false; model.pick() }
                .buttonStyle(PillButtonStyle(Color.decide))
                // Space must reach the editor while the list is being typed.
                .keyboardShortcut(editing ? nil : KeyboardShortcut(.space, modifiers: []))
                .disabled(items.count < 2)
                .padding(.bottom, 16)
        }
        // Too few options: open the editor and keep it open while the second one is typed.
        .onAppear { if model.choices.count < 2 { editing = true } }
    }
}

struct ChoiceRow: View {
    let text: String
    let lit: Bool
    let won: Bool

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: won ? 15 : 13, weight: won ? .bold : .medium, design: .rounded))
                .foregroundStyle(lit ? .white : .primary)
            Spacer()
            if won { Image(systemName: "sparkles").foregroundStyle(.white).transition(.scale.combined(with: .opacity)) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, won ? 10 : 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(lit ? AnyShapeStyle(LinearGradient(colors: Color.decide, startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(.quaternary.opacity(0.3))))
        .scaleEffect(won ? 1.03 : 1)
    }
}

// MARK: - Icon

//: a pair of dice tumbling on green felt

func appIcon() -> NSBitmapImageRep {
    render(0x34D38A, 0x0A5E3E) { ctx in
        radial([NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)],
               center: CGPoint(x: 512, y: 600), radius: 420, in: ctx)
        func die(at c: CGPoint, size s: CGFloat, angle: CGFloat, pips: [(CGFloat, CGFloat)]) {
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: angle * .pi / 180)
            let rect = CGRect(x: -s / 2, y: -s / 2, width: s, height: s)
            ctx.saveGState()
            shadow(ctx, y: -20, blur: 34, alpha: 0.38)
            ctx.addPath(roundedRect(rect, s * 0.2))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(roundedRect(rect, s * 0.2))
            ctx.clip()
            gradient([rgb(0xFFFFFF), rgb(0xE3E8E5)], from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY), in: ctx)
            ctx.restoreGState()
            let r = s * 0.085
            for (px, py) in pips {
                let p = CGPoint(x: px * s * 0.27, y: py * s * 0.27)
                ctx.setFillColor(rgb(0x0E5A3C).cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
            ctx.restoreGState()
        }
        // A five behind, a three in front.
        die(at: CGPoint(x: 640, y: 630), size: 300, angle: 16, pips: [(-1, 1), (1, 1), (0, 0), (-1, -1), (1, -1)])
        die(at: CGPoint(x: 400, y: 400), size: 340, angle: -12, pips: [(-1, 1), (0, 0), (1, -1)])
    }
}
