import AppKit
@testable import AppBundle
import XCTest

final class WorkspaceHotkeyRoutingTest: XCTestCase {
    func testUnboundKeysAndExtraModifiersPassThrough() {
        let altOne = WorkspaceHotkeyKey(code: 18, modifiers: NSEvent.ModifierFlags.option.rawValue)
        var routing = WorkspaceHotkeyRouting()
        routing.bindings = [altOne: "alt-1"]
        XCTAssertFalse(routing.keyDown(.init(code: 19, modifiers: altOne.modifiers)).consume)
        XCTAssertFalse(routing.keyDown(.init(code: 18, modifiers: altOne.modifiers | NSEvent.ModifierFlags.shift.rawValue)).consume)
        XCTAssertFalse(routing.keyUp(18))
    }

    func testShortcutRepeatsAndKeyUpRemainCapturedAfterModeChange() {
        let altOne = WorkspaceHotkeyKey(code: 18, modifiers: NSEvent.ModifierFlags.option.rawValue)
        var routing = WorkspaceHotkeyRouting()
        routing.bindings = [altOne: "alt-1"]
        XCTAssertEqual(routing.keyDown(altOne).binding, "alt-1")
        XCTAssertEqual(routing.keyDown(altOne).binding, "alt-1")
        routing.bindings = [:]
        let repeatAfterChange = routing.keyDown(.init(code: 18, modifiers: 0))
        XCTAssertTrue(repeatAfterChange.consume)
        XCTAssertNil(repeatAfterChange.binding)
        XCTAssertTrue(routing.keyUp(18))
        XCTAssertFalse(routing.keyUp(18))
        XCTAssertFalse(routing.keyDown(.init(code: 18, modifiers: 0)).consume)
    }

    func testCapsLockAndDeviceFlagsDoNotChangeShortcut() {
        let modifiers = NSEvent.ModifierFlags.option
        let plain = WorkspaceHotkeyKey(code: 18, modifiers: modifiers.rawValue)
        let extra = WorkspaceHotkeyKey(code: 18, modifiers: modifiers.union([.capsLock, .numericPad, .function]).rawValue)
        XCTAssertEqual(plain, extra)
    }

    func testRecoveryDoesNotRetainKeysWhoseReleaseMayHaveBeenMissed() {
        let altOne = WorkspaceHotkeyKey(code: 18, modifiers: NSEvent.ModifierFlags.option.rawValue)
        var routing = WorkspaceHotkeyRouting()
        routing.bindings = [altOne: "alt-1"]
        XCTAssertTrue(routing.keyDown(altOne).consume)
        routing.resetCapturedKeys()
        XCTAssertFalse(routing.keyDown(.init(code: 18, modifiers: 0)).consume)
        XCTAssertFalse(routing.keyUp(18))
        XCTAssertEqual(routing.keyDown(altOne).binding, "alt-1")
    }
}
