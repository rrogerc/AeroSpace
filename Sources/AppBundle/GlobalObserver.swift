import AppKit
import Common

enum GlobalObserver {
    @MainActor private static var runningApplicationsObservation: NSKeyValueObservation? = nil

    private static func onNotif(_ notification: Notification) {
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        let scope = RefreshScope.app((notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier)
        Task.startUnstructured { @MainActor in
            if !TrayMenuModel.shared.isEnabled { return }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true, scope: scope)
            } else {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName), scope: scope)
            }
        }
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       w.macAppUnsafe.nsApp.isHidden,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
                    {
                        // Force focus
                        _ = w.focusWindow()
                        w.nativeFocus()
                    }
                    for app in MacApp.allAppsMap.values {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    @MainActor
    static func initObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp)
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif)
        // Some apps (e.g. Clock) quit without didTerminateApplicationNotification, but they still leave runningApplications.
        // Otherwise, their dead windows stay in the tree until something else refreshes
        runningApplicationsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { _, change in
            let stillRunning = Set((change.newValue ?? []).map(\.processIdentifier))
            let quit = Set((change.oldValue ?? []).filter { $0.bundleIdentifier != lockScreenAppBundleId }.map(\.processIdentifier))
                .subtracting(stillRunning)
            if quit.isEmpty { return }
            Task.startUnstructured { @MainActor in
                if !TrayMenuModel.shared.isEnabled { return }
                scheduleCancellableCompleteRefreshSession(.globalObserver("runningApplicationsRemoved"), scope: .apps(quit))
            }
        }

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            // todo reduce number of refreshSession in the callback
            //  resetManipulatedWithMouseIfPossible might call its own refreshSession
            //  The end of the callback calls refreshSession
            Task.startUnstructured { @MainActor in
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                try await resetManipulatedWithMouseIfPossible()
                let mouseLocation = mouseLocation
                let clickedMonitor = mouseLocation.monitorApproximation
                switch true {
                    // Detect clicks on desktop of different monitors
                    case clickedMonitor.visibleRect.contains(mouseLocation) && clickedMonitor.activeWorkspace != focus.workspace:
                        _ = try await runLightSession(.globalObserverLeftMouseUp, token) {
                            clickedMonitor.activeWorkspace.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        scheduleCancellableCompleteRefreshSession(.globalObserverLeftMouseUp)
                }
            }
        }
    }
}
