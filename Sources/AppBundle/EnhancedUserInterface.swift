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
    private let read: () -> AxAttributeResult<Bool>
    private let write: (Bool) -> AXError

    init(read: @escaping () -> AxAttributeResult<Bool>, write: @escaping (Bool) -> AXError) {
        self.read = read
        self.write = write
    }

    func acquire() {
        depth += 1
        guard depth == 1, !unsupported, !restore else { return }
        if wasDisabled {
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

    func acquireForBatch() {
        if depth == 0 { acquire() }
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
