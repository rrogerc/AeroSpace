import AppKit
import Common
import Foundation
import os
import PrivateApi

/// A new window used to show up where its app put it, and AeroSpace moved it to its tile when it found out: with
/// Ghostty about 100 ms later, six frames in which the new window covered the whole workspace.
///
/// Nobody can move a window before its app shows it. But WindowServer knows a window tens of milliseconds before it's
/// on screen, and a window that is in a shown group with alpha 0 isn't drawn (see WindowSwapGroups). So a new window
/// joins such a group, the curtain, the moment WindowServer knows it. Its app shows it there, unseen. AeroSpace gives
/// it its frame as usual, and when WindowServer has that frame, the window leaves the curtain: it shows up in its
/// tile, on top of the windows that make room for it, and they get their frames after that.
///
/// At birth every window looks the same to WindowServer, also a menu, a sheet, a popover, and a window that AeroSpace
/// will never manage. So nothing stays behind the curtain for long:
/// - A window that isn't a window of its own (it has a parent, or a level) leaves when its app shows it
/// - A window that AeroSpace manages but doesn't tile (a dialog, a popup) leaves at the next layout
/// - Every step on the way has a deadline, and only WindowServer is asked, never the app
final class NewWindowCurtain: Sendable {
    static let shared = NewWindowCurtain()

    private struct Frame {
        let job: RunLoopJob
        let target: CGRect
        let asked: ContinuousClock.Instant
        /// The job got as far as asking the app: see `asking`
        var isAsked = false
        var answered: ContinuousClock.Instant?

        /// The job is over, and it never asked the app
        var cameToNothing: Bool { job.isComplete && !isAsked }
    }

    private struct Entry {
        let pid: Int32
        let born: ContinuousClock.Instant
        var shown: ContinuousClock.Instant?
        /// Since when the window waits for a layout: AeroSpace has it in its tree, or a frame came to nothing
        var managed: ContinuousClock.Instant?
        var frame: Frame?
        /// The app was asked for the frame a second time: it had answered, and WindowServer had another frame
        var askedAgain = false
        /// The frame of the window came to nothing, or the other windows didn't make room for it: see `wait`.
        /// Until a layout asks for its frame (again)
        var needsLayout = false
        /// How often AeroSpace was told to look at the app because of this window
        var looks = 0
        var isLeaving = false
        /// How often the window couldn't be taken out of the group
        var failures = 0
    }

    private struct State {
        var group: WorkspaceVisibilityGroup?
        var isCreatingGroup = false
        /// A group that can't be created isn't tried again with every layout
        var noGroupBefore: ContinuousClock.Instant?
        /// Groups that couldn't be removed. They're empty, or WindowServer removes them with this process
        var oldGroups: [WorkspaceVisibilityGroup] = []
        var home: UInt64 = 0
        var windows: [UInt32: Entry] = [:]
        /// A window gets the curtain once in its life, when it's new
        var announced: Set<UInt32> = []
        var announcedOrder: [UInt32] = []
        /// WindowManager doesn't promise to take a window out of the group after it has put it in. So a window that
        /// has just left is looked at a few more times
        var left: [UInt32: ContinuousClock.Instant] = [:]
        var regularApps: Set<Int32> = []
        var isChecking = false
        var isSweepScheduled = false
        /// macOS delays the timers of a background app by tens of milliseconds, unless something urgent is going on
        var urgency: Urgency?
    }

    private final class Urgency: Sendable {
        nonisolated(unsafe) private let activity: any NSObjectProtocol
        init() {
            unsafe activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Showing a new window")
        }
        deinit { unsafe ProcessInfo.processInfo.endActivity(activity) }
    }

    private let driver: any NewWindowCurtainDriver
    private let timing: NewWindowCurtainTiming
    private let clock: @Sendable () -> ContinuousClock.Instant
    /// AeroSpace looks at the app right away, and lays out. The app has shown a window that AeroSpace doesn't manage
    /// yet (an app that has just started isn't known to it at all), or a window needs a layout that nothing else
    /// is going to start
    private let lookAt: @Sendable (Int32) -> ()
    /// nil in tests: everything runs on the thread of the caller, and `check` is called by hand
    private let queue: DispatchQueue?
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// WindowServer takes the list of the windows to watch as a whole: the list that is read last is sent last
    private let watching = OSAllocatedUnfairLock()

    init(
        driver: any NewWindowCurtainDriver = WindowServerNewWindowDriver(),
        timing: NewWindowCurtainTiming = NewWindowCurtainTiming(),
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        queue: DispatchQueue? = DispatchQueue(label: "bobko.aerospace.new-window-curtain", qos: .userInteractive),
        lookAt: @escaping @Sendable (Int32) -> () = { pid in
            Task.startUnstructured { @MainActor in
                if TrayMenuModel.shared.isEnabled {
                    scheduleCancellableCompleteRefreshSession(.globalObserver("newWindowShown"), scope: .app(pid))
                }
            }
        },
    ) {
        self.driver = driver
        self.timing = timing
        self.clock = clock
        self.queue = queue
        self.lookAt = lookAt
    }

    // MARK: - What AeroSpace knows

    var group: UInt64? { state.withLock { $0.group?.id } }
    var curtained: Set<UInt32> { state.withLock { Set($0.windows.keys) } }
    func isBehind(_ id: UInt32) -> Bool { state.withLock { $0.windows[id] != nil } }
    /// Whose the windows behind the curtain are. WindowServer has said it since they were created, while its list of
    /// windows (CGWindowList) has no record to go by for a window that its app hasn't shown yet: it has no size
    var owners: [UInt32: Int32] { state.withLock { $0.windows.mapValues(\.pid) } }
    /// The apps of the windows that wait for AeroSpace to ask for their frame. Not of a window that its app created
    /// a while ago and hasn't shown: it may never show it
    var appsWithoutFrame: Set<Int32> {
        let now = clock()
        return state.withLock { state in
            Set(state.windows.values.filter { $0.frame == nil && !$0.isLeaving && ($0.shown != nil || now - $0.born < timing.expected) }.map(\.pid))
        }
    }
    /// A window is in the tree of AeroSpace, and no layout has asked for its frame yet
    var hasManagedWindowWithoutFrame: Bool {
        state.withLock { state in state.windows.values.contains { $0.managed != nil && $0.frame == nil && !$0.isLeaving } }
    }

    /// AeroSpace hides its windows on `home`: see HiddenWindowParkingWorker. Without it there's no curtain
    func activate(home: UInt64) {
        let now = clock()
        let create = state.withLock { state in
            state.home = home
            if state.group != nil || state.isCreatingGroup || state.noGroupBefore.map({ now < $0 }) == true { return false }
            state.isCreatingGroup = true
            return true
        }
        guard create else { return }
        run { [self] in
            let old = state.withLock { state in defer { state.oldGroups = [] }; return state.oldGroups }
            let stillThere = old.filter { !driver.destroy($0, home: home) }
            let group = driver.createGroup()
            state.withLock { state in
                state.group = group
                state.isCreatingGroup = false
                state.noGroupBefore = group == nil ? now + timing.noGroup : nil
                state.oldGroups += stillThere
            }
        }
    }

    /// Every window leaves the curtain. With `wait`, they have left when this returns
    func deactivate(wait: Bool = false) {
        let (group, home, ids, apps) = state.withLock { state in
            defer {
                state.group = nil
                state.windows = [:]
                state.left = [:]
            }
            return (state.group, state.home, Array(state.windows.keys), Set(state.windows.values.filter(\.needsLayout).map(\.pid)))
        }
        guard let group else { return }
        let leave: @Sendable () -> () = { [self] in
            // Also a window that joined the group a moment ago, and that nobody knows of yet
            for id in Set(ids).union(driver.windows(in: group) ?? []) { _ = driver.show(id, from: group, home: home) }
            if !driver.destroy(group, home: home) {
                state.withLock { $0.oldGroups.append(group) }
                removeOldGroupsLater()
            }
            watch()
            apps.forEach(lookAt)
        }
        if let queue, wait { queue.sync(execute: leave) } else { run(leave) }
    }

    /// A group that couldn't be removed may still have a window in it, which nobody sees then
    private func removeOldGroupsLater(attempt: Int = 1) {
        guard let queue, attempt <= 10 else { return }
        queue.asyncAfter(deadline: .now() + .seconds(1)) { [self] in
            let (old, home) = state.withLock { state in defer { state.oldGroups = [] }; return (state.oldGroups, state.home) }
            let stillThere = old.filter { group in
                for id in driver.windows(in: group) ?? [] { _ = driver.show(id, from: group, home: home) }
                return !driver.destroy(group, home: home)
            }
            if stillThere.isEmpty { return }
            state.withLock { $0.oldGroups += stillThere }
            removeOldGroupsLater(attempt: attempt + 1)
        }
    }

    /// AeroSpace has the window in its tree. Its layout decides what becomes of it
    func manages(_ id: UInt32) {
        let now = clock()
        state.withLock { state in
            if state.windows[id]?.managed == nil { state.windows[id]?.managed = now }
        }
    }

    /// A layout is going to ask the app of the window for this frame, with `job`. The window leaves the curtain when
    /// WindowServer has the frame. Called before the job can run: see `asking`
    func frame(_ id: UInt32, _ job: RunLoopJob, _ target: CGRect) {
        let now = clock()
        state.withLock { state in
            guard state.windows[id] != nil else { return }
            state.windows[id]?.frame = Frame(job: job, target: target, asked: now)
            state.windows[id]?.needsLayout = false
            if state.windows[id]?.managed == nil { state.windows[id]?.managed = now }
        }
    }

    /// The job of a frame is asking the app now, or has found that WindowServer has the frame already. A job that
    /// ends without it never got that far: the window wasn't ready for a frame, or a command came in between. Then
    /// nobody has asked the app, and its window would wait for a frame that isn't coming
    func asking(_ id: UInt32, _ job: RunLoopJob) {
        state.withLock { state in
            if state.windows[id]?.frame?.job === job { state.windows[id]?.frame?.isAsked = true }
        }
    }

    /// The window leaves the curtain as it is
    func show(_ id: UInt32) {
        run { [self] in leave(id, "no tile") }
    }

    /// The windows aren't behind the curtain anymore, without having been shown: they're gone, or parked with the
    /// windows of a hidden workspace
    func forget(_ ids: [UInt32]) {
        let known = state.withLock { state in ids.compactMap { state.windows.removeValue(forKey: $0) } }
        if known.isEmpty { return }
        watch()
        Set(known.filter(\.needsLayout).map(\.pid)).forEach(lookAt)
    }

    private func watch() {
        watching.withLock { driver.watch(state.withLock { Array($0.windows.keys) }) }
    }

    /// Blocks the AX thread of an app whose window makes room for new windows, until they can be seen: a window that
    /// shrinks before the new one is there shows the wallpaper in between.
    ///
    /// false if one of the new windows has no frame coming. Then this layout doesn't get it into its tile, and nobody
    /// makes room for it yet: the layout that asks for its frame does, or the one after the window has left the
    /// curtain as it is. Waiting for it here would keep that layout from the AX thread of the app, which the two
    /// windows often share (a new terminal window next to the one it was opened from)
    func wait(for windows: Set<UInt32>, _ job: RunLoopJob) -> Bool {
        enum NewWindows { case seen, behind, withoutFrame }
        let look = { [state] () -> NewWindows in
            state.withLock { curtain in
                var result = NewWindows.seen
                for id in windows {
                    guard let entry = curtain.windows[id] else { continue }
                    if entry.isLeaving || entry.frame?.cameToNothing == false {
                        result = .behind
                    } else {
                        curtain.windows[id]?.needsLayout = true
                        return .withoutFrame
                    }
                }
                return result
            }
        }
        switch look() {
            case .seen: return true
            case .withoutFrame: return false
            case .behind: break
        }
        let interval = signposter.beginInterval("waitForNewWindows")
        defer { signposter.endInterval("waitForNewWindows", interval) }
        // Otherwise, macOS may delay the timer below by tens of milliseconds, because AeroSpace is a background app
        return withExtendedLifetime(Urgency()) {
            let deadline = ContinuousClock.now + timing.others
            while !job.isCancelled && ContinuousClock.now < deadline {
                switch look() {
                    case .seen: return true
                    case .withoutFrame: return false
                    case .behind: usleep(1000)
                }
            }
            return true
        }
    }

    // MARK: - What WindowServer tells

    /// An event of AeroSpaceWindowEvent. Any thread
    func windowEvent(_ event: UInt32, _ id: UInt32) {
        // Nothing to do for the windows of everyday: not even a hop to another thread
        let matters = state.withLock { state in
            state.windows[id] != nil || (event == AeroSpaceWindowEvent.levelChanged.rawValue && state.group != nil && !state.announced.contains(id))
        }
        if matters { run { [self] in handle(event, id) } }
    }

    private func handle(_ event: UInt32, _ id: UInt32) {
        if event == AeroSpaceWindowEvent.closed.rawValue { return forget([id]) }
        if state.withLock({ $0.windows[id] != nil }) { return check(id) }
        if event == AeroSpaceWindowEvent.levelChanged.rawValue { born(id) }
    }

    private func born(_ id: UInt32) {
        let target = state.withLock { state -> (group: WorkspaceVisibilityGroup, home: UInt64)? in
            guard let group = state.group, state.announced.insert(id).inserted else { return nil }
            state.announcedOrder.append(id)
            if state.announcedOrder.count > 1024 { state.announced.remove(state.announcedOrder.removeFirst()) }
            return (group, state.home)
        }
        guard let target,
              // A tab that is dragged out of its window becomes a window that follows the pointer
              !driver.isMouseButtonDown(),
              let info = driver.window(id),
              // Only a window that nobody has seen yet. Later the curtain would make it blink
              !info.isOrderedIn, info.spaces.isEmpty, info.level == 0, info.parent == 0,
              info.pid != getpid(), isRegularApp(info.pid),
              // A window of another desktop of macOS isn't ours to hide
              driver.activeSpace() == target.home,
              driver.hide(id, in: target.group)
        else { return }
        signposter.emitEvent("newWindowCurtained", "window: \(id, privacy: .public)")
        let now = clock()
        let isBehind = state.withLock { state in
            guard state.group == target.group else { return false }
            state.windows[id] = Entry(pid: info.pid, born: now)
            return true
        }
        // Deactivated meanwhile: the group is going, and the window mustn't stay in it
        guard isBehind else {
            _ = driver.show(id, from: target.group, home: target.home)
            return
        }
        watch()
        checkLater()
    }

    private func isRegularApp(_ pid: Int32) -> Bool {
        if state.withLock({ $0.regularApps.contains(pid) }) { return true }
        // An app that is starting may not be regular yet, so only a yes is remembered
        guard driver.isRegularApp(pid) else { return false }
        state.withLock { state in
            if state.regularApps.count > 256 { state.regularApps = [] }
            state.regularApps.insert(pid)
        }
        return true
    }

    // MARK: - Leaving

    /// Looks at every window behind the curtain. Runs every few milliseconds while there are any
    func check() {
        let (ids, left, group, home) = state.withLock { state in
            let now = clock()
            state.left = state.left.filter { now - $0.value < timing.lookedAfter }
            return (Array(state.windows.keys), Array(state.left.keys), state.group, state.home)
        }
        for id in ids { check(id) }
        guard let group else { return }
        for id in left where driver.window(id)?.spaces.contains(group.id) == true {
            _ = driver.show(id, from: group, home: home)
        }
    }

    private func check(_ id: UInt32) {
        guard state.withLock({ $0.windows[id]?.isLeaving == false }) else { return }
        // WindowServer doesn't know the window, or didn't answer. If the window is still there, it mustn't stay unseen
        guard let info = driver.window(id) else { return leave(id, "gone") }
        let now = clock()
        // A menu, a sheet, a popover, a panel above the other windows: none of them gets a tile
        if info.level != 0 || info.parent != 0 { return leave(id, "not a window of its own") }
        // One step: a layout may ask for another frame meanwhile, and the job of a frame says that it's asking
        // before it's over
        let (reason, look) = state.withLock { state -> (String?, Int32?) in
            guard var entry = state.windows[id], !entry.isLeaving else { return (nil, nil) }
            defer { state.windows[id] = entry }
            var look = false
            if entry.shown == nil, info.isOrderedIn {
                entry.shown = now
                signposter.emitEvent("newWindowShown", "window: \(id, privacy: .public)")
                look = entry.managed == nil || entry.needsLayout
            }
            if let frame = entry.frame, frame.job.isComplete {
                if frame.isAsked {
                    if frame.answered == nil { entry.frame?.answered = now }
                } else {
                    // Nobody asked the app. The layout that does must not wait for the deadline of this one
                    signposter.emitEvent("newWindowFrameCameToNothing", "window: \(id, privacy: .public)")
                    entry.frame = nil
                    entry.managed = now
                    entry.needsLayout = true
                    // An app that hasn't shown the window may be the reason. Then AeroSpace looks when it has
                    look = look || entry.shown != nil
                }
            }
            var reason: String?
            if let frame = entry.frame {
                if frame.answered != nil, isInPlace(info.bounds, frame.target) {
                    reason = "in place"
                } else if let answered = frame.answered, let shown = entry.shown, now - max(answered, shown) >= timing.refused {
                    // WindowServer has the frame of a window only once its app has shown it, so not before that.
                    // An app that sets a frame of its own while it shows the window (its default size, the place
                    // next to its last window) takes the one of its tile right after: it's asked once more
                    if entry.askedAgain {
                        reason = "another frame"
                    } else {
                        signposter.emitEvent("newWindowAskedAgain", "window: \(id, privacy: .public)")
                        entry.askedAgain = true
                        entry.frame = nil
                        entry.managed = now
                        entry.needsLayout = true
                        look = true
                    }
                } else if now - frame.asked >= timing.inPlace {
                    reason = frame.answered == nil ? "no frame in time" : "not shown in time"
                }
            } else if let managed = entry.managed {
                if now - managed >= timing.placed { reason = "no layout in time" }
            } else if let shown = entry.shown {
                if now - shown >= timing.managed { reason = "not managed in time" }
            } else if now - entry.born >= timing.shown {
                reason = "not shown in time"
            }
            if reason == nil, let shown = entry.shown, now - shown >= timing.unseen { reason = "unseen for too long" }
            // Not again and again: whatever keeps the window from its frame may last
            guard look, reason == nil, entry.looks < 3 else { return (reason, nil) }
            entry.looks += 1
            return (nil, entry.pid)
        }
        if let look { lookAt(look) }
        if let reason { leave(id, reason) }
    }

    private func leave(_ id: UInt32, _ reason: String) {
        let leaving = state.withLock { state -> (group: WorkspaceVisibilityGroup, home: UInt64, hasFrame: Bool)? in
            guard let group = state.group, let entry = state.windows[id], !entry.isLeaving else { return nil }
            state.windows[id]?.isLeaving = true
            return (group, state.home, entry.frame != nil)
        }
        guard let leaving else { return }
        runApart { [self] in
            let interval = signposter.beginInterval("showNewWindow", "window: \(id, privacy: .public) reason: \(reason, privacy: .public)")
            defer { signposter.endInterval("showNewWindow", interval) }
            guard driver.show(id, from: leaving.group, home: leaving.home) else {
                // The next check tries again, or finds out that the window is gone
                let failures = state.withLock { state in
                    state.windows[id]?.isLeaving = false
                    state.windows[id]?.failures += 1
                    return state.windows[id]?.failures ?? 0
                }
                // WindowManager doesn't take the window out. WindowServer does, if the whole group goes: the next
                // layout creates another one
                if failures >= 3 { deactivate() }
                return
            }
            // The windows that make room for this one wait until it can be seen
            if leaving.hasFrame {
                let deadline = ContinuousClock.now + timing.onScreen
                while !driver.isOnScreen(id) && ContinuousClock.now < deadline && driver.window(id) != nil { usleep(500) }
            }
            let now = clock()
            let entry = state.withLock { state in
                let entry = state.windows.removeValue(forKey: id)
                if entry != nil { state.left[id] = now }
                return entry
            }
            watch()
            // It left as it was, and nothing else is going to start the layout that puts it into its tile, or that
            // makes the other windows make room
            if let entry, entry.needsLayout { lookAt(entry.pid) }
        }
    }

    /// The opening animation of macOS scales a new window by a percent or two around its middle, for a fifth of a
    /// second. And an app may keep a frame that is close to the one it was asked for (a terminal with whole cells)
    private func isInPlace(_ bounds: CGRect, _ target: CGRect) -> Bool {
        let x = max(4, target.width * 0.015), y = max(4, target.height * 0.015)
        return abs(bounds.minX - target.minX) <= x && abs(bounds.maxX - target.maxX) <= x &&
            abs(bounds.minY - target.minY) <= y && abs(bounds.maxY - target.maxY) <= y
    }

    // MARK: - Threads

    private func run(_ body: @escaping @Sendable () -> ()) {
        if let queue { queue.async(execute: body) } else { body() }
    }

    /// Taking a window out of the group waits for WindowManager, and for the window to show up. The birth of the
    /// next window can't wait behind that
    private func runApart(_ body: @escaping @Sendable () -> ()) {
        if queue != nil { DispatchQueue.global(qos: .userInteractive).async(execute: body) } else { body() }
    }

    private func checkLater() {
        guard let queue, state.withLock({ state in
            if state.isChecking { return false }
            state.isChecking = true
            return true
        }) else { return }
        checkAgain(on: queue)
    }

    private func checkAgain(on queue: DispatchQueue) {
        // A window that its app hasn't shown yet is announced when it is (AeroSpaceWindowEventOrderedIn), so it's
        // looked at less often. The others are about to show up: every millisecond of theirs is seen
        let isUrgent = state.withLock { state in
            state.windows.values.contains { $0.shown != nil || $0.frame != nil } || !state.left.isEmpty
        }
        let urgency = isUrgent ? state.withLock { $0.urgency } ?? Urgency() : nil
        state.withLock { $0.urgency = urgency }
        queue.asyncAfter(deadline: .now() + (isUrgent ? timing.pause : timing.longPause).dispatchTimeInterval) { [self] in
            check()
            let more = state.withLock { state in
                if !state.windows.isEmpty || !state.left.isEmpty { return true }
                state.isChecking = false
                state.urgency = nil
                return false
            }
            if more { checkAgain(on: queue) } else { sweepLater(on: queue) }
        }
    }

    /// Nothing may stay behind the curtain. If a window is there that nobody knows of, it leaves
    private func sweepLater(on queue: DispatchQueue) {
        guard state.withLock({ state in
            if state.isSweepScheduled { return false }
            state.isSweepScheduled = true
            return true
        }) else { return }
        queue.asyncAfter(deadline: .now() + timing.sweep.dispatchTimeInterval) { [self] in
            // It asks WindowServer about every window there is, and the birth of the next window can't wait for that
            runApart { [self] in
                let (group, home, known) = state.withLock { state in
                    state.isSweepScheduled = false
                    return (state.group, state.home, Set(state.windows.keys))
                }
                guard let group, let windows = driver.windows(in: group) else { return }
                for id in windows where !known.contains(id) {
                    signposter.emitEvent("newWindowSwept", "window: \(id, privacy: .public)")
                    _ = driver.show(id, from: group, home: home)
                }
            }
        }
    }
}

struct NewWindowCurtainTiming: Sendable {
    /// An app may create a window long before it shows it (a browser, an app that is starting), or never show it
    var shown: Duration = .seconds(5)
    /// Most apps show a new window right away. Until then AeroSpace is in a hurry to find it
    var expected: Duration = .milliseconds(300)
    /// AeroSpace manages a window after its app has answered a few AX requests
    var managed: Duration = .milliseconds(150)
    /// From the moment that AeroSpace manages the window until a layout gives it a frame
    var placed: Duration = .milliseconds(200)
    /// From the request of the frame until WindowServer has it
    var inPlace: Duration = .milliseconds(250)
    /// The app has answered the request and shown its window, and WindowServer still has another frame. The app is
    /// asked once more, and after this long again, it keeps its own frame (e.g. a window that can't be that small).
    /// WindowServer had the frame of 140 new Ghostty windows 15 ms after that (the median), and 37 ms at the latest
    var refused: Duration = .milliseconds(50)
    /// Whatever happens, a window that its app has shown isn't behind the curtain for longer than this
    var unseen: Duration = .milliseconds(450)
    /// A window that has left the curtain is on screen a few milliseconds later
    var onScreen: Duration = .milliseconds(250)
    /// The windows that make room for a new window don't wait for it for longer than this
    var others: Duration = .milliseconds(400)
    var lookedAfter: Duration = .milliseconds(500)
    var pause: Duration = .milliseconds(3)
    var longPause: Duration = .milliseconds(50)
    var sweep: Duration = .seconds(1)
    var noGroup: Duration = .seconds(5)
}

/// What WindowServer knows about a window that may not be on screen yet
struct NewWindowInfo: Equatable, Sendable {
    var pid: Int32
    var level = 0
    /// The window that a sheet, a popover or a menu belongs to
    var parent: UInt32 = 0
    var isOrderedIn = false
    var bounds: CGRect = .zero
    var spaces: [UInt64] = []
}

protocol NewWindowCurtainDriver: Sendable {
    /// nil if WindowServer doesn't know the window
    func window(_ id: UInt32) -> NewWindowInfo?
    func isOnScreen(_ id: UInt32) -> Bool
    func activeSpace() -> UInt64
    /// AeroSpace doesn't manage the windows of other apps
    func isRegularApp(_ pid: Int32) -> Bool
    func isMouseButtonDown() -> Bool
    /// A shown group with alpha 0
    func createGroup() -> WorkspaceVisibilityGroup?
    /// The windows that are still in the group are back on the desktop
    func destroy(_ group: WorkspaceVisibilityGroup, home: UInt64) -> Bool
    /// Asks, and doesn't wait: the window is in the group a few milliseconds later
    func hide(_ id: UInt32, in group: WorkspaceVisibilityGroup) -> Bool
    /// Waits until the window is out of the group
    func show(_ id: UInt32, from group: WorkspaceVisibilityGroup, home: UInt64) -> Bool
    func windows(in group: WorkspaceVisibilityGroup) -> [UInt32]?
    /// The windows to get the events of (AeroSpaceWindowEvent), besides the level of every new window
    func watch(_ ids: [UInt32])
}

struct WindowServerNewWindowDriver: NewWindowCurtainDriver {
    func window(_ id: UInt32) -> NewWindowInfo? {
        var raw = AeroSpaceNewWindowInfo()
        guard unsafe AeroSpaceCopyNewWindowInfo(id, &raw) else { return nil }
        let spaces = (AeroSpaceCopyAllWindowSpaces(id) as? [NSNumber])?.map(\.uint64Value) ?? []
        return NewWindowInfo(pid: raw.pid, level: Int(raw.level), parent: raw.parent, isOrderedIn: raw.orderedIn, bounds: raw.bounds, spaces: spaces)
    }

    func isOnScreen(_ id: UInt32) -> Bool {
        // The window ID goes in as it is, not as a CFNumber: see getWindowServerWindows
        guard let ids = CFArrayCreateMutable(nil, 1, nil) else { return false }
        unsafe CFArrayAppendValue(ids, UnsafeRawPointer(bitPattern: UInt(id)))
        let records = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]]
        return records?.first?[kCGWindowIsOnscreen as String] as? Bool == true
    }

    func activeSpace() -> UInt64 { AeroSpaceActiveNativeSpace() }
    func isRegularApp(_ pid: Int32) -> Bool { NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular }
    func isMouseButtonDown() -> Bool { CGEventSource.buttonState(.combinedSessionState, button: .left) }

    func createGroup() -> WorkspaceVisibilityGroup? {
        guard AeroSpaceWindowSwapAvailable(), AeroSpaceWindowEventsAvailable() else { return nil }
        let name = "AeroSpace new windows \(getuid()) \(getpid()) \(UUID().uuidString)"
        let id = AeroSpaceCreateWorkspaceGroup(name as CFString)
        guard id != 0 else { return nil }
        let group = WorkspaceVisibilityGroup(id: id, name: name)
        if AeroSpacePrepareCurtainGroup(id, name as CFString) { return group }
        _ = destroy(group, home: AeroSpaceActiveNativeSpace())
        return nil
    }

    func destroy(_ group: WorkspaceVisibilityGroup, home: UInt64) -> Bool {
        AeroSpaceRestoreWorkspaceGroups([NSNumber(value: group.id): group.name] as CFDictionary, home)
    }

    func hide(_ id: UInt32, in group: WorkspaceVisibilityGroup) -> Bool { AeroSpaceCurtainWindow(id, group.id) }
    func show(_ id: UInt32, from group: WorkspaceVisibilityGroup, home: UInt64) -> Bool { AeroSpaceUncurtainWindow(id, group.id, home) }
    func windows(in group: WorkspaceVisibilityGroup) -> [UInt32]? { (AeroSpaceCopyCurtainedWindows(group.id) as? [NSNumber])?.map(\.uint32Value) }

    func watch(_ ids: [UInt32]) {
        unsafe ids.withUnsafeBufferPointer { unsafe AeroSpaceWatchWindows($0.baseAddress, $0.count) }
    }
}

/// The new windows that the frames of a layout wait for: see NewWindowCurtain.wait
@TaskLocal
var newWindowsToShowFirst: Set<UInt32> = []

@MainActor
func observeNewWindows() {
    if isUnitTest || serverArgs.isReadOnly || ProcessInfo.processInfo.environment["AEROSPACE_NEW_WINDOW_CURTAIN"] == "0" { return }
    _ = AeroSpaceObserveWindowEvents { event, windowId in NewWindowCurtain.shared.windowEvent(event, windowId) }
}

extension Duration {
    fileprivate var dispatchTimeInterval: DispatchTimeInterval {
        .nanoseconds(Int(components.seconds) * 1_000_000_000 + Int(components.attoseconds / 1_000_000_000))
    }
}
