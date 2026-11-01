import AppKit
import Carbon.HIToolbox
import Combine
import DiskArbitration
import Kit
import SwiftUI
import UniformTypeIdentifiers

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
    private var hotKey: HotKey?
    private var cancellables: Set<AnyCancellable> = []
    let drives = DriveList()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "eject", accessibilityLabel: "Eject") {
            EjectView().environmentObject(self.drives)
        }
        status.onSecondaryClick = { [weak self] in self?.drives.ejectAll(feedback: true) }
        hotKey = HotKey(keyCode: kVK_ANSI_E, modifiers: cmdKey | optionKey) { [weak self] in self?.drives.ejectAll(feedback: true) }
        // objectWillChange covers both the volume list and the "Show Count" setting.
        drives.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatus() }
            .store(in: &cancellables)
        updateStatus()
    }

    private func updateStatus() {
        let volumes = drives.volumes
        status.setSymbol(volumes.isEmpty ? "eject" : "eject.fill", label: "\(volumes.count) ejectable volumes")
        status.setTitle(volumes.isEmpty || !drives.showCount ? "" : "\(volumes.count)")
    }
}

// MARK: - Model

struct Drive: Identifiable, Equatable {
    enum Kind: String { case diskImage = "Disk Image", external = "External", network = "Network", removable = "Removable" }

    let url: URL
    let name: String
    let total: Int64
    let available: Int64
    let kind: Kind

    var id: URL { url }

    init(url: URL, name: String, total: Int64, available: Int64, kind: Kind) {
        self.url = url
        self.name = name
        self.total = total
        self.available = available
        self.kind = kind
    }

    /// Made-up disks for `--snapshot`, so a published image never shows the owner's volume names.
    static let demo = [
        Drive(url: URL(fileURLWithPath: "/Volumes/Backup"), name: "Backup", total: 2_000_000_000_000, available: 812_000_000_000, kind: .external),
        Drive(url: URL(fileURLWithPath: "/Volumes/Installer"), name: "Installer", total: 14_200_000_000, available: 0, kind: .diskImage),
        Drive(url: URL(fileURLWithPath: "/Volumes/SD Card"), name: "SD Card", total: 64_000_000_000, available: 41_300_000_000, kind: .removable),
    ]

    static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRootFileSystemKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
    ]

    /// Volumes a person would eject: anything browsable that is not the startup disk or an internal partition.
    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(Drive.keys)), v.volumeIsBrowsable != false,
              v.volumeIsRootFileSystem != true else { return nil }
        let local = v.volumeIsLocal != false
        let removable = v.volumeIsEjectable == true || v.volumeIsRemovable == true
        guard !local || removable || v.volumeIsInternal == false else { return nil }
        self.url = url
        name = v.volumeLocalizedName ?? url.lastPathComponent
        total = Int64(v.volumeTotalCapacity ?? 0)
        available = Int64(v.volumeAvailableCapacity ?? 0)
        kind = !local ? .network : Drive.isDiskImage(url) ? .diskImage : removable ? .removable : .external
    }

    private static func isDiskImage(_ url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let info = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        return (info[kDADiskDescriptionDeviceModelKey] as? String)?.contains("Disk Image") == true
    }

    /// The system's own icon for this kind of disk, for when there is no mounted path to ask Finder about.
    var genericIcon: NSImage {
        let file = switch kind {
        case .external: "/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/External.icns"
        case .removable: "/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/Removable.icns"
        case .network, .diskImage: ""
        }
        return NSImage(contentsOfFile: file) ?? NSWorkspace.shared.icon(for: kind == .diskImage ? UTType(filenameExtension: "dmg") ?? .diskImage : .volume)
    }

    var symbol: String {
        switch kind {
        case .diskImage: "opticaldiscdrive.fill"
        case .network: "server.rack"
        case .removable: "sdcard.fill"
        case .external: "externaldrive.fill"
        }
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
final class DriveList: ObservableObject {
    @Published private(set) var volumes: [Drive] = []
    @Published private(set) var ejecting: Set<URL> = []
    @Published var errors: [URL: String] = [:]
    @AppStorage("showCount") var showCount = true

    private var observers: [NSObjectProtocol] = []

    init() {
        if StatusPopover.isSnapshot {
            volumes = Drive.demo
            return
        }
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        guard !StatusPopover.isSnapshot else { return }
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Drive.keys, options: [.skipHiddenVolumes]) ?? []
        let now = urls.compactMap(Drive.init(url:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if now != volumes { withAnimation(.snappy) { volumes = now } }
        errors = errors.filter { url, _ in now.contains { $0.url == url } }
    }

    func eject(_ drive: Drive) { eject([drive], feedback: false) }

    func ejectAll(feedback: Bool) {
        guard !volumes.isEmpty else {
            if feedback { HUD.show(symbol: "eject", title: "Nothing to eject") }
            return
        }
        eject(volumes, feedback: feedback)
    }

    private func eject(_ drives: [Drive], feedback: Bool) {
        let pending = drives.filter { !ejecting.contains($0.url) }
        guard !pending.isEmpty else { return }
        pending.forEach { ejecting.insert($0.url); errors[$0.url] = nil }
        Task.detached(priority: .userInitiated) {
            var failures: [(Drive, String)] = []
            for drive in pending {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: drive.url)
                } catch {
                    // Ejecting one partition ejects the whole disk, so its sibling is already gone: not a failure.
                    guard FileManager.default.fileExists(atPath: drive.url.path) else { continue }
                    failures.append((drive, DriveList.explain(error, name: drive.name)))
                }
            }
            let failed = failures
            await MainActor.run {
                pending.forEach { self.ejecting.remove($0.url) }
                withAnimation(.snappy) {
                    for (drive, message) in failed { self.errors[drive.url] = message }
                }
                self.refresh()
                guard feedback else { return }
                if let (drive, message) = failed.first {
                    // The HUD is small: name the cause only when it is the common one, the row shows the full sentence.
                    let one = message.hasPrefix("\(drive.name) is in use") ? "\(drive.name) is in use" : "\(drive.name) could not be ejected"
                    HUD.show(symbol: "exclamationmark.triangle.fill", title: failed.count == 1 ? one : "\(failed.count) disks could not be ejected",
                             tint: .orange)
                } else {
                    HUD.show(symbol: "eject.fill", title: pending.count == 1 ? "Ejected \(pending[0].name)" : "Ejected \(pending.count) disks")
                }
            }
        }
    }

    /// Turns the error into a sentence that says what to do next.
    nonisolated static func explain(_ error: Error, name: String) -> String {
        let ns = error as NSError
        // A volume with open files fails with fBsyErr (-47) from NSWorkspace, or EBUSY from the unmount below it.
        if ns.code == -47 || ns.code == Int(EBUSY) || (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EBUSY) {
            return "\(name) is in use. Quit the apps or close the files using it, then try again."
        }
        if ns.code == -5000 || ns.code == Int(EPERM) || ns.code == NSFileWriteNoPermissionError {
            return "You do not have permission to eject \(name)."
        }
        return "\(name) could not be ejected. \(ns.localizedDescription)"
    }
}

// MARK: - Views

enum Palette {
    static let accent = [Color(red: 0.42, green: 0.6, blue: 1), Color(red: 0.25, green: 0.27, blue: 0.88)]
}

struct EjectView: View {
    @EnvironmentObject var drives: DriveList

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Disks").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(drives.volumes.isEmpty ? "Nothing connected" : "\(drives.volumes.count) ready to eject")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if drives.volumes.count > 1 {
                    Button {
                        drives.ejectAll(feedback: false)
                    } label: {
                        Label("Eject All", systemImage: "eject.fill")
                    }
                    .buttonStyle(PillButtonStyle(Palette.accent))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(spacing: 6) {
                if drives.volumes.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "externaldrive.badge.checkmark")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(LinearGradient(colors: Palette.accent, startPoint: .top, endPoint: .bottom))
                        Text("Drives, card readers, disk images and network shares show up here, ready to eject.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 24)
                    }
                    .padding(.vertical, 22)
                }
                ForEach(drives.volumes) { DriveRow(drive: $0) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            HStack(spacing: 6) {
                Text("Eject all from anywhere").font(.system(size: 11)).foregroundStyle(.tertiary)
                KeyCap("⌥⌘E")
                Text("or right-click the icon").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 12)
            Divider().opacity(0.5)
            PanelFooter(name: "Eject", shortcut: "⌥⌘E") {
                Toggle("Show Count in Menu Bar", isOn: $drives.showCount)
            }
        }
        .frame(width: 340)
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in drives.refresh() }
    }
}

struct DriveRow: View {
    @EnvironmentObject var drives: DriveList
    let drive: Drive
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // A generic disk icon when the path is gone (just ejected, or a snapshot's made-up disk).
                Image(nsImage: FileManager.default.fileExists(atPath: drive.url.path)
                    ? NSWorkspace.shared.icon(forFile: drive.url.path) : drive.genericIcon)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(drive.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: drive.symbol).font(.system(size: 9))
                        Text(drive.total > 0 ? "\(drive.kind.rawValue) · \(Format.bytes(drive.total)), \(Format.bytes(drive.available)) free"
                             : drive.kind.rawValue)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Spacer()
                if drives.ejecting.contains(drive.url) {
                    ProgressView().controlSize(.small).frame(width: 26, height: 26)
                } else {
                    GlassIconButton("eject.fill", help: "Eject \(drive.name)") { drives.eject(drive) }
                }
            }
            if let error = drives.errors[drive.url] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(hovering ? 0.5 : 0.3)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture { NSWorkspace.shared.open(drive.url) }
        .help("Open \(drive.name) in Finder")
    }
}

// MARK: - Icon

//: the eject symbol over a glowing drive slot

func appIcon() -> NSBitmapImageRep {
    render(0x6E9BFF, 0x3036C8) { ctx in
        // Drive slot glow.
        radial([rgb(0xA8C4FF, 0.55), rgb(0xA8C4FF, 0)], center: CGPoint(x: 512, y: 300), radius: 360, in: ctx)
        // Triangle with softly rounded corners.
        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: 512, y: 770))
        tri.addLine(to: CGPoint(x: 268, y: 470))
        tri.addLine(to: CGPoint(x: 756, y: 470))
        tri.closeSubpath()
        let soft = tri.union(tri.copy(strokingWithWidth: 60, lineCap: .round, lineJoin: .round, miterLimit: 10))
        let bar = roundedRect(CGRect(x: 238, y: 270, width: 548, height: 110), 50)
        for shape in [soft, bar] {
            ctx.saveGState()
            shadow(ctx, y: -16, blur: 30, alpha: 0.32)
            ctx.addPath(shape)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            gradient([rgb(0xFFFFFF), rgb(0xDDE4FF)], from: CGPoint(x: 0, y: 800), to: CGPoint(x: 0, y: 260), in: ctx)
            ctx.restoreGState()
        }
    }
}
