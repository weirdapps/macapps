import AppKit
import Combine
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
    private var cancellables: Set<AnyCancellable> = []
    let trash = TrashWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "trash", accessibilityLabel: "Bin") {
            BinView().environmentObject(self.trash)
        }
        trash.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatus() }
            .store(in: &cancellables)
        updateStatus()
    }

    private func updateStatus() {
        guard case .ready(let contents) = trash.state, contents.count > 0 else {
            status.setSymbol("trash", label: "Trash is empty")
            status.setTitle("")
            return
        }
        status.setSymbol("trash.fill", label: "Trash has \(contents.count) items")
        switch trash.badge {
        case .count: status.setTitle("\(contents.count)")
        case .size: status.setTitle(Format.bytes(contents.bytes))
        case .none: status.setTitle("")
        }
    }
}

// MARK: - Model

struct TrashItem: Identifiable, Equatable {
    let url: URL
    let bytes: Int64
    var id: URL { url }
}

struct TrashContents: Equatable {
    var count = 0
    var bytes: Int64 = 0
    var largest: [TrashItem] = []
}

enum TrashState: Equatable {
    case loading, denied, ready(TrashContents)
}

enum Badge: String, CaseIterable {
    case count, size, none

    var title: String {
        switch self {
        case .count: "Item Count"
        case .size: "Size"
        case .none: "Nothing"
        }
    }
}

enum Trash {
    static var url: URL {
        (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }

    /// Top-level names, or nil when macOS does not let this app read the folder.
    static func names() -> [URL]? {
        try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
            .filter { $0.lastPathComponent != ".DS_Store" }
    }

    /// Size on disk of a file or a whole folder tree.
    static func size(of item: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        func allocated(_ u: URL) -> Int64 {
            let v = try? u.resourceValues(forKeys: keys)
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        guard (try? item.resourceValues(forKeys: keys))?.isDirectory == true else { return allocated(item) }
        var total = allocated(item)
        if let e = FileManager.default.enumerator(at: item, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) {
            for case let u as URL in e { total += allocated(u) }
        }
        return total
    }

    static func read() -> TrashState {
        guard let names = names() else { return .denied }
        let items = names.map { TrashItem(url: $0, bytes: size(of: $0)) }
        return .ready(TrashContents(count: items.count, bytes: items.reduce(0) { $0 + $1.bytes },
                                    largest: Array(items.sorted { $0.bytes > $1.bytes }.prefix(6))))
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        var value = Double(max(0, count))
        var unit = 0
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        while value >= 999.5 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) bytes" }
        return value < 9.95 ? String(format: "%.1f %@", value, units[unit]) : String(format: "%.0f %@", value, units[unit])
    }
}

@MainActor
final class TrashWatcher: ObservableObject {
    @Published private(set) var state = TrashState.loading
    @AppStorage("badge") var badge = Badge.count

    private var lastNames: [URL]?
    private var timer: Timer?
    private var busy = false

    init() {
        refresh(force: true)
        // Listing the top level is cheap; the full size is only recomputed when that listing changes.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: false) }
        }
        timer?.tolerance = 1
    }

    func refresh(force: Bool) {
        guard !busy else { return }
        let names = Trash.names()
        guard force || names != lastNames else { return }
        lastNames = names
        busy = true
        Task.detached(priority: .utility) {
            let state = Trash.read()
            await MainActor.run {
                self.busy = false
                withAnimation(.snappy) { self.state = state }
            }
        }
    }

    func openTrash() { NSWorkspace.shared.open(Trash.url) }

    func reveal(_ item: TrashItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
}

// MARK: - Views

enum Palette {
    static let accent = [Color(red: 0.6, green: 0.68, blue: 0.78), Color(red: 0.32, green: 0.38, blue: 0.48)]
}

struct BinView: View {
    @EnvironmentObject var trash: TrashWatcher

    var body: some View {
        VStack(spacing: 0) {
            switch trash.state {
            case .loading:
                ProgressView().controlSize(.small).padding(.vertical, 50)
            case .denied:
                Message(symbol: "lock.fill", title: "The Trash is private",
                        text: "macOS only shows the Trash to apps with Full Disk Access. Bin does not ask for it, so open the Trash in Finder instead.")
            case .ready(let contents) where contents.count == 0:
                Message(symbol: "sparkles", title: "The Trash is empty", text: "Nothing to clean up right now.")
            case .ready(let contents):
                Summary(contents: contents)
                VStack(spacing: 4) {
                    HStack {
                        Text("Largest items").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    ForEach(contents.largest) { ItemRow(item: $0) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            Button {
                trash.openTrash()
            } label: {
                Label("Open Trash in Finder", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(PillButtonStyle(Palette.accent))
            .padding(.bottom, 14)
            Divider().opacity(0.5)
            PanelFooter(name: "Bin") {
                Picker("Menu Bar Shows", selection: $trash.badge) {
                    ForEach(Badge.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        .frame(width: 320)
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in trash.refresh(force: true) }
    }
}

struct Summary: View {
    let contents: TrashContents

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "trash.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: Palette.accent, startPoint: .top, endPoint: .bottom)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.25)))
                .shadow(color: Palette.accent[1].opacity(0.4), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.bytes(contents.bytes))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("\(contents.count) \(contents.count == 1 ? "item" : "items") in the Trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }
}

struct ItemRow: View {
    @EnvironmentObject var trash: TrashWatcher
    let item: TrashItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 22, height: 22)
            Text(item.url.lastPathComponent)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(Format.bytes(item.bytes))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(hovering ? 0.55 : 0.3)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture { trash.reveal(item) }
        .help("Show in Finder")
    }
}

struct Message: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(LinearGradient(colors: Palette.accent, startPoint: .top, endPoint: .bottom))
            Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 26)
        }
        .padding(.top, 28)
        .padding(.bottom, 18)
    }
}

// MARK: - Icon

//: a ribbed bin with a lid lifting off

func appIcon() -> NSBitmapImageRep {
    render(0xA9B7C9, 0x445066) { ctx in
        // Body: a tapered can.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 312, y: 640))
        body.addLine(to: CGPoint(x: 712, y: 640))
        body.addLine(to: CGPoint(x: 668, y: 238))
        body.addQuadCurve(to: CGPoint(x: 618, y: 196), control: CGPoint(x: 664, y: 196))
        body.addLine(to: CGPoint(x: 406, y: 196))
        body.addQuadCurve(to: CGPoint(x: 356, y: 238), control: CGPoint(x: 360, y: 196))
        body.closeSubpath()
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 30, alpha: 0.32)
        ctx.addPath(body)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xDCE3EC)], from: CGPoint(x: 312, y: 0), to: CGPoint(x: 712, y: 0), in: ctx)
        // Ribs.
        ctx.setStrokeColor(rgb(0xB8C3D2).cgColor)
        ctx.setLineWidth(26)
        ctx.setLineCap(.round)
        for (top, bottom) in [(CGFloat(430), CGFloat(446)), (512, 512), (594, 578)] {
            ctx.move(to: CGPoint(x: top, y: 580)); ctx.addLine(to: CGPoint(x: bottom, y: 260))
        }
        ctx.strokePath()
        ctx.restoreGState()
        // Lid, tilted as if just lifted.
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 700)
        ctx.rotate(by: 0.12)
        shadow(ctx, y: -10, blur: 22, alpha: 0.3)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(roundedRect(CGRect(x: -236, y: 0, width: 472, height: 64), 32))
        ctx.addPath(roundedRect(CGRect(x: -70, y: 50, width: 140, height: 62), 26))
        ctx.fillPath()
        ctx.setFillColor(rgb(0xA9B7C9).cgColor)
        ctx.addPath(roundedRect(CGRect(x: -34, y: 64, width: 68, height: 22), 11))
        ctx.fillPath()
        ctx.restoreGState()
        // A sparkle: freshly emptied.
        sparkle(ctx, at: CGPoint(x: 790, y: 790), size: 54, color: .white)
        sparkle(ctx, at: CGPoint(x: 240, y: 380), size: 30, color: NSColor.white.withAlphaComponent(0.8))
    }
}
