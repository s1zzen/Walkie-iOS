import Foundation
import Network

struct WalkConnectivityTransitions {
    private var walkID: UUID?
    private var online: Bool?
    mutating func update(online next: Bool, walkID nextWalk: UUID?) -> String? {
        if walkID != nextWalk { walkID = nextWalk; online = nil }
        guard nextWalk != nil else { online = nil; return nil }
        let previous = online
        online = next
        if previous == next { return nil }
        if !next { return "network_lost" }
        return previous == false ? "network_restored" : nil
    }
}

@MainActor final class WalkConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private var transitions = WalkConnectivityTransitions()
    private var online: Bool?
    var walkID: (() -> UUID?)?
    var onEvent: ((String) -> Void)?
    var onRestored: (() -> Void)?
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = self.online == false
                self.online = connected
                self.refreshWalk()
                if wasOffline && connected { self.onRestored?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.walkie.connectivity"))
    }
    func refreshWalk() {
        guard let online else { return }
        if let event = transitions.update(online: online, walkID: walkID?()) { onEvent?(event) }
    }
    deinit { monitor.cancel() }
}
