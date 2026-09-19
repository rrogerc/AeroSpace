import AppKit
import Common

/// The subscription is active as long as you keep this class in memory
final class AxSubscription {
    let obs: AXObserver
    let ax: AXUIElement
    let axThreadToken: AxAppThreadToken = axTaskLocalAppThreadToken ?? dieT("axTaskLocalAppThreadToken is not initialized")
    var notifKeys: Set<String> = []

    private init(obs: AXObserver, ax: AXUIElement) {
        axThreadToken.checkEquals(axTaskLocalAppThreadToken)
        self.obs = obs
        self.ax = ax
    }

    private func subscribe(_ key: String, windowId: UInt32?) throws -> Bool {
        axThreadToken.checkEquals(axTaskLocalAppThreadToken)
        // AX passes refcon through unchanged. Store the integer ID itself, never a
        // pointer to an object whose lifetime could end before a queued callback.
        let context = unsafe windowId.flatMap { unsafe UnsafeMutableRawPointer(bitPattern: UInt($0)) }
        if unsafe AXObserverAddNotification(obs, ax, key as CFString, context) == .success {
            notifKeys.insert(key)
            return true
        } else {
            return false
        }
    }

    static func bulkSubscribe(
        _ nsApp: NSRunningApplication,
        _ ax: AXUIElement,
        _ job: RunLoopJob,
        _ handlerToNotifKeyMapping: HandlerToNotifKeyMapping,
        windowId: UInt32? = nil,
    ) throws -> [AxSubscription] {
        var result: [AxSubscription] = []
        var visitedNotifKeys: Set<String> = []
        for unsafe (handler, notifKeys) in unsafe handlerToNotifKeyMapping {
            try job.checkCancellation()
            guard let obs = unsafe AXObserver.new(nsApp.processIdentifier, handler) else { return [] }
            let subscription = AxSubscription(obs: obs, ax: ax)
            for key: String in notifKeys {
                try job.checkCancellation()
                assert(visitedNotifKeys.insert(key).inserted)
                if try !subscription.subscribe(key, windowId: windowId) { return [] }
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            result.append(subscription)
        }
        return result
    }

    deinit {
        axThreadToken.checkEquals(axTaskLocalAppThreadToken)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        for notifKey in notifKeys {
            AXObserverRemoveNotification(obs, ax, notifKey as CFString)
        }
    }
}

typealias HandlerToNotifKeyMapping = [(AXObserverCallback, [String])]

func notificationWindowId(_ context: UnsafeMutableRawPointer?, fallback: () -> UInt32?) -> UInt32? {
    let rawId = UInt(bitPattern: context)
    if let windowId = UInt32(exactly: rawId), windowId != 0 { return windowId }
    return fallback()
}
