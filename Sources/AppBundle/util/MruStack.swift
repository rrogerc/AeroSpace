/// Stack with most recently element on top
final class MruStack<T: Equatable>: Sequence {
    typealias Element = T

    private var mruNode: Node<T>? = nil

    func makeIterator() -> MruStackIterator<T> {
        MruStackIterator(mruNode)
    }

    var mostRecent: T? { mruNode?.value }

    func pushOrRaise(_ value: T) {
        remove(value)
        mruNode = Node(value, mruNode)
    }

    /// Puts newValue where oldValue is, without changing the order of the others. Returns whether oldValue was found
    func replace(_ oldValue: T, with newValue: T) -> Bool {
        var current = mruNode
        while let cur = current {
            if cur.value == oldValue {
                cur.value = newValue
                return true
            }
            current = cur.next
        }
        return false
    }

    @discardableResult
    func remove(_ value: T) -> Bool {
        var prev: Node<T>? = nil
        var current = mruNode
        while let cur = current {
            if cur.value == value {
                switch prev {
                    case let prev?: prev.next = cur.next
                    case nil: mruNode = current?.next
                }
                cur.next = nil
                return true
            }
            prev = cur
            current = cur.next
        }
        return false
    }
}

struct MruStackIterator<T: Equatable>: IteratorProtocol {
    typealias Element = T
    private var current: Node<T>?

    fileprivate init(_ current: Node<T>?) {
        self.current = current
    }

    mutating func next() -> T? {
        let result = current?.value
        current = current?.next
        return result
    }
}

private final class Node<T: Equatable> {
    var next: Node<T>? = nil
    var value: T

    init(_ value: T, _ next: Node<T>?) {
        self.value = value
        self.next = next
    }

    init(_ value: T) {
        self.value = value
    }
}
