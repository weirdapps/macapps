import AppKit
import Carbon.HIToolbox
import Combine
import AudioToolbox
import CoreAudio
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
    private var hotKey: HotKey?
    private var cancellables: Set<AnyCancellable> = []
    let mic = Microphone()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "mic.fill", accessibilityLabel: "Hush") {
            HushView().environmentObject(self.mic)
        }
        status.onSecondaryClick = { [weak self] in self?.mic.toggle(feedback: true) }
        hotKey = HotKey(keyCode: kVK_ANSI_M, modifiers: cmdKey | optionKey) { [weak self] in
            self?.mic.toggle(feedback: true)
        }
        mic.hotKeyReady = StatusPopover.isSnapshot || hotKey?.isRegistered == true
        mic.$muted.sink { [weak self] muted in
            self?.status.setSymbol(muted ? "mic.slash.fill" : "mic.fill", label: muted ? "Microphone muted" : "Microphone live")
        }
        .store(in: &cancellables)
    }
}

// MARK: - CoreAudio

@MainActor
final class Microphone: ObservableObject {
    @Published private(set) var muted = false
    @Published private(set) var deviceName = "No input device"
    @AppStorage("playSound") var playSound = true
    @AppStorage("showHUD") var showHUD = true
    /// False when another app already owns the shortcut, so the panel stops advertising it.
    @Published var hotKeyReady = true

    /// Input volume saved before muting, for devices without a mute control, by device name.
    /// Kept in defaults so a relaunch while muted still restores the user's level.
    private var savedVolume: [String: Float] {
        get { UserDefaults.standard.dictionary(forKey: "savedVolume") as? [String: Float] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "savedVolume") }
    }
    private var timer: Timer?

    init() {
        // Screenshots go on a public page: a fixed device name, never this Mac's.
        if StatusPopover.isSnapshot {
            deviceName = "MacBook Pro Microphone"
            return
        }
        refresh()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Keep the user's intent when the input device changes.
                let wanted = self.muted
                self.refresh()
                if wanted != self.muted { self.set(muted: wanted, feedback: false) }
            }
        }
        // Another app may change the mute state; a light poll keeps the icon honest.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func toggle(feedback: Bool) { set(muted: !muted, feedback: feedback) }

    func set(muted wanted: Bool, feedback: Bool) {
        guard let device = Microphone.defaultInput() else { return }
        if Microphone.hasMute(device) {
            Microphone.setMute(device, wanted)
        } else {
            let key = Microphone.name(device) ?? String(device)
            if wanted {
                savedVolume[key] = Microphone.volume(device) ?? 1
                Microphone.setVolume(device, 0)
            } else {
                Microphone.setVolume(device, max(savedVolume[key] ?? 1, 0.05))
            }
        }
        refresh()
        guard feedback else { return }
        if playSound { NSSound(named: muted ? "Bottle" : "Pop")?.play() }
        if showHUD {
            HUD.show(symbol: muted ? "mic.slash.fill" : "mic.fill",
                     title: muted ? "Microphone Off" : "Microphone On",
                     tint: muted ? .red : .primary)
        }
    }

    func refresh() {
        guard let device = Microphone.defaultInput() else {
            deviceName = "No input device"
            return
        }
        deviceName = Microphone.name(device) ?? "Microphone"
        let now = Microphone.hasMute(device) ? Microphone.isMuted(device) : (Microphone.volume(device) ?? 1) < 0.001
        if now != muted { muted = now }
    }

    // MARK: Property helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeInput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInput() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    static func name(_ device: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    static func hasMute(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyMute)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value != 0
    }

    static func setMute(_ device: AudioDeviceID, _ muted: Bool) {
        var address = address(kAudioDevicePropertyMute)
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func volume(_ device: AudioDeviceID) -> Float32? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setVolume(_ device: AudioDeviceID, _ volume: Float32) {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = volume
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}

// MARK: - Views

struct HushView: View {
    @EnvironmentObject var mic: Microphone

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                MuteButton(muted: mic.muted) { mic.toggle(feedback: false) }
                VStack(spacing: 4) {
                    Text(mic.muted ? "Microphone is off" : "Microphone is live")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .contentTransition(.interpolate)
                    Label(mic.deviceName, systemImage: "waveform")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if mic.hotKeyReady {
                        Text("Toggle from anywhere").font(.system(size: 11)).foregroundStyle(.tertiary)
                        KeyCap("⌥⌘M")
                        Text("or right-click the icon").font(.system(size: 11)).foregroundStyle(.tertiary)
                    } else {
                        Text("⌥⌘M is taken by another app. Right-click the icon to toggle.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 26)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)

            Divider().opacity(0.5)
            PanelFooter(name: "Hush") {
                Toggle("Play Sound", isOn: $mic.playSound)
                Toggle("Show Overlay", isOn: $mic.showHUD)
            }
        }
        .frame(width: 300)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: mic.muted)
    }
}

struct MuteButton: View {
    let muted: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Soft rings that breathe while the microphone is live.
                ForEach(0..<2) { i in
                    Circle()
                        .stroke(Color.green.opacity(muted ? 0 : 0.25), lineWidth: 2)
                        .scaleEffect(pulse ? 1.35 + CGFloat(i) * 0.18 : 1)
                        .opacity(pulse ? 0 : 1)
                        .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(Double(i) * 0.5), value: pulse)
                }
                Circle()
                    .fill(LinearGradient(colors: muted
                                         ? [Color(red: 1, green: 0.38, blue: 0.36), Color(red: 0.86, green: 0.12, blue: 0.2)]
                                         : [Color(red: 0.3, green: 0.85, blue: 0.5), Color(red: 0.1, green: 0.62, blue: 0.36)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .overlay(
                        Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                            .padding(3)
                    )
                    .shadow(color: (muted ? Color.red : .green).opacity(0.4), radius: hovering ? 14 : 9, y: 4)
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
            .frame(width: 104, height: 104)
            .scaleEffect(hovering ? 1.04 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onAppear { pulse = true }
        .help(muted ? "Unmute" : "Mute")
    }
}

// MARK: - Icon

//: a studio microphone with a slash

func appIcon() -> NSBitmapImageRep {
    render(0xFF6A6A, 0xD81B60) { ctx in
        let c = CGPoint(x: 512, y: 512)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.1).cgColor)
        ctx.setLineWidth(18)
        for r in [250.0, 340] { ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r + 30, width: r * 2, height: r * 2)) }

        ctx.saveGState()
        shadow(ctx, y: -14, blur: 26, alpha: 0.3)
        let head = CGRect(x: 412, y: 450, width: 200, height: 330)
        ctx.addPath(roundedRect(head, 100))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        // Holder arc, stem and base.
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(40)
        ctx.setLineCap(.round)
        ctx.addArc(center: CGPoint(x: 512, y: 560), radius: 165, startAngle: .pi * 0.02, endAngle: .pi * 0.98, clockwise: true)
        ctx.strokePath()
        ctx.move(to: CGPoint(x: 512, y: 395)); ctx.addLine(to: CGPoint(x: 512, y: 300)); ctx.strokePath()
        ctx.move(to: CGPoint(x: 410, y: 290)); ctx.addLine(to: CGPoint(x: 614, y: 290)); ctx.strokePath()
        ctx.restoreGState()
        // Grille.
        ctx.saveGState()
        ctx.addPath(roundedRect(head, 100))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xF1E3E8)], from: CGPoint(x: head.minX, y: 0), to: CGPoint(x: head.maxX, y: 0), in: ctx)
        ctx.setStrokeColor(rgb(0xE6C2CF).cgColor)
        ctx.setLineWidth(10)
        ctx.setLineCap(.round)
        for i in 0..<4 {
            let y = 690 - CGFloat(i) * 44
            ctx.move(to: CGPoint(x: 462, y: y)); ctx.addLine(to: CGPoint(x: 562, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()
        // Slash, cut out from the background colour so it reads at small sizes.
        ctx.setLineCap(.round)
        ctx.setStrokeColor(rgb(0xEC3B6A).cgColor)
        ctx.setLineWidth(84)
        ctx.move(to: CGPoint(x: 300, y: 770)); ctx.addLine(to: CGPoint(x: 724, y: 260)); ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(42)
        ctx.move(to: CGPoint(x: 300, y: 770)); ctx.addLine(to: CGPoint(x: 724, y: 260)); ctx.strokePath()
    }
}
