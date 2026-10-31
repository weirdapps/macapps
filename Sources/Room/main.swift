import AppKit
import Combine
import DiskArbitration
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
    let disks = DiskStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "internaldrive.fill", accessibilityLabel: "Room") {
            RoomView().environmentObject(self.disks)
        }
        disks.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()
    }

    private func updateTitle() {
        guard disks.showFreeInBar, let boot = disks.volumes.first(where: \.isBoot) else {
            status.setTitle("")
            return
        }
        status.setTitle(Volume.compact(boot.available))
    }
}

// MARK: - Model

struct Volume: Identifiable, Equatable {
    let url: URL
    let name: String
    let total: Int64
    let available: Int64
    let isBoot: Bool
    let isEjectable: Bool
    let isDiskImage: Bool

    var id: URL { url }
    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsRootFileSystemKey, .volumeIsEjectableKey,
        .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsBrowsableKey,
    ]

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(Volume.keys)), v.volumeIsBrowsable != false,
              let total = v.volumeTotalCapacity, total > 0 else { return nil }
        self.url = url
        name = v.volumeLocalizedName ?? v.volumeName ?? url.lastPathComponent
        self.total = Int64(total)
        // "Important usage" counts purgeable space, as Finder does; fall back to the plain figure.
        available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        isBoot = v.volumeIsRootFileSystem == true
        isEjectable = !isBoot && (v.volumeIsEjectable == true || v.volumeIsRemovable == true || v.volumeIsInternal == false)
        isDiskImage = Volume.isDiskImage(url)
    }

    /// Disk images are mounted from a file; `hdiutil`-backed volumes report a disk image as their device model.
    private static func isDiskImage(_ url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let info = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        return (info[kDADiskDescriptionDeviceModelKey] as? String)?.contains("Disk Image") == true
    }

    /// Decimal units as Finder uses them, one decimal below 100: "491 GB", "1.5 TB", "12.3 GB".
    static func format(_ bytes: Int64) -> String {
        var value = Double(max(0, bytes))
        var unit = 0
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) bytes" }
        let tenths = (value * 10).rounded() / 10
        return tenths < 100 && tenths != tenths.rounded() ? String(format: "%.1f %@", tenths, units[unit])
            : String(format: "%.0f %@", value, units[unit])
    }

    /// Short form for the menu bar.
    static func compact(_ bytes: Int64) -> String { format(bytes) }
}

@MainActor
final class DiskStore: ObservableObject {
    @Published private(set) var volumes: [Volume] = []
    @Published var ejecting: URL?
    @Published var error: String?
    @AppStorage("showFreeInBar") var showFreeInBar = true

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        // Free space changes quietly; a slow poll is plenty for a menu bar figure.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 5
    }

    func refresh() {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Volume.keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        let now = urls.compactMap(Volume.init(url:)).sorted { a, b in
            a.isBoot != b.isBoot ? a.isBoot : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        if now != volumes { volumes = now }
    }

    func eject(_ volume: Volume) {
        ejecting = volume.url
        error = nil
        let url = volume.url
        Task.detached {
            let failure: String?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                failure = nil
            } catch {
                failure = "\(volume.name) is in use. Quit the apps using it and try again."
            }
            await MainActor.run {
                self.ejecting = nil
                withAnimation(.snappy) {
                    self.error = failure
                    self.refresh()
                }
            }
        }
    }
}

// MARK: - Views

enum Palette {
    static let accent = [Color(red: 1, green: 0.78, blue: 0.3), Color(red: 0.94, green: 0.5, blue: 0.1)]
    static let full = [Color(red: 1, green: 0.45, blue: 0.4), Color(red: 0.88, green: 0.16, blue: 0.2)]

    static func bar(_ fraction: Double) -> [Color] { fraction > 0.9 ? full : accent }
}

struct RoomView: View {
    @EnvironmentObject var disks: DiskStore

    var body: some View {
        VStack(spacing: 0) {
            if let boot = disks.volumes.first(where: \.isBoot) {
                Header(volume: boot)
            }
            VStack(spacing: 6) {
                ForEach(disks.volumes) { VolumeRow(volume: $0) }
                if disks.volumes.count == 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive.badge.plus")
                        Text("Drives and disk images appear here.")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                }
                if let error = disks.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            Divider().opacity(0.5)
            PanelFooter(name: "Room") {
                Toggle("Show Free Space in Menu Bar", isOn: $disks.showFreeInBar)
                Button("Open Storage Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                }
            }
        }
        .frame(width: 340)
        .animation(.snappy, value: disks.volumes)
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in disks.refresh() }
    }
}

struct Header: View {
    let volume: Volume

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Donut(fraction: volume.usedFraction)
                .frame(width: 70, height: 70)
            VStack(alignment: .leading, spacing: 2) {
                Text(Volume.format(volume.available))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("available on \(volume.name)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(Volume.format(volume.used)) used of \(Volume.format(volume.total))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

struct Donut: View {
    let fraction: Double

    var body: some View {
        let colors = Palette.bar(fraction)
        ZStack {
            Circle().stroke(.quaternary.opacity(0.6), lineWidth: 10)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[1].opacity(0.3), radius: 4)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

struct VolumeRow: View {
    @EnvironmentObject var disks: DiskStore
    let volume: Volume
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: volume.url.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(volume.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if volume.isDiskImage {
                        Text("Disk Image").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Volume.format(volume.available)) free")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                CapacityBar(fraction: volume.usedFraction)
                    .frame(height: 6)
                Text("\(Volume.format(volume.used)) of \(Volume.format(volume.total)) used")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if volume.isEjectable {
                if disks.ejecting == volume.url {
                    ProgressView().controlSize(.small).frame(width: 26, height: 26)
                } else {
                    GlassIconButton("eject.fill", help: "Eject \(volume.name)") { disks.eject(volume) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(hovering ? 0.5 : 0.3)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture { NSWorkspace.shared.open(volume.url) }
        .help("Open \(volume.name) in Finder")
    }
}

struct CapacityBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.7))
                Capsule()
                    .fill(LinearGradient(colors: Palette.bar(fraction), startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * fraction))
            }
        }
    }
}

// MARK: - Icon

//: a stack of disk platters, the top one filling up

func appIcon() -> NSBitmapImageRep {
    render(0xFFD25E, 0xE8670E) { ctx in
        let cx: CGFloat = 512, rx: CGFloat = 250, ry: CGFloat = 86
        func ellipse(_ y: CGFloat) -> CGRect { CGRect(x: cx - rx, y: y - ry, width: rx * 2, height: ry * 2) }
        // Three slabs from the bottom up, each a side band under an elliptical top.
        let band: CGFloat = 96
        for (i, y) in [CGFloat(360), 510, 660].enumerated() {
            ctx.saveGState()
            shadow(ctx, y: -12, blur: 26, alpha: 0.28)
            ctx.addEllipse(in: ellipse(y - band))
            ctx.addRect(CGRect(x: cx - rx, y: y - band, width: rx * 2, height: band))
            ctx.setFillColor(rgb(0xFBE3C4).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addEllipse(in: ellipse(y))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            // Status light on each band.
            ctx.setFillColor((i == 2 ? rgb(0x3DD68C) : rgb(0xF29A3B)).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx + 140, y: y - 69 - band / 2 - 15, width: 30, height: 30))
        }
        // Top platter: a used arc, like a capacity gauge.
        let top = ellipse(660).insetBy(dx: 40, dy: 14)
        ctx.saveGState()
        ctx.translateBy(x: cx, y: 660)
        ctx.scaleBy(x: 1, y: top.height / top.width)
        ctx.setLineWidth(36)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(rgb(0xF6D9B5).cgColor)
        ctx.addArc(center: .zero, radius: top.width / 2 - 18, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()
        ctx.setStrokeColor(rgb(0xF07F1E).cgColor)
        ctx.addArc(center: .zero, radius: top.width / 2 - 18, startAngle: .pi / 2, endAngle: .pi / 2 - 0.7 * 2 * .pi, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
