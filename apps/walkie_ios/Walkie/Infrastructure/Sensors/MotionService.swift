import CoreMotion
import Foundation
import WalkieCore

@MainActor
protocol MotionSource: AnyObject {
    var onMotion: ((ResearchMotion) -> Void)? { get set }
    func start()
    func stop()
}

/// The step measurement time is preserved separately from delivery time.
/// Denied/unavailable/delayed steps are missing evidence, never zero movement.
@MainActor
final class MotionService: MotionSource {
    var onMotion: ((ResearchMotion) -> Void)?
    private let pedometer = CMPedometer()
    private var generation = UUID()

    func start() {
        guard CMPedometer.isStepCountingAvailable(), CMPedometer.authorizationStatus() == .authorized else { return }
        generation = UUID()
        let token = generation
        pedometer.startUpdates(from: Date()) { [weak self] data, error in
            guard error == nil, let data else { return }
            let snapshot = ResearchMotion(steps: data.numberOfSteps.intValue, measuredAt: data.endDate,
                receivedAt: Date(), monotonicTime: ProcessInfo.processInfo.systemUptime)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onMotion?(snapshot)
            }
        }
    }

    func stop() { generation = UUID(); pedometer.stopUpdates() }
}
