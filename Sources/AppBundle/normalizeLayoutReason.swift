@MainActor
func normalizeLayoutReason(scope: RefreshScope = .all) async throws {
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive.filter { scope.contains($0.app.pid) }
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self).filter { scope.contains($0.app.pid) })
    try await validateStillPopups(scope: scope)
}

@MainActor
private func validateStillPopups(scope: RefreshScope) async throws {
    for node in macosPopupWindowsContainer.children {
        let popup = (node as! MacWindow)
        if !scope.contains(popup.macApp.pid) { continue }
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.isWindowHeuristic(windowLevel, .cancellable) {
            try await popup.relayoutWindow(on: focus.workspace, .cancellable)
            await tryOnWindowDetected(popup)
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window]) async throws {
    for window in windows {
        let workspace = window.nodeWorkspace ?? window.foreignNativeDesktopWorkspaceName.map(Workspace.get(byName:)) ?? workspace
        let isMacosFullscreen = try await window.isMacosFullscreen(.cancellable)
        let isMacosMinimized = try await (!isMacosFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized(.cancellable) }
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.isMacosAppHidden
        // An unknown membership is not evidence that a sidelined window returned.
        let isOnForeignDesktop = window.isOnForeignNativeDesktop ||
            (window.foreignNativeDesktopWorkspaceName != nil && !window.canReturnFromForeignNativeDesktop)
        let wasFocused = focus.windowOrNil == window
        if isOnForeignDesktop { window.foreignNativeDesktopWorkspaceName = workspace.name }
        let prevParentKind: NonLeafTreeNodeKind
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
                prevParentKind = parent.kind
            case .macos(let kind), .foreignNativeDesktop(let kind):
                prevParentKind = kind
        }
        let (parent, reason): (NonLeafTreeNodeObject?, LayoutReason) = switch true {
            case isMacosFullscreen:
                (workspace.macOsNativeFullscreenWindowsContainer, .macos(prevParentKind: prevParentKind))
            case isMacosMinimized:
                (macosMinimizedWindowsContainer, .macos(prevParentKind: prevParentKind))
            case isMacosWindowOfHiddenApp:
                (workspace.macOsNativeHiddenAppsWindowsContainer, .macos(prevParentKind: prevParentKind))
            case isOnForeignDesktop:
                (workspace.macOsForeignDesktopWindowsContainer, .foreignNativeDesktop(prevParentKind: prevParentKind))
            default: (nil, .standard)
        }
        if let parent {
            window.layoutReason = reason
            if window.parent !== parent {
                window.bind(to: parent, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
            }
            if case .foreignNativeDesktop = reason, wasFocused {
                _ = setFocus(to: workspace.toLiveFocus())
            }
        } else {
            if window.layoutReason != .standard {
                try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
            }
            window.foreignNativeDesktopWorkspaceName = nil
        }
    }
}

@MainActor
func exitMacOsNativeUnconventionalState(
    window: Window,
    prevParentKind: NonLeafTreeNodeKind,
    workspace: Workspace,
    _ cm: CancellationMode,
) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .workspace:
            break // Not possible
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, cm, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer, .macosForeignDesktopWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
}
