import AppKit
import Carbon.HIToolbox

struct HotkeyBinding: Equatable, Codable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    var display: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        parts.append(Self.keyName(keyCode))
        return parts.joined()
    }

    static func from(event: NSEvent) -> HotkeyBinding? {
        guard event.type == .keyDown else { return nil }
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        guard mods != 0 else { return nil }
        return HotkeyBinding(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
    }

    static func load(key: String) -> HotkeyBinding? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }

    func save(key: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear(key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_Space: "Space"
        default: "Key \(code)"
        }
    }
}

enum HotkeySlot: UInt32, CaseIterable {
    case dictation = 1
    case transformLocal = 2
    case transformCloud = 3

    var defaultsKey: String {
        switch self {
        case .dictation: "hotkey.dictation"
        case .transformLocal: "hotkey.transformLocal"
        case .transformCloud: "hotkey.transformCloud"
        }
    }
}

/// Global Carbon hotkeys. Unbound by default — the user records them in Settings.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onDictation: (() -> Void)?
    var onTransformLocal: (() -> Void)?
    var onTransformCloud: (() -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?

    func start() {
        installHandler()
        reload()
    }

    func reload() {
        unregisterAll()
        register(.dictation, HotkeyBinding.load(key: HotkeySlot.dictation.defaultsKey))
        register(.transformLocal, HotkeyBinding.load(key: HotkeySlot.transformLocal.defaultsKey))
        register(.transformCloud, HotkeyBinding.load(key: HotkeySlot.transformCloud.defaultsKey))
        NotificationCenter.default.post(name: .parrotHotkeysChanged, object: nil)
    }

    private func register(_ slot: HotkeySlot, _ binding: HotkeyBinding?) {
        guard let binding else { return }
        let hotKeyID = EventHotKeyID(signature: OSType(0x50525431), id: slot.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.carbonModifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { refs.append(ref) }
    }

    private func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs = []
    }

    private func installHandler() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { center.handle(id: hotKeyID.id) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func handle(id: UInt32) {
        switch HotkeySlot(rawValue: id) {
        case .dictation: onDictation?()
        case .transformLocal: onTransformLocal?()
        case .transformCloud: onTransformCloud?()
        case nil: break
        }
    }
}
