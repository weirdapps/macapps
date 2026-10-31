import AppKit
import Carbon.HIToolbox
import Combine
import AudioToolbox
import CoreAudio
import Kit
import SwiftUI

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

    /// Input volume saved before muting, for devices without a mute control.
    private var savedVolume: [AudioDeviceID: Float32] = [:]
    private var timer: Timer?

    init() {
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
        } else if wanted {
            savedVolume[device] = Microphone.volume(device) ?? 1
            Microphone.setVolume(device, 0)
        } else {
            Microphone.setVolume(device, max(savedVolume[device] ?? 1, 0.05))
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
                    Text("Toggle from anywhere").font(.system(size: 11)).foregroundStyle(.tertiary)
                    KeyCap("⌥⌘M")
                    Text("or right-click the icon").font(.system(size: 11)).foregroundStyle(.tertiary)
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
