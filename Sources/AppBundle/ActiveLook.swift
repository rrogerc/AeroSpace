import Common
import Foundation
import os
import PrivateApi

/// macOS draws the window that has the keyboard with a darker shadow than the other windows, and it's the app of a
/// window that tells WindowServer which of the two shadows to draw. A workspace switch can focus a window only after
/// it's on screen, and an app takes a few frames to react (Zen: four or five). So the window of the next workspace
/// arrived with the light shadow, and the gaps around it blinked on every switch: dark, light, dark.
///
/// So the window that a switch is about to focus gets its active look while it's still hidden. How depends on its app
enum ActiveLook: Sendable {
    /// Another app is frontmost. The app of the window is sent the events that macOS sends on activation, without
    /// being activated: it draws the window as its key window, and the app that is really frontmost keeps the keyboard
    /// until the switch focuses the window as usual
    case events
    /// The app of the window is frontmost already: another window of it has the keyboard. The window becomes the main
    /// window of the app through AX, and AppKit goes on drawing the window that is on screen as active until the new
    /// one shows up. The closure sends the AX request
    case mainWindow(@Sendable () -> RunLoopJob)

    enum Kind: Equatable { case events, mainWindow }

    /// nil if the window looks active as it is
    static func kind(pid: pid_t, windowId: UInt32, frontmostPid: pid_t?, appWindowsCount: Int, appMainWindowId: UInt32?) -> Kind? {
        if pid != frontmostPid { return .events }
        // The frontmost app draws its main window as active already. It has no other window to draw as active,
        // or the window is the one that had the keyboard last (e.g. on the way back from an empty workspace).
        // Then there's nothing to ask the app, and it may take long to answer for a window that isn't on screen
        return appWindowsCount <= 1 || appMainWindowId == windowId ? nil : .mainWindow
    }
}

/// The window that a workspace switch reveals, and focuses after that
final class RevealedFocus: Sendable {
    let windowId: UInt32
    let pid: pid_t
    let look: ActiveLook
    private let eventsSent = OSAllocatedUnfairLock(initialState: false)

    init(windowId: UInt32, pid: pid_t, look: ActiveLook) {
        self.windowId = windowId
        self.pid = pid
        self.look = look
    }

    /// The app was told that it's active (`ActiveLook.events`)
    var looksActive: Bool {
        get { eventsSent.withLock { $0 } }
        set { eventsSent.withLock { $0 = newValue } }
    }
}

/// The app that was told that it's active before its window was revealed (`ActiveLook.events`). macOS activates it
/// for real right after the switch. But if it doesn't (a newer command took the focus elsewhere, or the window wasn't
/// focused after all), the app would go on drawing a key window while another app has the keyboard. So it's told
/// that it's inactive again, unless it has become the frontmost app meanwhile
@MainActor
final class ActiveLookingApp {
    static let shared = ActiveLookingApp()

    private var app: (pid: pid_t, windowId: UInt32)?
    private var generation: UInt64 = 0
    private let frontmostPid: @MainActor () -> pid_t?
    private let lookInactive: @MainActor (pid_t, UInt32) -> ()
    private let later: @MainActor (@escaping @MainActor () -> ()) -> ()

    init(
        frontmostPid: @escaping @MainActor () -> pid_t? = { AppBundle.frontmostPid },
        lookInactive: @escaping @MainActor (pid_t, UInt32) -> () = { pid, windowId in _ = AeroSpaceSetAppLooksActive(pid, windowId, false) },
        // Activation takes a few frames. An app that isn't frontmost after a second isn't going to be
        later: @escaping @MainActor (@escaping @MainActor () -> ()) -> () = { check in
            Task.startUnstructured { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                check()
            }
        },
    ) {
        self.frontmostPid = frontmostPid
        self.lookInactive = lookInactive
        self.later = later
    }

    /// The app is about to be told that it's active. The returned token is for `wasNotTold`
    func willLookActive(pid: pid_t, windowId: UInt32) -> UInt64 {
        focusGoes(to: pid)
        generation &+= 1
        app = (pid, windowId)
        let generation = generation
        later { [self] in
            if generation == self.generation { settle() }
        }
        return generation
    }

    /// The window wasn't revealed after all, so its app wasn't told anything
    func wasNotTold(_ token: UInt64) {
        if token == generation { app = nil }
    }

    /// Native focus is requested for a window of `pid`, or `pid` is about to look active
    func focusGoes(to pid: pid_t) {
        if let app, app.pid != pid { settle() }
    }

    /// macOS has activated the app, so its look is true. From now on, macOS tells the app when it's inactive
    func frontmostAppIs(_ pid: pid_t?) {
        if let app, app.pid == pid { self.app = nil }
    }

    private func settle() {
        guard let app else { return }
        self.app = nil
        if frontmostPid() != app.pid { lookInactive(app.pid, app.windowId) }
    }
}
