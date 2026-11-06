import Foundation
import SwiftUI

protocol ProductTelemetryRecording: Sendable {
    func record(_ type: String, screen: String?, payload: [String: String]) async throws
}

extension ProductTelemetryRecording {
    func record(_ type: String, payload: [String: String] = [:]) async throws {
        try await record(type, screen: nil, payload: payload)
    }
}

struct NoOpProductTelemetryRecorder: ProductTelemetryRecording {
    func record(_ type: String, screen: String?, payload: [String: String]) async throws {}
}

private struct ProductTelemetryKey: EnvironmentKey {
    static let defaultValue: any ProductTelemetryRecording = NoOpProductTelemetryRecorder()
}

extension EnvironmentValues {
    var productTelemetry: any ProductTelemetryRecording {
        get { self[ProductTelemetryKey.self] }
        set { self[ProductTelemetryKey.self] = newValue }
    }
}
