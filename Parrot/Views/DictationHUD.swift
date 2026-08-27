import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ProcessingHUD: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink)
                .padding(.horizontal, Theme.Metrics.radius * 2)
                .padding(.vertical, Theme.Metrics.radius)
                .background(Theme.Colors.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.Colors.line))
                .padding(.top, Theme.Metrics.radius * 2)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Wispr-style orb: mic only. Shortcuts and transforms live in the app.
struct ProcessingBarView: View {
    @Environment(RecordingManager.self) private var recordingManager

    private var listening: Bool {
        recordingManager.dictation.phase == .listening
    }

    private var status: String {
        let dictation = recordingManager.dictation.phase.hud
        if !dictation.isEmpty { return dictation }
        return recordingManager.transforms.phase.hud
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recordingManager.dictation.toggle()
            } label: {
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(listening ? Theme.Colors.stop : Theme.Colors.ink)
            }
            .buttonStyle(.plain)
            .help("Dictate")

            if !status.isEmpty {
                Text(status)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Colors.line))
        .contextMenu {
            HotkeyChip(slot: .dictation)
            HotkeyChip(slot: .transformLocal)
            HotkeyChip(slot: .transformCloud)
            Button("Hide bar") { ProcessingBarController.shared.setVisible(false) }
        }
    }
}

struct HotkeyRecorderRow: View {
    let title: String
    let slot: HotkeySlot

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            HotkeyChip(slot: slot)
        }
    }
}

struct HotkeyChip: View {
    let slot: HotkeySlot
    @State private var listening = false
    @State private var localMonitor: Any?
    @State private var globalMonitor: Any?

    var body: some View {
        Button(listening ? "Press keys…" : (HotkeyBinding.load(key: slot.defaultsKey)?.display ?? label)) {
            startListening()
        }
        .buttonStyle(.plain)
        .font(Theme.Typography.mono(11))
        .foregroundStyle(listening ? Theme.Colors.accent : Theme.Colors.ink2)
        .help("Click, then hold a modifier and a key. Escape cancels. Right-click clears.")
        .onExitCommand { stopListening() }
        .contextMenu {
            Button("Clear shortcut") {
                HotkeyBinding.clear(key: slot.defaultsKey)
                HotkeyCenter.shared.reload()
            }
        }
    }

    private var label: String {
        switch slot {
        case .dictation: "Dictation key"
        case .transformLocal: "Local key"
        case .transformCloud: "Cloud key"
        }
    }

    private func startListening() {
        guard !listening else { return }
        listening = true
        let handle: (NSEvent) -> Void = { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopListening()
                return
            }
            if let binding = HotkeyBinding.from(event: event) {
                binding.save(key: slot.defaultsKey)
                HotkeyCenter.shared.reload()
                stopListening()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
        }
    }

    private func stopListening() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        listening = false
    }
}

@MainActor
final class ProcessingBarController {
    static let shared = ProcessingBarController()

    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?

    func attach(manager: RecordingManager) {
        if panel == nil {
            let view = AnyView(ProcessingBarView().environment(manager))
            let host = NSHostingView(rootView: view)
            host.sizingOptions = [.intrinsicContentSize]
            self.host = host

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 120, height: 32),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isMovableByWindowBackground = true
            panel.contentView = host
            self.panel = panel
        }
        syncVisibility()
    }

    func setVisible(_ show: Bool) {
        UserDefaults.standard.set(show, forKey: FeatureProcessing.showBarKey)
        syncVisibility()
    }

    func syncVisibility() {
        let show = UserDefaults.standard.object(forKey: FeatureProcessing.showBarKey) as? Bool ?? true
        guard let panel else { return }
        if show {
            panel.contentView?.layoutSubtreeIfNeeded()
            let size = host?.fittingSize ?? NSSize(width: 72, height: 28)
            panel.setContentSize(NSSize(width: max(size.width, 56), height: max(size.height, 28)))
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                let x = visible.midX - panel.frame.width / 2
                let y = visible.minY + 12
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
}
