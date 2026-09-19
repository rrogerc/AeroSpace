import ApplicationServices

/// Owned by the app's AX thread. Cache only a confirmed missing attribute, never a
/// transient AX failure or a false value (an accessibility client can enable it later).
final class EnhancedUserInterface {
    private var depth = 0
    private var restore = false
    private var unsupported = false
    private let read: () -> AxAttributeResult<Bool>
    private let write: (Bool) -> AXError

    init(read: @escaping () -> AxAttributeResult<Bool>, write: @escaping (Bool) -> AXError) {
        self.read = read
        self.write = write
    }

    func acquire() {
        depth += 1
        guard depth == 1, !unsupported, !restore else { return }
        switch read() {
            case .success(true):
                let error = write(false)
                if error == .success { restore = true }
                if error.isMissingAttribute { unsupported = true }
            case .success(false): break
            case .failure(let error):
                if error.isMissingAttribute { unsupported = true }
        }
    }

    func release() {
        guard depth > 0 else { return }
        depth -= 1
        if depth == 0 { restoreIfNeeded() }
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
}

extension AXError {
    fileprivate var isMissingAttribute: Bool { self == .attributeUnsupported || self == .noValue }
}
