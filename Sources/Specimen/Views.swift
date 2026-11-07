import AppKit
import Kit
import SwiftUI

enum Theme {
    static let top = Color(red: 0x8E / 255, green: 0x5B / 255, blue: 0xD9 / 255)
    static let bottom = Color(red: 0x4B / 255, green: 0x2A / 255, blue: 0x8C / 255)
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct ContentView: View {
    @ObservedObject var model: FontModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            DetailView(model: model)
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search fonts")
        .modifier(SearchFocus(token: model.focusSearch))
        .frame(minWidth: 760, minHeight: 480)
        .tint(Theme.top)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: FontModel

    var body: some View {
        let visible = model.visibleFamilies
        List(selection: $model.selection) {
            ForEach(visible) { family in
                FamilyRow(family: family, favourite: model.favourites.contains(family.name), pinned: model.pinned.contains(family.name))
                    .tag(family.name)
                    .contextMenu {
                        Button(model.favourites.contains(family.name) ? "Remove from Favourites" : "Add to Favourites") {
                            model.toggleFavourite(family.name)
                        }
                        Button(model.pinned.contains(family.name) ? "Unpin from Comparison" : "Pin for Comparison") {
                            model.togglePin(family.name)
                        }
                        Divider()
                        Button("Copy Font Name") { model.copy(family.name) }
                    }
            }
        }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(model.filter == .favourites && model.search.isEmpty ? "No favourites yet" : "No fonts match",
                          systemImage: model.filter == .favourites ? "star" : "magnifyingglass")
                } description: {
                    Text(model.filter == .favourites && model.search.isEmpty ? "Star a font to keep it here." : "Try another name or filter.")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Picker("Show", selection: $model.filter) {
                    ForEach(FontFilter.allCases) { f in
                        Label(f.title, systemImage: f.symbol).tag(f)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Show all fonts, favourites or one kind")
                Spacer(minLength: 4)
                Text("\(visible.count) \(visible.count == 1 ? "family" : "families")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .animation(.snappy, value: visible.count)
        }
    }
}

struct FamilyRow: View {
    let family: FontFamily
    let favourite: Bool
    let pinned: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(family.name)
                .font(family.canPreviewName ? FontCatalog.familyFont(family.name, size: 14) : .system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            if pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if favourite {
                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct DetailView: View {
    @ObservedObject var model: FontModel

    var body: some View {
        VStack(spacing: 0) {
            if model.mode != .compare, model.selection == nil {
                ContentUnavailableView("Choose a font", systemImage: "textformat",
                                       description: Text("Pick a family in the sidebar to see it set in your own words."))
            } else {
                Header(model: model)
                ControlBar(model: model)
                Divider()
                SampleArea(model: model)
            }
        }
        .frame(minWidth: 480)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar { DetailToolbar(model: model) }
        .navigationTitle("Specimen")
    }
}

struct DetailToolbar: ToolbarContent {
    @ObservedObject var model: FontModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.mode) {
                ForEach(DetailMode.allCases) { m in
                    Label(m.title, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .help("Styles, waterfall, glyphs or comparison")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            let name = model.selection
            Button {
                if let name { model.toggleFavourite(name) }
            } label: {
                Label("Favourite", systemImage: name.map { model.favourites.contains($0) } == true ? "star.fill" : "star")
            }
            .help("Add to favourites (⌘D)")
            .disabled(name == nil)
            Button {
                if let name { model.togglePin(name) }
            } label: {
                Label("Pin", systemImage: name.map { model.pinned.contains($0) } == true ? "pin.fill" : "pin")
            }
            .help("Pin for comparison, up to four (⇧⌘P)")
            .disabled(name == nil)
            Button {
                withAnimation(.snappy) { model.darkSample.toggle() }
            } label: {
                Label("Background", systemImage: model.darkSample ? "sun.max" : "moon")
            }
            .help(model.darkSample ? "Light sample background (⇧⌘D)" : "Dark sample background (⇧⌘D)")
            Button {
                if let name { model.copy(name) }
            } label: {
                Label("Copy Name", systemImage: "doc.on.doc")
            }
            .help("Copy font name (⇧⌘C)")
            .disabled(name == nil)
        }
    }
}

struct Header: View {
    @ObservedObject var model: FontModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if model.mode == .compare {
                Text("Compare")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(model.pinned.isEmpty ? "Pin up to four fonts" : "\(model.pinned.count) of \(FontCatalog.maxPinned) pinned")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if let name = model.selection {
                let family = model.family(named: name)
                Text(name)
                    .font(family?.canPreviewName == true ? FontCatalog.familyFont(name, size: 28) : .system(size: 26, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    let count = model.styles(of: name).count
                    Tag(text: "\(count) \(count == 1 ? "style" : "styles")")
                    if let family {
                        Tag(text: family.category.title)
                        if family.isMonospaced { Tag(text: "Monospaced") }
                    }
                }
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
    }
}

struct ControlBar: View {
    @ObservedObject var model: FontModel

    var body: some View {
        HStack(spacing: 14) {
            if model.mode != .glyphs {
                TextField("Type your sample text", text: $model.sampleText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160)
            }
            if model.mode == .waterfall || model.mode == .glyphs, let name = model.selection {
                let styles = model.styles(of: name)
                if styles.count > 1 {
                    Picker("Style", selection: Binding(get: { model.currentStyle(of: name)?.postScriptName ?? "" },
                                                       set: { model.styleChoice = $0 })) {
                        ForEach(styles) { Text($0.styleName).tag($0.postScriptName) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if model.mode == .glyphs { Spacer() }
            if model.mode != .waterfall {
                HStack(spacing: 8) {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                    Slider(value: $model.size, in: FontCatalog.sizeRange)
                        .frame(width: 150)
                        .help("Sample size")
                    Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    Text("\(Int(model.size)) pt")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }
}

// MARK: - Sample area

struct SampleArea: View {
    @ObservedObject var model: FontModel

    private var ink: Color { model.darkSample ? Color(white: 0.95) : Color(white: 0.08) }
    private var paper: Color { model.darkSample ? Color(white: 0.11) : .white }

    var body: some View {
        Group {
            switch model.mode {
            case .styles: if let name = model.selection { StylesView(model: model, family: name, ink: ink) }
            case .waterfall: if let name = model.selection { WaterfallView(model: model, family: name, ink: ink) }
            case .glyphs: if let name = model.selection { GlyphGrid(model: model, family: name, ink: ink) }
            case .compare: CompareView(model: model, ink: ink)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paper)
        .environment(\.colorScheme, model.darkSample ? .dark : .light)
        .animation(.snappy, value: model.darkSample)
    }
}

struct StyleCaption: View {
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.top)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct StylesView: View {
    @ObservedObject var model: FontModel
    let family: String
    let ink: Color

    var body: some View {
        let styles = model.styles(of: family)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(styles.enumerated()), id: \.element.id) { index, style in
                    VStack(alignment: .leading, spacing: 6) {
                        StyleCaption(title: style.styleName, detail: style.postScriptName)
                        Text(model.effectiveSample)
                            .font(FontCatalog.font(style.postScriptName, size: model.size))
                            .foregroundStyle(ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Copy PostScript Name") { model.copy(style.postScriptName) }
                        Button("Copy Font Name") { model.copy(family) }
                    }
                    if index < styles.count - 1 { Divider().opacity(0.6) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
    }
}

struct WaterfallView: View {
    @ObservedObject var model: FontModel
    let family: String
    let ink: Color

    var body: some View {
        let ps = model.currentStyle(of: family)?.postScriptName ?? family
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(FontCatalog.waterfallSizes, id: \.self) { size in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text("\(Int(size))")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                        Text(model.effectiveSample)
                            .font(FontCatalog.font(ps, size: size))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .clipped()
                            .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                                 startPoint: .leading, endPoint: .trailing))
                    }
                }
            }
            .padding(24)
        }
    }
}

struct GlyphGrid: View {
    @ObservedObject var model: FontModel
    let family: String
    let ink: Color

    var body: some View {
        let style = model.currentStyle(of: family)
        let ps = style?.postScriptName ?? family
        let scalars = (NSFont(name: ps, size: 24)).map { FontCatalog.glyphScalars(for: $0 as CTFont) } ?? []
        let glyphSize = min(max(model.size, 18), 72)
        let cell = glyphSize * 1.6 + 8
        if scalars.isEmpty {
            ContentUnavailableView("No glyphs to show", systemImage: "square.grid.3x3",
                                   description: Text("This font maps no printable characters."))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell * 1.4), spacing: 8)], spacing: 8) {
                    ForEach(scalars, id: \.value) { scalar in
                        GlyphCell(scalar: scalar, font: FontCatalog.font(ps, size: glyphSize), height: cell, ink: ink) {
                            model.copy(String(Character(scalar)))
                        }
                    }
                }
                .padding(20)
            }
            .id(ps)
        }
    }
}

struct GlyphCell: View {
    let scalar: Unicode.Scalar
    let font: Font
    let height: CGFloat
    let ink: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(String(Character(scalar)))
                    .font(font)
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .minimumScaleFactor(0.4)
                Text(FontCatalog.codeLabel(scalar))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(hovering ? AnyShapeStyle(Theme.top) : AnyShapeStyle(.tertiary))
            }
            .padding(6)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.7 : 0.3)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.top.opacity(hovering ? 0.6 : 0), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(FontCatalog.codeLabel(scalar)) \(scalar.properties.name?.capitalized ?? ""). Click to copy.")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct CompareView: View {
    @ObservedObject var model: FontModel
    let ink: Color

    var body: some View {
        if model.pinned.isEmpty {
            ContentUnavailableView {
                Label("Nothing pinned", systemImage: "pin")
            } description: {
                Text("Pin up to four fonts with ⇧⌘P to set them side by side.")
            } actions: {
                if let name = model.selection {
                    Button("Pin \(name)") { model.togglePin(name) }.buttonStyle(.borderedProminent)
                }
            }
        } else {
            ScrollView {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(model.pinned, id: \.self) { name in
                        CompareColumn(model: model, family: name, ink: ink)
                    }
                }
                .padding(20)
            }
        }
    }
}

struct CompareColumn: View {
    @ObservedObject var model: FontModel
    let family: String
    let ink: Color
    @State private var hovering = false

    var body: some View {
        let ps = FontCatalog.regularStyle(in: model.styles(of: family))?.postScriptName ?? family
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(family).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                    Text(model.family(named: family)?.category.title ?? "")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    withAnimation(.snappy) { _ = model.togglePin(family) }
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0.5)
                .help("Unpin \(family)")
            }
            Rectangle().fill(Theme.gradient).frame(height: 2).clipShape(Capsule())
            Text(model.effectiveSample)
                .font(FontCatalog.font(ps, size: model.size))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(FontCatalog.alphabet)
                .font(FontCatalog.font(ps, size: 15))
                .foregroundStyle(ink.opacity(0.75))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary.opacity(0.6)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Font Name") { model.copy(family) }
            Button("Show in Styles") {
                model.selection = family
                model.mode = .styles
            }
        }
    }
}

/// Edit > Find Font (⌘F) moves focus to the sidebar search field where the system supports it.
struct SearchFocus: ViewModifier {
    let token: Int
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .searchFocused($focused)
                .onChange(of: token) { focused = true }
        } else {
            content
        }
    }
}
