import AppKit
import Kit
import SwiftUI

enum Theme {
    static let accent = [Color(hex: 0x2EE6E6), Color(hex: 0x1496B8)]
    static let ink = Color(hex: 0x1C1C1E)
    static let ancient = Color(hex: 0xE2B86B)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// How an element is painted in the current colour mode.
struct Paint {
    let fill: Color
    let solid: Bool // A full-strength colour (heatmaps) rather than a tint over the window.
    let darkText: Bool
    let missing: Bool

    static func of(_ e: Element, mode: ColorMode) -> Paint {
        switch mode {
        case .category: return Paint(fill: Color(hex: e.category.hex), solid: false, darkText: true, missing: false)
        case .state: return Paint(fill: Color(hex: e.phase.hex), solid: false, darkText: true, missing: e.phase == .unknown)
        case .discovery where e.year == nil:
            return Paint(fill: Theme.ancient, solid: true, darkText: true, missing: false)
        default:
            guard let v = mode.value(e) else { return Paint(fill: .gray, solid: false, darkText: true, missing: true) }
            let r = mode.range
            let t = (v - r.lowerBound) / (r.upperBound - r.lowerBound)
            return Paint(fill: Heat.color(t), solid: true, darkText: !Heat.isDark(t), missing: false)
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: TableModel
    @FocusState private var tableFocused: Bool
    @State private var findTrigger = 0

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                TableGrid(model: model, size: geo.size) { tableFocused = true }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            LegendBar(model: model)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 940, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($tableFocused)
        .onKeyPress(.leftArrow) { model.move(dr: 0, dc: -1); return .handled }
        .onKeyPress(.rightArrow) { model.move(dr: 0, dc: 1); return .handled }
        .onKeyPress(.upArrow) { model.move(dr: -1, dc: 0); return .handled }
        .onKeyPress(.downArrow) { model.move(dr: 1, dc: 0); return .handled }
        .onAppear { tableFocused = true }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search elements")
        .modifier(SearchFocus(trigger: findTrigger))
        .onSubmit(of: .search) {
            model.selectFirstResult()
        }
        .onReceive(NotificationCenter.default.publisher(for: .findElement)) { _ in findTrigger += 1 }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Colour By", selection: $model.mode) {
                    ForEach(ColorMode.allCases) { Text($0.short).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Colour the table by a property")
            }
            ToolbarItem {
                Button { model.copySelected() } label: { Label("Copy Details", systemImage: "doc.on.doc") }
                    .help("Copy the selected element's details (⇧⌘C)")
            }
        }
        .navigationTitle("Elements")
    }
}

extension Notification.Name {
    static let findElement = Notification.Name("ElementsFindElement")
}

/// Focuses the toolbar search field when `trigger` changes (macOS 15 and later).
struct SearchFocus: ViewModifier {
    let trigger: Int
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.searchFocused($focused).onChange(of: trigger) { _, _ in focused = true }
        } else {
            content
        }
    }
}

// MARK: - Grid

struct GridMetrics {
    let cellW: CGFloat
    let cellH: CGFloat
    let spacing: CGFloat
    let labelW: CGFloat = 16
    let labelH: CGFloat = 16
    let fGap: CGFloat
    let originX: CGFloat

    init(size: CGSize) {
        spacing = size.width > 1000 ? 4 : 3
        let w = (size.width - labelW - 17 * spacing) / 18
        let h = (size.height - labelH - 8 * spacing) / 9.32
        cellW = min(w, h * 1.12)
        cellH = min(h, cellW * 1.15)
        fGap = cellH * 0.32
        let total = labelW + 18 * cellW + 17 * spacing
        originX = max(0, (size.width - total) / 2)
    }

    func x(_ column: Int) -> CGFloat { originX + labelW + CGFloat(column - 1) * (cellW + spacing) }

    func y(_ row: Int) -> CGFloat {
        if row <= 7 { return labelH + CGFloat(row - 1) * (cellH + spacing) }
        return labelH + 7 * (cellH + spacing) + fGap + CGFloat(row - 9) * (cellH + spacing)
    }

    var height: CGFloat { y(10) + cellH }
}

struct TableGrid: View {
    @ObservedObject var model: TableModel
    let size: CGSize
    let onSelect: () -> Void

    var body: some View {
        let m = GridMetrics(size: size)
        ZStack(alignment: .topLeading) {
            // Group numbers over the columns, period numbers beside the rows.
            ForEach(1...18, id: \.self) { c in
                Text("\(c)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                    .frame(width: m.cellW, height: m.labelH)
                    .offset(x: m.x(c), y: 0)
            }
            ForEach(1...7, id: \.self) { r in
                Text("\(r)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                    .frame(width: m.labelW, height: m.cellH)
                    .offset(x: m.originX - 2, y: m.y(r))
            }

            DetailPanel(model: model, element: model.current)
                .frame(width: m.x(12) + m.cellW - m.x(3), height: m.y(3) + m.cellH - m.y(1))
                .offset(x: m.x(3), y: m.y(1))

            ForEach(PeriodicTable.elements) { e in
                ElementTile(element: e, mode: model.mode, width: m.cellW, height: m.cellH,
                            isSelected: e.number == model.selected, isLit: model.isLit(e))
                    .offset(x: m.x(e.column), y: m.y(e.row))
                    .zIndex(e.number == model.selected ? 2 : 0)
                    .onHover { inside in
                        guard !Desktop.isSnapshot else { return }
                        if inside { model.hovered = e.number } else if model.hovered == e.number { model.hovered = nil }
                    }
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.2)) { model.selected = e.number }
                        onSelect()
                    }
            }

            SeriesPlaceholder(text: "57-71", category: .lanthanide, mode: model.mode, width: m.cellW, height: m.cellH)
                .offset(x: m.x(3), y: m.y(6))
            SeriesPlaceholder(text: "89-103", category: .actinide, mode: model.mode, width: m.cellW, height: m.cellH)
                .offset(x: m.x(3), y: m.y(7))
        }
        .offset(y: max(0, (size.height - m.height) / 2))
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.snappy(duration: 0.25), value: model.mode)
    }
}

struct ElementTile: View {
    let element: Element
    let mode: ColorMode
    let width: CGFloat
    let height: CGFloat
    let isSelected: Bool
    let isLit: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let paint = Paint.of(element, mode: mode)
        let ink: Color = paint.solid ? (paint.darkText ? Theme.ink : .white) : .primary
        let shape = RoundedRectangle(cornerRadius: max(4, width * 0.11), style: .continuous)
        VStack(spacing: 0) {
            HStack {
                Text("\(element.number)").font(.system(size: max(8, width * 0.17), weight: .medium, design: .rounded))
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .opacity(0.75)
            Spacer(minLength: 0)
            Text(element.symbol).font(.system(size: width * 0.36, weight: .bold, design: .rounded))
            Spacer(minLength: 0)
            Text(mode.caption(element)).font(.system(size: max(7.5, width * 0.15), weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.6)
                .opacity(0.8)
        }
        .foregroundStyle(paint.missing && !paint.solid ? AnyShapeStyle(.secondary) : AnyShapeStyle(ink))
        .padding(.horizontal, width * 0.08)
        .padding(.vertical, height * 0.06)
        .frame(width: width, height: height)
        .background {
            if paint.missing {
                shape.fill(.quaternary.opacity(0.5))
            } else if paint.solid {
                shape.fill(paint.fill.gradient)
            } else {
                shape.fill(paint.fill.opacity(scheme == .dark ? 0.5 : 0.42))
            }
        }
        .overlay {
            shape.strokeBorder(paint.missing ? Color.secondary.opacity(0.25) : paint.fill.opacity(paint.solid ? 0 : 0.7),
                               lineWidth: 0.75)
        }
        .overlay {
            if isSelected {
                shape.strokeBorder(LinearGradient(colors: Theme.accent, startPoint: .top, endPoint: .bottom), lineWidth: 2.5)
                    .padding(-2.5)
            } else if hovering {
                shape.strokeBorder(Color.primary.opacity(0.45), lineWidth: 1.5)
            }
        }
        .scaleEffect(isSelected ? 1.08 : (hovering ? 1.04 : 1))
        .shadow(color: .black.opacity(isSelected ? 0.25 : 0), radius: 6, y: 2)
        .opacity(isLit ? 1 : 0.18)
        .contentShape(shape)
        .onHover { hovering = $0 && !Desktop.isSnapshot }
        .animation(.snappy(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.2), value: isLit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(element.name), \(element.number)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct SeriesPlaceholder: View {
    let text: String
    let category: Category
    let mode: ColorMode
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let color = mode == .category ? Color(hex: category.hex) : Color.secondary
        RoundedRectangle(cornerRadius: max(4, width * 0.11), style: .continuous)
            .strokeBorder(color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
            .background(RoundedRectangle(cornerRadius: max(4, width * 0.11), style: .continuous).fill(color.opacity(0.12)))
            .overlay {
                Text(text).font(.system(size: max(8, width * 0.17), weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(width: width, height: height)
    }
}

// MARK: - Detail

struct DetailPanel: View {
    @ObservedObject var model: TableModel
    let element: Element

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            HStack(alignment: .top, spacing: 16) {
                BigTile(element: element, mode: model.mode)
                    .frame(width: min(h, geo.size.width * 0.3), height: h)
                VStack(alignment: .leading, spacing: h > 190 ? 10 : 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(element.name).font(.system(size: h > 190 ? 26 : 22, weight: .bold, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        CategoryChip(category: element.category)
                        Spacer(minLength: 0)
                    }
                    Text(placement).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: h > 190 ? 10 : 6) {
                        GridRow {
                            Fact(label: "Atomic mass", value: element.massText, note: element.massNote)
                            Fact(label: "Electronegativity", value: element.electronegativity.map { Format.number($0, minDecimals: 2, maxDecimals: 2) },
                                 note: element.electronegativity == nil ? nil : "Pauling")
                            Fact(label: "Density", value: element.densityText, note: nil)
                        }
                        GridRow {
                            Fact(label: element.sublimes ? "Sublimes at" : "Melting point",
                                 value: element.melting.map(Format.celsius), note: element.melting.map(Format.kelvin))
                            Fact(label: "Boiling point", value: element.boiling.map(Format.celsius), note: element.boiling.map(Format.kelvin))
                            Fact(label: "Discovered", value: element.yearText, note: nil)
                        }
                        GridRow {
                            Fact(label: "Electron configuration", value: element.configurationText,
                                 note: element.number >= 104 ? "predicted" : nil)
                                .gridCellColumns(2)
                            Fact(label: "State at 20 °C", value: element.phase.title, note: nil)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .animation(.snappy(duration: 0.18), value: element.number)
    }

    var placement: String {
        if let group = element.group { return "Group \(group), period \(element.period), \(element.block)-block" }
        return "\(element.category == .lanthanide ? "Lanthanide" : "Actinide") series, period \(element.period), f-block"
    }
}

struct Fact: View {
    let label: String
    let value: String?
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "Unknown").font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? .tertiary : .primary)
                    .contentTransition(.numericText())
                if let note, value != nil {
                    Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CategoryChip: View {
    let category: Category

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color(hex: category.hex)).frame(width: 7, height: 7)
            Text(category.title).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(hex: category.hex).opacity(0.2)))
        .fixedSize()
    }
}

struct BigTile: View {
    let element: Element
    let mode: ColorMode

    var body: some View {
        let paint = Paint.of(element, mode: mode)
        let base = paint.missing ? Color.gray : paint.fill
        let ink: Color = paint.missing || paint.darkText ? Theme.ink : .white
        GeometryReader { geo in
            let s = geo.size.height
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(element.number)").font(.system(size: s * 0.12, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Spacer()
                    Text(element.massText).font(.system(size: s * 0.075, weight: .medium, design: .rounded))
                        .opacity(0.75)
                }
                Spacer(minLength: 0)
                Text(element.symbol).font(.system(size: s * 0.4, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 0)
                Text(element.name).font(.system(size: s * 0.085, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .monospacedDigit()
            .foregroundStyle(ink)
            .padding(s * 0.08)
            .frame(width: geo.size.width, height: s)
            .background {
                RoundedRectangle(cornerRadius: s * 0.1, style: .continuous)
                    .fill(LinearGradient(colors: [base.opacity(paint.missing ? 0.35 : 0.85), base], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: s * 0.1, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0)], startPoint: .top, endPoint: .center))
                    )
                    .shadow(color: base.opacity(0.4), radius: 8, y: 3)
            }
        }
    }
}

// MARK: - Legend

struct LegendBar: View {
    @ObservedObject var model: TableModel

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch model.mode {
                case .category:
                    HStack(spacing: 4) {
                        ForEach(Category.allCases) { c in
                            LegendChip(color: Color(hex: c.hex), title: c.short, isOn: model.highlightedCategory == c) {
                                model.highlightedCategory = $0 ? c : (model.highlightedCategory == c ? nil : model.highlightedCategory)
                            }
                        }
                    }
                case .state:
                    HStack(spacing: 4) {
                        ForEach(Phase.allCases) { p in
                            LegendChip(color: Color(hex: p.hex), title: p.title, isOn: model.highlightedPhase == p) {
                                model.highlightedPhase = $0 ? p : (model.highlightedPhase == p ? nil : model.highlightedPhase)
                            }
                        }
                    }
                default:
                    HeatLegend(mode: model.mode)
                }
            }
            Spacer(minLength: 8)
            searchStatus
        }
        .frame(height: 26)
        .animation(.snappy(duration: 0.2), value: model.mode)
    }

    @ViewBuilder var searchStatus: some View {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let results = model.results
            Text(results.isEmpty ? "No element matches \u{201C}\(q)\u{201D}"
                 : "\(results.count) \(results.count == 1 ? "match" : "matches"), Return selects \(results[0].name)")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

struct LegendChip: View {
    let color: Color
    let title: String
    let isOn: Bool
    let hover: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 10, height: 10)
            Text(title).font(.system(size: 11.5, weight: .medium)).fixedSize()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(hovering ? 0.8 : 0)))
        .onHover { inside in
            hovering = inside
            hover(inside)
        }
        .help("Hover to highlight")
    }
}

struct HeatLegend: View {
    let mode: ColorMode

    var body: some View {
        let r = mode.range
        HStack(spacing: 10) {
            Text(mode.title).font(.system(size: 11.5, weight: .semibold))
            Text(label(r.lowerBound)).font(.system(size: 11.5, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            Capsule()
                .fill(LinearGradient(colors: Heat.stops.map { Color(hex: $0) }, startPoint: .leading, endPoint: .trailing))
                .frame(width: 240, height: 10)
                .overlay(Capsule().strokeBorder(.black.opacity(0.08)))
            Text(label(r.upperBound)).font(.system(size: 11.5, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            if mode == .discovery {
                LegendSwatch(color: Theme.ancient, title: "Ancient")
            } else if mode == .electronegativity {
                LegendSwatch(color: Color.gray.opacity(0.25), title: "No value")
            }
        }
    }

    func label(_ v: Double) -> String {
        switch mode {
        case .electronegativity: Format.number(v, minDecimals: 2, maxDecimals: 2)
        case .mass: Format.number(v, maxDecimals: 1) + " u"
        default: v == mode.range.lowerBound ? "\(Int(v)) or earlier" : String(Int(v))
        }
    }
}

struct LegendSwatch: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(width: 10, height: 10)
            Text(title).font(.system(size: 11.5, weight: .medium))
        }
        .padding(.leading, 6)
    }
}
