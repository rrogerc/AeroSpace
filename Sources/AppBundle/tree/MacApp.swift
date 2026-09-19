import AppKit
import Common

// Potential alternative implementation
// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md
// (only available since macOS 14)
final class MacApp: AbstractApp {
    /*conforms*/ let pid: Int32
    /*conforms*/ let rawAppBundleId: String?
    let appId: KnownBundleId?
    let nsApp: NSRunningApplication
    private let axApp: ThreadGuardedValue<AXUIElement>
    private let appAxSubscriptions: ThreadGuardedValue<[AxSubscription]> // keep subscriptions in memory
    private let windows: ThreadGuardedValue<[UInt32: AxWindow]> = .init([:])
    private(set) var windowsCount = 0
    var lastNativeFocusedWindowId: UInt32? = nil
    private var requests: AppRequestQueue?
    private let enhancedUserInterface: ThreadGuardedValue<EnhancedUserInterface>
    private var setFrameJobs: [UInt32: RunLoopJob] = [:]
    @MainActor private static var focusJob: RunLoopJob? = nil
    private var cachedName: String?

    /*conforms*/ var name: String? {
        if let cachedName { return cachedName }
        let name = nsApp.localizedName
        // LaunchServices name lookups can block. Cache the name for this process,
        // but retry while a newly launched app has no name yet.
        if let name, !name.isEmpty { cachedName = name }
        return name
    }
    /*conforms*/ var execPath: String? { nsApp.executableURL?.path }
    /*conforms*/ var bundlePath: String? { nsApp.bundleURL?.path }

    // todo think if it's possible to integrate this global mutable state to https://github.com/nikitabobko/AeroSpace/issues/1215
    //      and make deinitialization automatic in deinit
    @MainActor static var allAppsMap: [pid_t: MacApp] = [:]
    @MainActor private static var wipPids: [pid_t: AwaitableOneTimeBroadcastLatch] = [:]

    private init(
        _ nsApp: NSRunningApplication,
        _ axApp: AXUIElement,
        _ axSubscriptions: [AxSubscription],
        _ thread: Thread,
    ) {
        self.nsApp = nsApp
        self.axApp = .init(axApp)
        self.pid = nsApp.processIdentifier
        self.rawAppBundleId = nsApp.bundleIdentifier
        self.appId = nsApp.bundleIdentifier.flatMap { KnownBundleId.init(rawValue: $0) }
        assert(!axSubscriptions.isEmpty)
        self.appAxSubscriptions = .init(axSubscriptions)
        let enhancedUserInterface = ThreadGuardedValue(EnhancedUserInterface(
            read: { axApp.getResult(Ax.enhancedUserInterfaceAttr) },
            write: { axApp.setResult(Ax.enhancedUserInterfaceAttr, $0) },
        ))
        self.enhancedUserInterface = enhancedUserInterface
        self.requests = AppRequestQueue(thread, endFrameBatch: {
            enhancedUserInterface.threadGuarded.release()
        })
    }

    @MainActor
    @discardableResult
    static func getOrRegister(_ nsApp: NSRunningApplication) async throws -> MacApp? {
        // Don't perceive any of the lock screen windows as real windows
        // Otherwise, false positive ax notifications might trigger that lead to gcWindows
        if nsApp.bundleIdentifier == lockScreenAppBundleId { return nil }
        let pid = nsApp.processIdentifier
        // AX requests crash if you send them to yourself
        if pid == myPid { return nil }

        if let existing = allAppsMap[pid] { return existing }
        try checkCancellation()
        if let wip = wipPids[pid] {
            try await wip.await()
            return allAppsMap[pid]
        }
        let wip = AwaitableOneTimeBroadcastLatch()
        wipPids[pid] = wip

        let thread = Thread {
            $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: pid, idForDebug: nsApp.idForDebug)) {
                let axApp = AXUIElementCreateApplication(nsApp.processIdentifier)
                let handlers: HandlerToNotifKeyMapping = unsafe [
                    (refreshObs, [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]),
                ]
                let job = RunLoopJob(.cancellable)
                let subscriptions = (try? unsafe AxSubscription.bulkSubscribe(nsApp, axApp, job, handlers)) ?? []
                let isGood = !subscriptions.isEmpty
                let app = isGood ? MacApp(nsApp, axApp, subscriptions, Thread.current) : nil

                let appAxSubscriptionsThreadGuarded = app?.appAxSubscriptions
                let windowsThreadGuarded = app?.windows
                let axAppThreadGuarded = app?.axApp
                let enhancedUserInterfaceThreadGuarded = app?.enhancedUserInterface

                Task.startUnstructured { @MainActor in
                    allAppsMap[pid] = app
                    wipPids[pid] = nil
                    await wip.signalToAll()
                }
                if isGood {
                    CFRunLoopRun()

                    // Destroy AX objects in reverse order of their creation
                    enhancedUserInterfaceThreadGuarded?.threadGuarded.restoreIfNeeded()
                    enhancedUserInterfaceThreadGuarded?.destroy()
                    appAxSubscriptionsThreadGuarded?.destroy()
                    windowsThreadGuarded?.destroy()
                    axAppThreadGuarded?.destroy()
                }
            }
        }
        thread.name = "AxAppThread \(nsApp.idForDebug)"
        thread.start()

        try await wip.await()
        return allAppsMap[pid]
    }

    func closeAndUnregisterAxWindow(_ windowId: UInt32) {
        if serverArgs.isReadOnly { return }
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        _ = withWindowAsync(windowId, .cancellable) { [windows] window, job in
            guard let closeButton = window.get(Ax.closeButtonAttr) else { return }
            if AXUIElementPerformAction(closeButton.cast, kAXPressAction as CFString) == .success {
                windows.threadGuarded.removeValue(forKey: windowId)
            }
        }
    }

    func getAxSize(_ windowId: UInt32, _ cm: CancellationMode) async throws -> CGSize? {
        try await withWindow(windowId, cm) { [pid] window, job in
            getWindowServerWindow(windowId, pid: pid)?.bounds.size ?? window.get(Ax.sizeAttr)
        }
    }

    // todo merge together with detectNewWindows
    func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
        let windowId = try await requests?.run(cm) { [nsApp, axApp, windows] job in
            try axApp.threadGuarded.get(Ax.focusedWindowAttr)
                .flatMap { try windows.threadGuarded.getOrRegisterAxWindow(windowId: $0.windowId, $0.ax.cast, nsApp, job) }?
                .windowId
        }
        guard let windowId else { return nil }
        return try await MacWindow.getOrRegister(windowId: windowId, macApp: self)
    }

    @MainActor func prepareWorkspaceFocus(_ windowId: UInt32) -> WorkspaceFocusPreparation? {
        guard !serverArgs.isReadOnly, PrivateWindowFocus.isEnabled, windowsCount == 1, requests != nil else { return nil }
        MacApp.focusJob?.cancel()
        let job = RunLoopJob(.cancellable)
        MacApp.focusJob = job
        return WorkspaceFocusPreparation(pid: pid, windowId: windowId, job: job)
    }

    @MainActor func nativeFocus(_ windowId: UInt32, prepared: WorkspaceFocusPreparation? = nil) {
        if serverArgs.isReadOnly { return }
        if let prepared, prepared.pid != pid || prepared.windowId != windowId || prepared.job.isCancelled { return }
        signposter.emitEvent("nativeFocusRequested")
        if MacApp.focusJob !== prepared?.job { MacApp.focusJob?.cancel() }
        // Performance optimization. If possible avoid doing AX requests
        // (important for apps which are slow at responding even such basic AX requests. E.g. Godot)
        // Beware of the macOS bug: https://github.com/nikitabobko/AeroSpace/issues/101
        let activationOnly = (!NSScreen.screensHaveSeparateSpaces || monitorInfos.count == 1) &&
            (lastNativeFocusedWindowId == windowId || windowsCount == 1)
        guard requests != nil else { return }
        let job = prepared?.job ?? RunLoopJob(.cancellable)
        let visibility = NativeVisibilityGates.shared.get(windowId, pid: pid)
        let groupPreparation = prepared?.hasStarted == true ? prepared : nil
        let preparation = if groupPreparation == nil && (visibility != nil || NativeFocusPreparation.isEnabled) && PrivateWindowFocus.isEnabled && monitorInfos.count == 1 && windowsCount == 1 {
            NativeFocusPreparation.shared.prepare(job: job, visibility: visibility) { [pid] in
                PrivateWindowFocus.makeKeyWindow(pid: pid, windowId: windowId)
            }
        } else {
            nil as CompletableFuture<Bool>?
        }
        // A sole visible window has nothing else in its workspace to raise above.
        // Its prepared private activation already selects the key window. Avoid
        // another app round trip; other focus paths retain the window-specific raise.
        let privateRaiseRequired = visibility == nil || (preparation == nil && groupPreparation == nil) ||
            focus.windowOrNil?.windowId != windowId || focus.workspace.allLeafWindowsRecursive.count != 1
        // Keep the final raise and public fallback behind this window's queued frame.
        // Early activation is limited to one window on one monitor, with the same job.
        // Keep an existing frame batch's animation suppression through activation and
        // raise. Focus alone does not acquire suppression or perform another AX read.
        MacApp.focusJob = withWindowAsync(windowId, .cancellable, suppressAnimations: true, job: job) { [nsApp, pid] window, job in
            if let visibility, !visibility.wait(for: job) { return }
            try performNativeFocus(
                job: job,
                activationOnly: activationOnly,
                privateRaiseRequired: privateRaiseRequired,
                makeKeyWindow: { groupPreparation?.waitForResult() ?? preparation?.blockingGet() ?? PrivateWindowFocus.makeKeyWindow(pid: pid, windowId: windowId) },
                setMain: { window.set(Ax.isMainAttr, true) },
                raise: { AXUIElementPerformAction(window, kAXRaiseAction as CFString) },
                activate: { nsApp.activate(options: .activateIgnoringOtherApps) },
            )
        }
    }

    func setAxFrame(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        let visibility = NativeVisibilityGates.shared.get(windowId, pid: pid)
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable, suppressAnimations: true) { [enhancedUserInterface, pid] window, job in
            if let visibility, !visibility.wait(for: job) { return }
            // Read after preceding writes on this app's worker. Requested frames are not proof
            // that an app accepted them, and a mouse drag may have changed the actual frame.
            // Keep position-only moves on the existing AX path: an extra WindowServer read
            // can wait behind app activation and delay hiding the outgoing window.
            let update = WindowFrameUpdate(topLeft: topLeft, size: size)
                .skippingUnchangedValues(comparedTo: size == nil ? nil : getWindowServerWindow(windowId, pid: pid)?.bounds)
            if update.isEmpty { return }
            try job.checkCancellation()
            enhancedUserInterface.threadGuarded.acquireForBatch()
            try job.checkCancellation()
            try setFrame(window, update.topLeft, update.size, job)
        }
    }

    func hasPendingFrame(_ windowId: UInt32) -> Bool {
        setFrameJobs[windowId].map { !$0.isComplete } ?? false
    }

    func cancelPendingFrame(_ windowId: UInt32) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
    }

    func lastFrameJob(_ windowId: UInt32) -> RunLoopJob? { setFrameJobs[windowId] }

    func setAxFrameForTermination(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        let semaphore = DispatchSemaphore(value: 0)
        let job = withWindowAsync(windowId, .nonCancellable) { [enhancedUserInterface] window, job in
            enhancedUserInterface.threadGuarded.acquire()
            try? setFrame(window, topLeft, size, job)
            // Termination waits on this semaphore; restore the app's setting before allowing exit.
            enhancedUserInterface.threadGuarded.release()
            semaphore.signal()
        }
        switch job.isCancelled {
            case true: return
            case false: semaphore.wait()
        }
    }

    func getAxWindowsCount(_ cm: CancellationMode) async throws -> Int? {
        try await requests?.run(cm) { [axApp] job in
            axApp.threadGuarded.get(Ax.windowsAttr)?.count
        }
    }

    func getAxRect(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Rect? {
        try await withWindow(windowId, cm) { [pid] window, job in
            // Keep read-after-write ordering for floating windows and rapid workspace switches.
            if let info = getWindowServerWindow(windowId, pid: pid) { return info.rect }
            return try AppBundle.getAxRect(window: window, job: job)
        }
    }

    func getAxRectForTermination(_ windowId: UInt32) -> Rect? {
        let future = CompletableFuture<Rect?>()
        let job = withWindowAsync(windowId, .nonCancellable) { window, job in
            future.complete(try AppBundle.getAxRect(window: window, job: job))
        }
        return switch job.isCancelled {
            case true: nil
            case false: future.blockingGet()
        }
    }

    func isWindowHeuristic(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            window.isWindowHeuristic(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } == true
    }

    func getAxUiElementWindowType(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            window.getWindowType(axApp: axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } ?? .window
    }

    func isDialogHeuristic(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        try await withWindow(windowId, cm) { [appId] window, job in
            window.isDialogHeuristic(appId, windowLevel)
        } == true
    }

    func setNativeFullscreen(_ windowId: UInt32, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.isFullscreenAttr, value)
        }
    }

    func setNativeMinimized(_ windowId: UInt32, _ value: Bool) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { window, job in
            window.set(Ax.minimizedAttr, value)
        }
    }

    func dumpWindowAxInfo(windowId: UInt32, _ cm: CancellationMode) async throws -> [String: Json] {
        try await withWindow(windowId, cm) { window, job in
            dumpAxRecursive(window, .window)
        } ?? [:]
    }

    func dumpAppAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await requests?.run(cm) { [axApp] job in
            dumpAxRecursive(axApp.threadGuarded, .app)
        } ?? [:]
    }

    func getAxTitle(_ windowId: UInt32, _ cm: CancellationMode) async throws -> String? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.titleAttr)
        }
    }

    func isMacosNativeFullscreen(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.isFullscreenAttr)
        }
    }

    func isMacosNativeMinimized(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.minimizedAttr)
        }
    }

    @MainActor
    static func refreshAllAndGetAliveWindowIds(frontmostAppBundleId: String?, scope: RefreshScope = .all) async throws -> [MacApp: [UInt32]] {
        for (_, app) in MacApp.allAppsMap { // gc dead apps
            try checkCancellation()
            if app.nsApp.isTerminated {
                await app.destroy()
            }
        }
        return try await withThrowingTaskGroup(of: (pid_t, [UInt32]).self, returning: [MacApp: [UInt32]].self) { group in
            func refreshTheApp(_ nsApp: NSRunningApplication) {
                group.addTask { @Sendable @MainActor in
                    guard let app = try await MacApp.getOrRegister(nsApp) else { return (nsApp.processIdentifier, []) }
                    return (nsApp.processIdentifier, try await app.refreshAndGetAliveWindowIds(frontmostAppBundleId: frontmostAppBundleId))
                }
            }
            // Register new apps
            for nsApp in NSWorkspace.shared.runningApplications {
                try checkCancellation()
                if nsApp.activationPolicy == .regular && scope.contains(nsApp.processIdentifier) {
                    refreshTheApp(nsApp)
                }
            }
            for (_, app) in MacApp.allAppsMap {
                try checkCancellation()
                // "About this Mac" window, TouchID, and a lot of other utility windows
                // We don't monitor them actively as we do for regular apps, but if a window of one of those utility
                // apps got focused it will end up in allAppsMap
                if app.nsApp.activationPolicy != .regular && scope.contains(app.pid) {
                    refreshTheApp(app.nsApp)
                }
            }
            var result: [MacApp: [UInt32]] = [:]
            for try await (pid, windowIds) in group {
                if let app = MacApp.allAppsMap[pid] {
                    result[app] = windowIds
                }
            }
            return result
        }
    }

    private func refreshAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [UInt32] {
        if nsApp.isTerminated {
            await destroy()
            return []
        }
        guard let requests else { return [] }
        let (alive, dead) = try await requests.run(.cancellable) { [nsApp, windows, axApp] (job) -> ([UInt32], [UInt32]) in
            var alive: [UInt32: AxWindow] = windows.threadGuarded
            var dead = [UInt32: AxWindow]()
            // Reading AXWindows already resolves each returned element's window ID.
            // Reuse that validation only for the identical AX element; omitted windows
            // and replacement elements still need the existing liveness probe.
            let currentWindows = axApp.threadGuarded.get(Ax.windowsAttr) ?? []
            try job.checkCancellation()
            // Second line of defence against lock screen. See the first line of defence: closedWindowsCache
            // Second and third lines of defence are technically needed only to avoid potential flickering
            if frontmostAppBundleId != lockScreenAppBundleId {
                (alive, dead) = try alive.partition { id, existing in
                    try job.checkCancellation()
                    if currentWindows.contains(where: { windowId, element in windowId == id && CFEqual(element, existing.ax) }) { return true }
                    return existing.ax.containingWindowId() != nil
                }
            }

            for (id, window) in currentWindows {
                try job.checkCancellation()
                try alive.getOrRegisterAxWindow(windowId: id, window, nsApp, job)
            }

            windows.threadGuarded = alive
            return (Array(alive.keys), Array(dead.keys))
        }
        windowsCount = alive.count
        for windowId in dead {
            setFrameJobs.removeValue(forKey: windowId)?.cancel()
        }
        return alive
    }

    private func destroy() async {
        _ = await Task.startUnstructured { @MainActor [pid] in _ = MacApp.allAppsMap.removeValue(forKey: pid) }.result
        for (_, job) in setFrameJobs {
            job.cancel()
        }
        setFrameJobs = [:]
        requests?.runAsync(job: RunLoopJob(.nonCancellable), priority: .background) { job in CFRunLoopStop(CFRunLoopGetCurrent()) }
        requests = nil // Disallow all future job submissions
    }

    private func withWindow<T>(
        _ windowId: UInt32,
        _ cm: CancellationMode,
        _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> T?,
    ) async throws -> T? {
        try await requests?.run(cm) { [windows] job in
            guard let window = windows.threadGuarded[windowId] else { return nil }
            return try body(window.ax, job)
        }
    }

    private func withWindowAsync(
        _ windowId: UInt32,
        _ cm: CancellationMode,
        suppressAnimations: Bool = false,
        job: RunLoopJob? = nil,
        _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> (),
    ) -> RunLoopJob {
        requests?.runAsync(job: job ?? RunLoopJob(cm), suppressAnimations: suppressAnimations) { [windows] job in
            guard let window = windows.threadGuarded[windowId] else { return }
            try? body(window.ax, job)
        } ?? .cancelled
    }
}

private final class AxWindow {
    let windowId: UInt32
    let ax: AXUIElement
    // periphery:ignore
    private let axSubscriptions: [AxSubscription] // keep subscriptions in memory

    private init(windowId: UInt32, _ ax: AXUIElement, _ axSubscriptions: [AxSubscription]) {
        self.windowId = windowId
        self.ax = ax
        assert(!axSubscriptions.isEmpty)
        self.axSubscriptions = axSubscriptions
    }

    static func new(windowId: UInt32, _ ax: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        let handlers: HandlerToNotifKeyMapping = unsafe [
            (refreshObs, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
            (movedObs, [kAXMovedNotification]),
            (resizedObs, [kAXResizedNotification]),
        ]
        let subscriptions = try unsafe AxSubscription.bulkSubscribe(nsApp, ax, job, handlers, windowId: windowId)
        return !subscriptions.isEmpty ? AxWindow(windowId: windowId, ax, subscriptions) : nil
    }
}

extension [UInt32: AxWindow] {
    @discardableResult
    fileprivate mutating func getOrRegisterAxWindow(windowId id: UInt32, _ axWindow: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        if let existing = self[id] { return existing }
        // Delay new window detection if mouse is down
        // It helps with apps that allow dragging their tabs out to create new windows
        // https://github.com/nikitabobko/AeroSpace/issues/1001
        if isLeftMouseButtonDown { return nil }

        if let window = try AxWindow.new(windowId: id, axWindow, nsApp, job) {
            self[id] = window
            return window
        } else {
            return nil
        }
    }
}

private func getAxRect(window: AXUIElement, job: RunLoopJob) throws -> Rect? {
    guard let topLeftCorner = window.get(Ax.topLeftCornerAttr) else { return nil }
    try job.checkCancellation()
    guard let size = window.get(Ax.sizeAttr) else { return nil }
    return Rect(topLeftX: topLeftCorner.x, topLeftY: topLeftCorner.y, width: size.width, height: size.height)
}

private func setFrame(_ window: AXUIElement, _ topLeft: CGPoint?, _ size: CGSize?, _ job: RunLoopJob) throws {
    // Set size and then the position. The order is important https://github.com/nikitabobko/AeroSpace/issues/143
    //                                                        https://github.com/nikitabobko/AeroSpace/issues/335
    if let size { window.set(Ax.sizeAttr, size) }
    try job.checkCancellation()
    if let topLeft { window.set(Ax.topLeftCornerAttr, topLeft) } else { return }
    try job.checkCancellation()
    if let size { window.set(Ax.sizeAttr, size) }
}
