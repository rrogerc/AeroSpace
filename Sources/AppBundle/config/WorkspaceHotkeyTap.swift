import AppKit
import Common

/// An early path for workspace shortcuts. Carbon registrations stay active
/// as a fallback if the tap is unavailable or macOS disables it.
@MainActor final class WorkspaceHotkeyTap {
    static let shared = WorkspaceHotkeyTap()
    private static let isEnabled = ProcessInfo.processInfo.environment["AEROSPACE_WORKSPACE_HOTKEY_TAP"] != "0"
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var routing = WorkspaceHotkeyRouting()

    private init() {}

    func updateBindings(_ bindings: [HotkeyBinding]) {
        guard Self.isEnabled, !isUnitTest else { return }
        routing.bindings = Dictionary(uniqueKeysWithValues: bindings.compactMap { binding in
            guard case .cmd(let command) = binding.commands, command.isWorkspaceSwitch else { return nil }
            let key = WorkspaceHotkeyKey(code: Int64(binding.keyCode.carbonKeyCode), modifiers: binding.modifiers.rawValue)
            return (key, binding.descriptionWithKeyCode)
        })
        guard port == nil, !routing.bindings.isEmpty else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        guard let port = unsafe CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                let consume = MainActor.assumeIsolated { WorkspaceHotkeyTap.shared.handle(type, event) }
                return unsafe consume ? nil : .passUnretained(event)
            },
            userInfo: nil,
        ), let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return }
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            routing.resetCapturedKeys()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            return routing.keyUp(code)
        }
        guard type == .keyDown else { return false }
        let result = routing.keyDown(WorkspaceHotkeyKey(code: code, modifiers: UInt(event.flags.rawValue)))
        if let binding = result.binding { triggerHotkeyBinding(binding) }
        // Consuming the event also prevents its Carbon registration from firing.
        return result.consume
    }
}

struct WorkspaceHotkeyKey: Hashable {
    let code: Int64
    let modifiers: UInt

    init(code: Int64, modifiers: UInt) {
        self.code = code
        // Match Carbon's command/control/option/shift semantics; Caps Lock and
        // device-specific flags do not change the configured shortcut.
        self.modifiers = modifiers & NSEvent.ModifierFlags([.command, .control, .option, .shift]).rawValue
    }
}

struct WorkspaceHotkeyRouting {
    var bindings: [WorkspaceHotkeyKey: String] = [:]
    private var capturedKeys: Set<Int64> = []

    mutating func keyDown(_ key: WorkspaceHotkeyKey) -> (consume: Bool, binding: String?) {
        if let binding = bindings[key] {
            capturedKeys.insert(key.code)
            return (true, binding)
        }
        // A binding/mode may change while the key is held. Do not leak repeats
        // or an unmatched key-up into the destination application.
        return (capturedKeys.contains(key.code), nil)
    }

    mutating func keyUp(_ code: Int64) -> Bool { capturedKeys.remove(code) != nil }

    mutating func resetCapturedKeys() { capturedKeys.removeAll() }
}
