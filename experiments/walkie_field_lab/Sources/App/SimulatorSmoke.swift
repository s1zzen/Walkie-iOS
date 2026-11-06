#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Только отладочная сборка симулятора; не входит в код, исполняемый на iPhone.
@MainActor
enum SimulatorSmoke {
    private static var started = false

    static func runIfRequested(recorder: FieldRecorder) {
        guard !started, ProcessInfo.processInfo.arguments.contains("--field-lab-smoke") else { return }
        started = true
        Task { @MainActor in
            do {
                let route = TestRoute(name: "Simulator smoke — synthetic", source: "synthetic_test_only", segments: [[
                    GeoPoint(latitude: 55.751244, longitude: 37.618423),
                    GeoPoint(latitude: 55.756244, longitude: 37.618423)
                ]])
                try recorder.start(route: route, name: "Simulator smoke", notes: "Synthetic simulator check; NOT a field experiment.")
                recorder.mark("note", note: "Automated simulator smoke test; simulated data only.")
                try await Task.sleep(for: .seconds(8))
                recorder.stop()
                print("FIELD_LAB_SMOKE_FINISHED")
            } catch { print("FIELD_LAB_SMOKE_FAILED: \(error.localizedDescription)") }
        }
    }
}
#endif
