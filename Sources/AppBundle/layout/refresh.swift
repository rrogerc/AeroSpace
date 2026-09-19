import AppKit
import Common

@MainActor
private var activeRefreshTask: Task<(), any Error>? = nil

private struct RefreshRequest {
    var scope: RefreshScope
    var event: RefreshSessionEvent
    var preLayout: Bool
}

@MainActor private var pendingRefresh: RefreshRequest?
@MainActor private var runningRefresh: RefreshRequest?
@MainActor private var refreshGeneration: UInt64 = 0
@MainActor private var lightSessions = 0
@MainActor private var pendingNativeVisibilityRecovery = false

@MainActor
private func enqueueRefresh(_ request: RefreshRequest) {
    if let pending = pendingRefresh {
        pendingRefresh = RefreshRequest(scope: pending.scope.union(request.scope), event: request.event, preLayout: pending.preLayout || request.preLayout)
    } else {
        pendingRefresh = request
    }
}

@MainActor
private func cancelCompleteRefresh() {
    if let runningRefresh { enqueueRefresh(runningRefresh) }
    runningRefresh = nil
    refreshGeneration &+= 1
    activeRefreshTask?.cancel()
    activeRefreshTask = nil
}

@MainActor
private func startPendingRefresh() {
    guard lightSessions == 0 else { return }
    if pendingNativeVisibilityRecovery {
        pendingNativeVisibilityRecovery = false
        Task.startUnstructured { @MainActor in await recoverNativeWorkspaceVisibility() }
        return
    }
    guard activeRefreshTask == nil, pendingRefresh != nil else { return }
    let generation = refreshGeneration
    activeRefreshTask = Task.startUnstructured { @MainActor in
        // Coalesce a notification burst without postponing indefinitely on every event.
        try await Task.sleep(for: .milliseconds(30))
        try checkCancellation()
        guard generation == refreshGeneration, let request = pendingRefresh else { return }
        pendingRefresh = nil
        runningRefresh = request
        await $appRequestPriority.withValue(.background) {
            await runHeavyCompleteRefreshSession(
                request.event,
                assumeCancellable: true,
                optimisticallyPreLayoutWorkspaces: request.preLayout,
                scope: request.scope,
            )
        }
        guard generation == refreshGeneration else { return }
        runningRefresh = nil
        activeRefreshTask = nil
        startPendingRefresh()
    }
}

@MainActor
func scheduleCancellableCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    optimisticallyPreLayoutWorkspaces: Bool = false,
    scope: RefreshScope = .all,
) {
    // Keep the interrupted scope: an event from app B must not lose unfinished discovery of app A.
    if runningRefresh != nil { cancelCompleteRefresh() }
    enqueueRefresh(RefreshRequest(scope: scope, event: event, preLayout: optimisticallyPreLayoutWorkspaces))
    startPendingRefresh()
}

@MainActor
func runHeavyCompleteRefreshSession(
    _ event: RefreshSessionEvent,
    assumeCancellable: Bool,
    layoutWorkspaces shouldLayoutWorkspaces: Bool = true,
    optimisticallyPreLayoutWorkspaces: Bool = false,
    scope: RefreshScope = .all,
) async {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    if !TrayMenuModel.shared.isEnabled { return }
    let res = await Result {
        try await $refreshSessionEvent.withValue(event) {
            let focusToken = NativeFocusRefreshToken()
            let nativeFocused = try await getNativeFocusedWindow(.cancellable)
            if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
            try checkCancellation()
            guard focusToken.isCurrent else { return }
            updateFocusCache(nativeFocused)

            if shouldLayoutWorkspaces && optimisticallyPreLayoutWorkspaces { try await layoutWorkspaces() }

            await refreshModel_nonCancellable()
            try await refresh(scope)
            gcMonitors()

            updateTrayText()
            SecureInputPanel.shared.refresh()
            try await normalizeLayoutReason(scope: scope)
            if shouldLayoutWorkspaces { try await layoutWorkspaces() }
        }
    }
    switch res {
        case .success(()): break
        case .failure(let err as CancellationError): check(assumeCancellable, "Non cancellable refresh session was canceled: \(err) (\(type(of: err)))")
        case .failure(let err): die("Illegal error: \(err)")
    }
}

@MainActor
func runLightSession<T>(
    _ event: RefreshSessionEvent,
    _: RunSessionGuard,
    preferCachedFocus: Bool = false,
    synchronizeNativeFocus: Bool = true,
    forceNativeFocus: Bool = false,
    deferLayout: @MainActor () -> Bool = { false },
    body: @MainActor () async throws -> T,
) async throws -> T {
    let state = signposter.beginInterval(#function, "event: \(event) axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken?.idForDebug)")
    defer { signposter.endInterval(#function, state) }
    cancelCompleteRefresh() // Give priority to commands, preserving unfinished discovery.
    lightSessions += 1
    defer {
        lightSessions -= 1
        startPendingRefresh()
    }
    return try await $refreshSessionEvent.withValue(event) {
        if synchronizeNativeFocus {
            let focusToken = NativeFocusRefreshToken()
            let nativeFocused = try await getNativeFocusedWindow(.cancellable, preferCached: preferCachedFocus)
            if let nativeFocused { try await debugWindowsIfRecording(nativeFocused, .cancellable) }
            try checkCancellation()
            if focusToken.isCurrent { updateFocusCache(nativeFocused) }
        }
        let focusBefore = focus.windowOrNil
        let workspaceBefore = focus.workspace

        await refreshModel_nonCancellable()
        let result = try await body()
        await refreshModel_nonCancellable()

        let focusAfter = focus.windowOrNil
        let layoutFocusToken = NativeFocusRefreshToken()

        // Submit window work before refreshing auxiliary UI. Still update it when
        // layout is cancelled so the tray follows the current logical focus.
        defer {
            updateTrayText()
            SecureInputPanel.shared.refresh()
        }
        // A queued workspace burst preserves commands/callbacks in order, but
        // only its final destination needs window moves and native activation.
        let layoutDeferred = deferLayout()
        let earlyFocus = !layoutDeferred && !event.isFocusFollowsMouse && workspaceBefore != focus.workspace && focusBefore != focusAfter
            ? NativeWorkspaceVisibility.shared.prepareFocus(focusAfter) : nil
        var handedOff = false
        defer { if !handedOff { earlyFocus?.job.cancel() } }
        if !event.isFocusFollowsMouse && !layoutDeferred { try await layoutWorkspaces(earlyFocus: earlyFocus) }
        if !layoutDeferred && (focusBefore != focusAfter || forceNativeFocus) && layoutFocusToken.isCurrent {
            if let earlyFocus, let window = focusAfter as? MacWindow {
                window.macAppUnsafe.nativeFocus(window.windowId, prepared: earlyFocus)
                handedOff = true
            } else {
                focusAfter?.nativeFocus() // syncFocusToMacOs
            }
        }
        if !event.isFocusFollowsMouse {
            let scope: RefreshScope = preferCachedFocus
                ? .apps(Set((workspaceBefore.allLeafWindowsRecursive + focus.workspace.allLeafWindowsRecursive).map { $0.app.pid }))
                : .all
            scheduleCancellableCompleteRefreshSession(event, scope: scope)
        }
        return result
    }
}

struct RunSessionGuard: Sendable {
    @MainActor
    static var isServerEnabled: RunSessionGuard? { TrayMenuModel.shared.isEnabled ? forceRun : nil }
    @MainActor
    static func isServerEnabled(orIsEnableCommand command: (any Command)?) -> RunSessionGuard? {
        command is EnableCommand ? .forceRun : .isServerEnabled
    }
    @MainActor
    static func checkServerIsEnabledOrDie(
        file: StaticString = #fileID,
        line: Int = #line,
        column: Int = #column,
        function: String = #function,
    ) -> RunSessionGuard {
        .isServerEnabled ?? dieT("server is disabled", file: file, line: line, column: column, function: function)
    }
    static let forceRun = RunSessionGuard()
    private init() {}
}

@MainActor
func refreshModel_nonCancellable() async {
    if refreshSessionEvent?.isFocusFollowsMouse == true {
        await checkOnFocusChangedCallbacks_nonCancellable()
    } else {
        Workspace.garbageCollectUnusedWorkspaces()
        await checkOnFocusChangedCallbacks_nonCancellable()
        normalizeContainers()
    }
}

@MainActor
private func refresh(_ scope: RefreshScope) async throws {
    // Garbage collect terminated apps and windows before working with all windows
    let mapping = try await MacApp.refreshAllAndGetAliveWindowIds(frontmostAppBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, scope: scope)
    let aliveWindowIds = mapping.values.flatMap(id).toSet()

    for window in MacWindow.allWindows {
        if scope.shouldCollectWindow(pid: window.macApp.pid, appTerminated: window.macApp.nsApp.isTerminated, aliveIds: aliveWindowIds, windowId: window.windowId) {
            window.garbageCollect(skipClosedWindowsCache: false)
        }
    }
    for (app, windowIds) in mapping {
        for windowId in windowIds {
            try await MacWindow.getOrRegister(windowId: windowId, macApp: app)
        }
    }

    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.garbageCollectUnusedWorkspaces()
}

func refreshObs(_: AXObserver, _: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let scope = RefreshScope.app(axTaskLocalAppThreadToken?.pid)
    Task.startUnstructured { @MainActor in
        if !TrayMenuModel.shared.isEnabled { return }
        scheduleCancellableCompleteRefreshSession(.ax(notif), scope: scope)
    }
}

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

/// Recovery must preserve the latest logical destination. Reading native focus
/// first can adopt the source window whose activation never completed.
@MainActor
func restoreFocusAfterNativeWorkspaceRecovery(layout: @MainActor () async throws -> Void) async throws {
    let token = NativeFocusRefreshToken()
    try await layout()
    try checkCancellation()
    if token.isCurrent, TrayMenuModel.shared.isEnabled { focus.windowOrNil?.nativeFocus() }
}

@MainActor
func recoverNativeWorkspaceVisibility() async {
    // Synchronous recovery may finish inside a command's layout. Let that
    // command finish before repairing; otherwise a nested layout could cancel
    // the very command which requested recovery.
    guard lightSessions == 0 else {
        pendingNativeVisibilityRecovery = true
        return
    }
    cancelCompleteRefresh()
    lightSessions += 1
    defer {
        lightSessions -= 1
        startPendingRefresh()
    }
    let event = RefreshSessionEvent.globalObserver("nativeVisibilityRecovered")
    do {
        try await $refreshSessionEvent.withValue(event) {
            try await restoreFocusAfterNativeWorkspaceRecovery { try await layoutWorkspaces() }
            updateTrayText()
            SecureInputPanel.shared.refresh()
            scheduleCancellableCompleteRefreshSession(event)
        }
    } catch is CancellationError {
        // A newer command will lay out and focus its own destination.
    } catch {
        die("Illegal recovery error: \(error)")
    }
}

@MainActor
private func layoutWorkspaces(earlyFocus: WorkspaceFocusPreparation? = nil) async throws {
    try checkCancellation()
    if !TrayMenuModel.shared.isEnabled {
        guard await NativeWorkspaceVisibility.shared.stop() else { return }
        for workspace in Workspace.all {
            workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
            try await workspace.layoutWorkspace() // Unhide tiling windows from corner
        }
        return
    }
    switch try await NativeWorkspaceVisibility.shared.apply(earlyFocus: earlyFocus) {
        case .native:
            for monitor in monitorInfos {
                let workspace = monitor.activeWorkspace
                workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() }
                try await workspace.layoutWorkspace()
            }
            return
        case .recovering:
            // AX focus or geometry writes while a window is still parked could
            // activate that native desktop. The worker retries recovery itself.
            return
        case .offscreen: break
    }
    let monitors = monitorInfos
    var monitorToOptimalHideCorner: [CGPoint: OptimalHideCorner] = [:]
    for monitor in monitors {
        let xOff = monitor.width * 0.1
        let yOff = monitor.height * 0.1
        // brc = bottomRightCorner
        let brc1 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: -yOff)
        let brc2 = monitor.rect.bottomRightCorner + CGPoint(x: -xOff, y: 2)
        let brc3 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: 2)

        // blc = bottomLeftCorner
        let blc1 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: -yOff)
        let blc2 = monitor.rect.bottomLeftCorner + CGPoint(x: xOff, y: 2)
        let blc3 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: 2)

        func contains(_ monitor: MonitorInfo, _ point: CGPoint) -> Int { monitor.rect.contains(point) ? 1 : 0 }
        let important = 10

        let corner: OptimalHideCorner =
            monitors.sumOfInt { contains($0, blc1) + contains($0, blc2) + important * contains($0, blc3) } <
            monitors.sumOfInt { contains($0, brc1) + contains($0, brc2) + important * contains($0, brc3) }
            ? .bottomLeftCorner
            : .bottomRightCorner
        monitorToOptimalHideCorner[monitor.rect.topLeftCorner] = corner
    }

    // to reduce flicker, first unhide visible workspaces, then hide invisible ones
    for monitor in monitors {
        let workspace = monitor.activeWorkspace
        workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
        try await workspace.layoutWorkspace()
    }
    var alreadyHidden: [(MacWindow, OptimalHideCorner)] = []
    for workspace in Workspace.all where !workspace.isVisible {
        let corner = monitorToOptimalHideCorner[workspace.workspaceMonitor.rect.topLeftCorner] ?? .bottomRightCorner
        for window in workspace.allLeafWindowsRecursive {
            let window = window as! MacWindow // todo as!
            if window.isHiddenInCorner {
                alreadyHidden.append((window, corner))
            } else {
                // Start the outgoing app's AX work before querying windows that
                // were already hidden. Busy apps can take a frame to respond.
                try await window.hideInCorner(corner)
            }
        }
    }
    let hiddenFrames = observeHiddenWindowFrames(alreadyHidden.map(\.0))
    for (window, corner) in alreadyHidden {
        try await window.hideInCorner(corner, observation: hiddenFrames[window.windowId])
    }
}

@MainActor
private func normalizeContainers() {
    // Can't do it only for visible workspace because most of the commands support --window-id and --workspace flags
    for workspace in Workspace.all {
        workspace.normalizeContainers()
    }
}
