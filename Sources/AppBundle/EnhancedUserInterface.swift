import ApplicationServices

/// Owned by the app's AX thread. Cache only a confirmed missing attribute, never a
/// transient AX failure (an accessibility client can enable the attribute later).
final class EnhancedUserInterface {
    private var depth = 0
    private var restore = false
    private var unsupported = false
    /// The app's last answer was false. Asking again before the next frames would hold them back for an AX round trip,
    /// and a game answers a request only every frame or two. So those frames go out first, and the app is asked after
    /// them. If another client has enabled the attribute meanwhile, that one batch may animate, and the layout of the
    /// next refresh writes its frames again, with the attribute disabled
    private var wasDisabled = false
    private var askAfterBatch = false
    /// The app had the attribute enabled at least once. Zen enables it by itself whenever it creates a window, and again
    /// half a second after somebody has disabled it. With the question after the frames, the first frames of every
    /// other new Zen window were animated: a quarter of a second in which the window is neither where its app put it
    /// nor in its tile. So an app like that is asked before every batch
    private var wasEverEnabled = false
    private let read: () -> AxAttributeResult<Bool>
    private let write: (Bool) -> AXError

    init(read: @escaping () -> AxAttributeResult<Bool>, write: @escaping (Bool) -> AXError) {
        self.read = read
        self.write = write
    }

    /// `askFirst`: these frames must not be animated, whatever the app answered the last time
    func acquire(askFirst: Bool = false) {
        depth += 1
        guard depth == 1, !unsupported, !restore else { return }
        if wasDisabled && !wasEverEnabled && !askFirst {
            askAfterBatch = true
        } else {
            ask(disable: true)
        }
    }

    func release() {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }
        restoreIfNeeded()
        if askAfterBatch {
            askAfterBatch = false
            ask(disable: false)
        }
    }

    /// `askFirst` for the frame of a new window: it gets it unseen, and shows up when it has it (NewWindowCurtain). An
    /// animation would show up instead
    func acquireForBatch(askFirst: Bool = false) {
        if depth == 0 {
            acquire(askFirst: askFirst)
        } else if askFirst && askAfterBatch {
            // The batch began with frames that didn't have to wait for the answer
            askAfterBatch = false
            ask(disable: true)
        }
    }

    func restoreIfNeeded() {
        guard restore else { return }
        let error = write(true)
        // Retain the restoration obligation after a temporary error and retry next batch.
        if error == .success || error.isMissingAttribute { restore = false }
        if error.isMissingAttribute { unsupported = true }
    }

    private func ask(disable: Bool) {
        wasDisabled = false
        switch read() {
            case .success(true):
                wasEverEnabled = true
                guard disable else { break }
                let error = write(false)
                if error == .success { restore = true }
                if error.isMissingAttribute { unsupported = true }
            case .success(false): wasDisabled = true
            case .failure(let error):
                if error.isMissingAttribute { unsupported = true }
        }
    }
}

extension AXError {
    fileprivate var isMissingAttribute: Bool { self == .attributeUnsupported || self == .noValue }
}
