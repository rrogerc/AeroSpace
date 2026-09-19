import AppKit
import Common
import Foundation
import HotKey

@MainActor private var hotkeys: [String: HotKey] = [:]

@MainActor func resetHotKeys() {
    // Explicitly unregister all hotkeys. We cannot always rely on destruction of the HotKey object to trigger
    // unregistration because we might be running inside a hotkey handler that is keeping its HotKey object alive.
    for (_, key) in hotkeys {
        key.isEnabled = false
    }
    hotkeys = [:]
    WorkspaceHotkeyTap.shared.updateBindings([])
}

extension HotKey {
    var isEnabled: Bool {
        get { !isPaused }
        set {
            if isEnabled != newValue {
                isPaused = !newValue
            }
        }
    }
}

@MainActor var activeMode: String? = mainModeId

@MainActor private let hotkeyBindingQueue: HotkeyBindingQueue = HotkeyBindingQueue { id, followsWorkspaceSwitch in
    guard let mode = activeMode, let binding = config.modes[mode]?.bindings[id] else { return false }
    broadcastEvent(.bindingTriggered(mode: mode, binding: binding.descriptionWithKeyNotation))
    let commands = binding.commands
    let isWorkspaceSwitch: Bool = if case .cmd(let command) = commands { command.isWorkspaceSwitch } else { false }
    do {
        try await runLightSession(
            .hotkeyBinding,
            .checkServerIsEnabledOrDie(),
            preferCachedFocus: isWorkspaceSwitch,
            synchronizeNativeFocus: !(isWorkspaceSwitch && followsWorkspaceSwitch),
            forceNativeFocus: isWorkspaceSwitch && followsWorkspaceSwitch,
            deferLayout: {
                guard isWorkspaceSwitch, let next = hotkeyBindingQueue.next, let activeMode,
                      case .cmd(let command)? = config.modes[activeMode]?.bindings[next]?.commands
                else { return false }
                return command.isWorkspaceSwitch
            },
        ) {
            _ = await commands.run(.defaultEnv, .emptyStdin)
        }
        return isWorkspaceSwitch
    } catch { return false }
}

@MainActor func triggerHotkeyBinding(_ id: String) {
    signposter.emitEvent("hotkeyReceived", "binding: \(id, privacy: .public)")
    hotkeyBindingQueue.enqueue(id)
}

/// Preserve input order across asynchronous AX reads. Consecutive workspace
/// shortcuts in the same burst use the preceding command's logical destination;
/// native activation can still be catching up. Every command runs, including
/// relative switches, back-and-forth and mode changes.
@MainActor final class HotkeyBindingQueue {
    private var pending: [String] = []
    var next: String? { pending.first }
    private var running = false
    private let run: @MainActor (String, Bool) async -> Bool

    init(run: @escaping @MainActor (String, Bool) async -> Bool) { self.run = run }

    func enqueue(_ id: String) {
        pending.append(id)
        guard !running else { return }
        running = true
        Task.startUnstructured { [self] in
            var followsWorkspaceSwitch = false
            while !pending.isEmpty {
                followsWorkspaceSwitch = await run(pending.removeFirst(), followsWorkspaceSwitch)
            }
            running = false
        }
    }
}

@MainActor func activateMode_nonCancellable(_ targetMode: String?) async {
    let targetBindings = targetMode.flatMap { config.modes[$0] }?.bindings ?? [:]
    for binding in targetBindings.values where !hotkeys.keys.contains(binding.descriptionWithKeyCode) {
        hotkeys[binding.descriptionWithKeyCode] = HotKey(key: binding.keyCode, modifiers: binding.modifiers, keyDownHandler: {
            triggerHotkeyBinding(binding.descriptionWithKeyCode)
        })
    }
    for (binding, key) in hotkeys {
        key.isEnabled = targetBindings.keys.contains(binding)
    }
    let oldMode = activeMode
    activeMode = targetMode
    WorkspaceHotkeyTap.shared.updateBindings(Array(targetBindings.values))
    if oldMode != targetMode {
        broadcastEvent(.modeChanged(mode: targetMode))
        _ = await config.onModeChanged.run(.defaultEnv, .emptyStdin)
    }
}

struct HotkeyBinding: Equatable, Sendable {
    let modifiers: NSEvent.ModifierFlags
    let keyCode: Key
    let commands: Shell<any Command>
    let descriptionWithKeyCode: String
    let descriptionWithKeyNotation: String

    init(_ modifiers: NSEvent.ModifierFlags, _ keyCode: Key, _ commands: Shell<any Command>, descriptionWithKeyNotation: String) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.commands = commands
        self.descriptionWithKeyCode = modifiers.isEmpty
            ? keyCode.toString()
            : modifiers.toString() + "-" + keyCode.toString()
        self.descriptionWithKeyNotation = descriptionWithKeyNotation
    }

    static func == (lhs: HotkeyBinding, rhs: HotkeyBinding) -> Bool {
        lhs.modifiers == rhs.modifiers &&
            lhs.keyCode == rhs.keyCode &&
            lhs.descriptionWithKeyCode == rhs.descriptionWithKeyCode &&
            lhs.commands.strictEquals(rhs.commands)
    }
}

func parseBindings(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext, _ mapping: [String: Key]) -> [String: HotkeyBinding] {
    guard let rawTable = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return [:]
    }
    var result: [String: HotkeyBinding] = [:]
    for (binding, rawCommand): (String, OrderedJson) in rawTable {
        let backtrace = backtrace + .key(binding)
        let binding = parseBinding(binding, backtrace, mapping)
            .map { modifiers, key -> HotkeyBinding in
                let commands = parseShellOfCommandsForConfig(rawCommand, backtrace, &c)
                return HotkeyBinding(modifiers, key, commands, descriptionWithKeyNotation: binding)
            }
            .getOrNil(appendErrorTo: &c.errors)
        if let binding {
            if result.keys.contains(binding.descriptionWithKeyCode) {
                c.errors.append(.init(backtrace, "'\(binding.descriptionWithKeyCode)' Binding redeclaration"))
            }
            result[binding.descriptionWithKeyCode] = binding
        }
    }
    return result
}

func parseBinding(_ raw: String, _ backtrace: ConfigBacktrace, _ mapping: [String: Key]) -> ResOrConfigParseDiagnostic<(NSEvent.ModifierFlags, Key)> {
    let rawKeys = raw.split(separator: "-")
    let modifiers: ResOrConfigParseDiagnostic<NSEvent.ModifierFlags> = rawKeys.dropLast()
        .mapAllOrFailure {
            modifiersMap[String($0)].toResult(.init(backtrace, "Can't parse modifiers in '\(raw)' binding"))
        }
        .map { NSEvent.ModifierFlags($0) }
    let key: ResOrConfigParseDiagnostic<Key> = rawKeys.last.flatMap { mapping[String($0)] }
        .toResult(.init(backtrace, "Can't parse the key in '\(raw)' binding"))
    return modifiers.flatMap { modifiers -> ResOrConfigParseDiagnostic<(NSEvent.ModifierFlags, Key)> in
        key.flatMap { key -> ResOrConfigParseDiagnostic<(NSEvent.ModifierFlags, Key)> in
            .success((modifiers, key))
        }
    }
}
