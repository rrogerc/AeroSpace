enum RefreshScope: Equatable, Sendable {
    case all
    case apps(Set<Int32>)

    static func app(_ pid: Int32?) -> RefreshScope { pid.map { .apps([$0]) } ?? .all }

    func contains(_ pid: Int32) -> Bool {
        switch self {
            case .all: true
            case .apps(let pids): pids.contains(pid)
        }
    }

    func union(_ other: RefreshScope) -> RefreshScope {
        switch (self, other) {
            case (.all, _), (_, .all): .all
            case (.apps(let lhs), .apps(let rhs)): .apps(lhs.union(rhs))
        }
    }

    func shouldCollectWindow(pid: Int32, appTerminated: Bool, aliveIds: Set<UInt32>, windowId: UInt32) -> Bool {
        appTerminated || (contains(pid) && !aliveIds.contains(windowId))
    }
}
