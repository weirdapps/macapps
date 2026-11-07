import AppKit
import Kit
import SwiftUI

// MARK: - Window

struct MindEditorView: View {
    @ObservedObject var document: MindDocument
    @StateObject private var editor: Editor
    @Environment(\.undoManager) private var undoManager
    @State private var panStart: CGSize?
    private let fileURL: URL?

    init(document: MindDocument, fileURL: URL? = nil, selection: UUID? = nil) {
        self.document = document
        self.fileURL = fileURL
        let editor = Editor(document: document, selection: selection)
        editor.fileURL = fileURL
        _editor = StateObject(wrappedValue: editor)
    }

    var body: some View {
        GeometryReader { geo in
            canvas
                .onAppear { editor.setViewSize(geo.size) }
                .onChange(of: geo.size) { _, size in editor.setViewSize(size) }
        }
        .frame(minWidth: 560, minHeight: 380)
        .overlay(alignment: .bottom) { StatusBar(editor: editor) }
        .toolbar { toolbar }
        .focusedSceneObject(editor)
        .onAppear { editor.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in editor.undoManager = manager }
        // Saving an untitled map (or renaming it) gives it a URL; exports are named after it.
        .onChange(of: fileURL) { _, url in editor.fileURL = url }
    }

    private var canvas: some View {
        let layout = editor.layout
        let viewport = editor.viewport
        let dragged = editor.drag.map { layout.branch(of: $0.id, in: document.map) } ?? []
        return ZStack(alignment: .topLeading) {
            KeyCatcher(editor: editor)
            DotGrid(viewport: viewport)
                .contentShape(Rectangle())
                .gesture(panGesture)
                .onTapGesture {
                    editor.finishEditing()
                    editor.focusCanvas()
                }
            Connectors(layout: layout, viewport: viewport, dimmed: dragged)
            ForEach(layout.order, id: \.self) { id in
                if let node = document.map.node(id), let frame = layout.frames[id] {
                    topic(node, frame: frame, viewport: viewport, dimmed: dragged.contains(id))
                }
            }
            if let drag = editor.drag, let frame = layout.frames[drag.id], let node = document.map.node(drag.id) {
                DragPreview(drag: drag, node: node, frame: frame, layout: layout, viewport: viewport)
            }
            if document.map.root.children.isEmpty, let root = layout.frames[document.map.root.id] {
                Text("Press Tab to add a branch, then keep typing.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .position(x: viewport.screen(root.center).x,
                              y: viewport.screen(root.center).y + root.size.height * viewport.scale / 2 + 28)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "canvas")
        .clipped()
    }

    @ViewBuilder
    private func topic(_ node: Node, frame: NodeFrame, viewport: Viewport, dimmed: Bool) -> some View {
        let isRoot = frame.depth == 0
        NodeChip(text: node.text, frame: frame, scale: viewport.scale,
                 selected: editor.selection == node.id && editor.drag == nil,
                 dropTarget: editor.drag?.target == node.id,
                 editor: editor.editingID == node.id ? editor : nil)
            .opacity(dimmed ? 0.3 : 1)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { editor.beginEditing(node.id) }
            .onTapGesture { editor.select(node.id) }
            .gesture(isRoot ? nil : DragGesture(minimumDistance: 5, coordinateSpace: .named("canvas"))
                .onChanged { editor.dragChanged(node.id, at: $0.location) }
                .onEnded { _ in editor.dragEnded() })
            .simultaneousGesture(isRoot ? panGesture : nil)
            .position(viewport.screen(frame.center))
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .help(isRoot ? "" : "Drag onto another topic to move this branch")
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = panStart ?? editor.viewport.offset
                if panStart == nil { panStart = start }
                editor.viewport.offset = CGSize(width: start.width + value.translation.width,
                                                height: start.height + value.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { editor.addChild() } label: { Label("Add Child", systemImage: "arrow.turn.down.right") }
                .help("Add a child topic (Tab)")
            Button { editor.addSibling() } label: { Label("Add Sibling", systemImage: "plus") }
                .help("Add a sibling topic (Return)")
            Button { editor.toggleCollapse() } label: {
                Label("Collapse", systemImage: document.map.node(editor.selection)?.collapsed == true
                      ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
            .help("Collapse or expand the selected topic (Space)")
            .disabled(!editor.canToggle)
        }
        ToolbarItem { Spacer() }
        ToolbarItemGroup {
            Button { editor.zoom(by: 1 / 1.25) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .help("Zoom out (Command -)")
            Text("\(Int((editor.viewport.scale * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42)
                .contentTransition(.numericText())
            Button { editor.zoom(by: 1.25) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .help("Zoom in (Command +)")
            Button { editor.fit() } label: { Label("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Fit the whole map in the window (Command 9)")
        }
    }
}

// MARK: - Canvas pieces

/// A quiet dot grid that moves and scales with the map.
struct DotGrid: View {
    let viewport: Viewport

    var body: some View {
        Canvas { ctx, size in
            var spacing = 26 * viewport.scale
            while spacing < 14 { spacing *= 2 }
            let origin = viewport.screen(CGPoint.zero)
            let startX = origin.x.truncatingRemainder(dividingBy: spacing) - spacing
            let startY = origin.y.truncatingRemainder(dividingBy: spacing) - spacing
            let dot = max(1.2, 1.6 * min(viewport.scale, 1.2))
            var path = Path()
            var y = startY
            while y < size.height + spacing {
                var x = startX
                while x < size.width + spacing {
                    path.addEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                    x += spacing
                }
                y += spacing
            }
            ctx.fill(path, with: .color(.primary.opacity(0.09)))
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// A smooth S curve from a parent to a child; animates when the layout changes.
struct Connector: Shape {
    var from: CGPoint
    var to: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(from.x, from.y), AnimatablePair(to.x, to.y)) }
        set {
            from = CGPoint(x: newValue.first.first, y: newValue.first.second)
            to = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = (from.x + to.x) / 2
        path.move(to: from)
        path.addCurve(to: to, control1: CGPoint(x: mid, y: from.y), control2: CGPoint(x: mid, y: to.y))
        return path
    }
}

struct Connectors: View {
    let layout: MapLayout
    let viewport: Viewport
    var dimmed: Set<UUID> = []

    var body: some View {
        ZStack {
            ForEach(layout.order.dropFirst(), id: \.self) { id in
                if let f = layout.frames[id], let pid = f.parent, let p = layout.frames[pid] {
                    Connector(from: viewport.screen(p.outer(toward: f.side)), to: viewport.screen(f.inner))
                        .stroke(Theme.branch(f.branch),
                                style: StrokeStyle(lineWidth: Self.width(f.depth) * viewport.scale, lineCap: .round))
                        .opacity(dimmed.contains(id) ? 0.25 : 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    static func width(_ depth: Int) -> CGFloat { depth == 1 ? 4.5 : depth == 2 ? 2.6 : 1.8 }
}

/// One topic: the central topic in the app's violet, main branches filled with their colour,
/// deeper topics as light chips edged in it.
struct NodeChip: View {
    let text: String
    let frame: NodeFrame
    let scale: CGFloat
    var selected = false
    var dropTarget = false
    var editor: Editor?

    @State private var hovering = false

    var body: some View {
        let depth = frame.depth
        let pad = Style.padding(depth)
        let radius = Style.cornerRadius(depth, height: frame.size.height) * scale
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let textSize = CGSize(width: (frame.size.width - pad.width * 2) * scale,
                              height: (frame.size.height - pad.height * 2) * scale)
        ZStack {
            background(shape)
            if let editor {
                NodeTextField(editor: editor, font: Style.font(depth, scale: scale),
                              color: depth <= 1 ? .white : .labelColor)
                    .frame(width: textSize.width + 2 * scale, height: textSize.height)
            } else {
                Text(text.isEmpty ? Style.placeholder : text)
                    .font(Font(Style.font(depth, scale: scale) as CTFont))
                    .foregroundStyle(foreground(empty: text.isEmpty))
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .minimumScaleFactor(0.6)
                    .frame(width: textSize.width + 2 * scale, height: textSize.height)
            }
        }
        .frame(width: frame.size.width * scale, height: frame.size.height * scale)
        .overlay {
            if selected || dropTarget {
                shape.inset(by: -4 * scale)
                    .stroke(dropTarget ? Theme.branch(frame.branch) : Theme.accent,
                            style: StrokeStyle(lineWidth: 2.5 * scale, dash: dropTarget ? [5 * scale, 4 * scale] : []))
            }
        }
        .overlay(alignment: frame.side < 0 ? .leading : .trailing) {
            if frame.hidden > 0 { badge }
        }
        .brightness(hovering && !selected ? 0.03 : 0)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: selected)
    }

    @ViewBuilder
    private func background(_ shape: RoundedRectangle) -> some View {
        switch frame.depth {
        case 0:
            shape.fill(Theme.gradient)
                .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: Color(nsColor: rgb(Theme.bottom)).opacity(0.45), radius: 16 * scale, y: 6 * scale)
        case 1:
            shape.fill(LinearGradient(colors: [Theme.branchLight(frame.branch), Theme.branch(frame.branch)],
                                      startPoint: .top, endPoint: .bottom))
                .shadow(color: Theme.branch(frame.branch).opacity(0.35), radius: 6 * scale, y: 3 * scale)
        default:
            shape.fill(Color(nsColor: .textBackgroundColor))
                .overlay(shape.fill(Theme.branch(frame.branch).opacity(0.10)))
                .overlay(shape.strokeBorder(Theme.branch(frame.branch).opacity(0.55), lineWidth: max(0.75, 1.1 * scale)))
        }
    }

    private func foreground(empty: Bool) -> some ShapeStyle {
        if frame.depth <= 1 { return AnyShapeStyle(Color.white.opacity(empty ? 0.6 : 1)) }
        return empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary)
    }

    /// How many topics a collapsed topic hides, on its outer edge.
    private var badge: some View {
        let d = 20 * scale
        return Text("\(frame.hidden)")
            .font(.system(size: 10.5 * scale, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: d, minHeight: d)
            .padding(.horizontal, frame.hidden > 9 ? 3 * scale : 0)
            .background(Capsule().fill(frame.depth == 0 ? Theme.accent : Theme.branch(frame.branch)))
            .shadow(color: .black.opacity(0.12), radius: 2 * scale, y: 1 * scale)
            .fixedSize()
            .offset(x: CGFloat(frame.side < 0 ? -1 : 1) * (d + 5 * scale))
    }
}

/// The topic following the pointer while it is dragged, with a dashed line to the topic it would join.
struct DragPreview: View {
    let drag: Editor.DragState
    let node: Node
    let frame: NodeFrame
    let layout: MapLayout
    let viewport: Viewport

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let target = drag.target, let t = layout.frames[target] {
                let side = t.side == 0 ? (drag.location.x >= viewport.screen(t.center).x ? 1 : -1) : t.side
                Connector(from: viewport.screen(t.outer(toward: side)), to: drag.location)
                    .stroke(Theme.branch(t.branch < 0 ? frame.branch : t.branch),
                            style: StrokeStyle(lineWidth: 2 * viewport.scale, lineCap: .round, dash: [6, 5]))
            }
            NodeChip(text: node.text, frame: frame, scale: viewport.scale)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
                .scaleEffect(1.04)
                .position(drag.location)
        }
        .allowsHitTesting(false)
    }
}

/// The bottom bar: topic count, the key hints, and a Show in Finder link after an export.
struct StatusBar: View {
    @ObservedObject var editor: Editor

    var body: some View {
        HStack(spacing: 10) {
            Text("\(editor.document.map.count) topics")
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            if let url = editor.exported {
                Divider().frame(height: 12)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                Text("Exported \(url.lastPathComponent)").font(.system(size: 12)).lineLimit(1)
                Button("Show in Finder") { revealInFinder([url]) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            Spacer(minLength: 12)
            hint("Tab", "child")
            hint("Return", "sibling")
            hint("Space", "collapse")
            hint("Type", "to edit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background {
            Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            KeyCap(key)
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Export

/// The map drawn at 100% on a plain background, for PNG export.
struct MapArtwork: View {
    let map: MindMap
    let layout: MapLayout

    static let margin: CGFloat = 48

    var body: some View {
        let b = layout.bounds.insetBy(dx: -Self.margin - 24, dy: -Self.margin)
        let viewport = Viewport(size: b.size, scale: 1, offset: CGSize(width: -b.midX, height: -b.midY))
        ZStack(alignment: .topLeading) {
            Color(nsColor: .textBackgroundColor)
            Connectors(layout: layout, viewport: viewport)
            ForEach(layout.order, id: \.self) { id in
                if let node = map.node(id), let frame = layout.frames[id] {
                    NodeChip(text: node.text, frame: frame, scale: 1).position(viewport.screen(frame.center))
                }
            }
        }
        .frame(width: b.width, height: b.height)
    }
}
