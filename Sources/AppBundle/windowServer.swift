import CoreGraphics
import Foundation
import PrivateApi

/// WindowServer metadata does not require the owning app to service an AX request.
struct WindowServerWindowInfo {
    let windowId: UInt32
    let pid: Int32
    let layer: Int
    let bounds: CGRect

    init?(_ info: [String: Any]) {
        guard let windowId = info[kCGWindowNumber as String] as? UInt32,
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let layer = info[kCGWindowLayer as String] as? Int,
              let rawBounds = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary)
        else { return nil }
        self.init(windowId: windowId, pid: pid, layer: layer, bounds: bounds)
    }

    init?(windowId: UInt32, pid: Int32, layer: Int, bounds: CGRect) {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.size.width.isFinite, bounds.size.height.isFinite,
              bounds.size.width > 0, bounds.size.height > 0,
              bounds.maxX.isFinite, bounds.maxY.isFinite
        else { return nil }
        self.windowId = windowId
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
    }

    var rect: Rect {
        // WindowServer, like AX, uses a top-left origin. CGRect.toRect() is for AppKit coordinates.
        Rect(topLeftX: bounds.minX, topLeftY: bounds.minY, width: bounds.width, height: bounds.height)
    }
}

func getWindowServerWindow(_ windowId: UInt32, pid: Int32) -> WindowServerWindowInfo? {
    let state = signposter.beginInterval("observeWindowFrame", "pid: \(pid, privacy: .public)")
    defer { signposter.endInterval("observeWindowFrame", state) }
    if let info = PrivateWindowMetadata.read([windowId])?.first, info.windowId == windowId, info.pid == pid { return info }
    guard let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowId) as? [[String: Any]],
          let record = records.first,
          let info = WindowServerWindowInfo(record),
          info.windowId == windowId, info.pid == pid
    else { return nil }
    return info
}

func getOnScreenWindowServerWindows() -> [WindowServerWindowInfo]? {
    let state = signposter.beginInterval("observeNativeWindowOrder")
    defer { signposter.endInterval("observeNativeWindowOrder", state) }
    guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    // Preserve front-to-back order. If metadata is incomplete, use the AX fallback for focus.
    var result: [WindowServerWindowInfo] = []
    for record in records {
        guard let info = WindowServerWindowInfo(record) else { return nil }
        result.append(info)
    }
    return result
}

func getWindowServerWindows(_ windowIds: [UInt32]) -> [WindowServerWindowInfo]? {
    guard !windowIds.isEmpty else { return [] }
    let state = signposter.beginInterval("observeLayoutWindowFrames")
    defer { signposter.endInterval("observeLayoutWindowFrames", state) }
    if let records = PrivateWindowMetadata.read(windowIds) { return records }
    // Unlike a bridged Swift array, this API expects CGWindowIDs stored directly as
    // pointer-sized integers, not CFNumbers. Nil callbacks ensure they aren't dereferenced.
    guard let ids = CFArrayCreateMutable(nil, windowIds.count, nil) else { return nil }
    for windowId in windowIds {
        unsafe CFArrayAppendValue(ids, UnsafeRawPointer(bitPattern: UInt(windowId)))
    }
    guard let records = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]] else { return nil }
    return records.compactMap(WindowServerWindowInfo.init)
}

enum PrivateWindowMetadata {
    static let isEnabled = ProcessInfo.processInfo.environment["AEROSPACE_PRIVATE_WINDOW_QUERIES"] == "1"

    static func read(_ windowIds: [UInt32]) -> [WindowServerWindowInfo]? {
        guard isEnabled else { return nil }
        if windowIds.isEmpty { return [] }
        var output = Array(repeating: AeroSpaceWindowInfo(), count: windowIds.count)
        var count = 0
        let error = unsafe windowIds.withUnsafeBufferPointer { ids in
            unsafe output.withUnsafeMutableBufferPointer { records in
                unsafe AeroSpaceCopyWindowInfo(ids.baseAddress, ids.count, records.baseAddress, records.count, &count)
            }
        }
        guard error == .success else { return nil }
        return decode(output, count: count, windowIds: windowIds)
    }

    static func decode(_ output: [AeroSpaceWindowInfo], count: Int, windowIds: [UInt32]) -> [WindowServerWindowInfo]? {
        guard count >= 0, count <= output.count else { return nil }
        let requested = Set(windowIds)
        var records: [WindowServerWindowInfo] = []
        for record in output.prefix(count) {
            guard requested.contains(record.windowId), record.pid > 0,
                  let info = WindowServerWindowInfo(windowId: record.windowId, pid: record.pid, layer: Int(record.layer), bounds: record.bounds)
            else { return nil }
            records.append(info)
        }
        return records
    }
}

/// Capture already hidden windows together, before reconciling their placements. Missing
/// metadata falls back to the usual AX path for that window, without affecting the others.
@MainActor
func observeHiddenWindowFrames(_ windows: [MacWindow]) -> [UInt32: HiddenWindowFrameObservation] {
    let settled = windows.filter { $0.isHiddenInCorner && !$0.macApp.hasPendingFrame($0.windowId) }
    guard !settled.isEmpty,
          let records = getWindowServerWindows(settled.map(\.windowId))
    else { return [:] }
    var infos: [UInt32: WindowServerWindowInfo] = [:]
    for info in records { infos[info.windowId] = info }
    var result: [UInt32: HiddenWindowFrameObservation] = [:]
    for window in settled {
        if let info = infos[window.windowId], info.pid == window.macApp.pid {
            result[window.windowId] = HiddenWindowFrameObservation(info: info, precedingFrame: window.macApp.lastFrameJob(window.windowId))
        }
    }
    return result
}

struct HiddenWindowFrameObservation {
    let info: WindowServerWindowInfo
    let precedingFrame: RunLoopJob?
    func isCurrent(latestFrame: RunLoopJob?) -> Bool {
        precedingFrame === latestFrame && latestFrame?.isComplete != false
    }
}

/// macOS can clamp a corner move vertically to retain a reachable title bar.
/// Remember the observed result of that move, while correcting later external moves.
struct HiddenWindowPlacement {
    let target: CGPoint
    let frame: RunLoopJob
    private var acceptedBounds: CGRect?

    init(target: CGPoint, frame: RunLoopJob) {
        self.target = target
        self.frame = frame
    }

    mutating func matches(observation: HiddenWindowFrameObservation?, target: CGPoint, latestFrame: RunLoopJob?, monitors: [Rect]) -> Bool {
        guard self.target == target, frame === latestFrame, !frame.isCancelled,
              let observation, observation.isCurrent(latestFrame: latestFrame)
        else { return false }
        let bounds = observation.info.bounds
        guard bounds.origin.x == target.x, !monitors.isEmpty,
              monitors.allSatisfy({ monitor in
                  let screen = CGRect(x: monitor.topLeftX, y: monitor.topLeftY, width: monitor.width, height: monitor.height)
                  let visible = bounds.intersection(screen)
                  // A hide leaves at most the existing one-point border on any display.
                  return visible.isNull || visible.width <= 1 || visible.height <= 1
              })
        else { return false }
        if let acceptedBounds { return acceptedBounds == bounds }
        acceptedBounds = bounds
        return true
    }
}

struct WindowFrameUpdate: Equatable, Sendable {
    let topLeft: CGPoint?
    let size: CGSize?

    var isEmpty: Bool { topLeft == nil && size == nil }

    func skippingUnchangedValues(comparedTo bounds: CGRect?) -> WindowFrameUpdate {
        guard let bounds else { return self }
        let size = size == bounds.size ? nil : size
        // A resize may also move the window. Preserve the size/position/size workaround in that case.
        let topLeft = size == nil && topLeft == bounds.origin ? nil : topLeft
        return WindowFrameUpdate(topLeft: topLeft, size: size)
    }
}
