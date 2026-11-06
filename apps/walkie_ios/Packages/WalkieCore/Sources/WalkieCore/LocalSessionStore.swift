import Foundation

public enum LocalSessionStoreError: Error, LocalizedError, Sendable {
    case quarantined

    public var errorDescription: String? {
        "После ошибки хранилища результат записи не подтверждён. Дальнейшие операции остановлены. Перезапустите приложение для восстановления журнала."
    }
}

/// Single writer for local-only walk data. Keep one instance for the app's lifetime.
/// Opening a fresh instance is a recovery boundary, not a second live connection.
public actor LocalSessionStore {
    private let root: URL
    private let segmentID = UUID()
    private let fileManager = FileManager.default
    private let afterJournalWrite: (@Sendable () throws -> Void)?
    private var loaded = false
    private var quarantined = false
    private var records: [UUID: SessionRecord] = [:]
    private var sequences: [UUID: Int] = [:]

    public init(root: URL) {
        self.root = root.standardizedFileURL
        self.afterJournalWrite = nil
    }

    /// Test-only failure boundary: bytes may have reached the file, but successful
    /// synchronization has not yet established a durable append outcome.
    init(root: URL, afterJournalWrite: @escaping @Sendable () throws -> Void) {
        self.root = root.standardizedFileURL
        self.afterJournalWrite = afterJournalWrite
    }

    public func create(route: RoutePlan, at: Date, kind: WalkStartKind = .regular) throws -> SessionRecord {
        try prepare()
        try validate(at)
        try route.validate()
        return try performIO {
            let record = SessionRecord(route: route, startedAt: at, kind: kind)
            let directory = sessionDirectory(record.id)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try protect(directory)
            let event = SessionEvent(
                metadata: metadata(sessionID: record.id, sequence: 1, at: at),
                kind: .created, state: .recording, endedAt: nil, poiID: nil, reason: nil
            )
            // The manifest is the commit marker. An interrupted create without one is
            // not presented as a usable session; its files remain available for diagnosis.
            try writeJSONLines([event], to: directory.appendingPathComponent("events.jsonl"))
            try writeJSONLines([LocationObservation](), to: directory.appendingPathComponent("locations.jsonl"))
            try save(record)
            records[record.id] = record
            sequences[record.id] = 1
            return record
        }
    }

    public func appendLocation(
        sessionID: UUID, coordinate: Coordinate, horizontalAccuracy: Double,
        observedAt: Date, receivedAt: Date, monotonicTime: Double
    ) throws {
        try prepare()
        var record = try requireRecord(sessionID)
        guard record.state == .recording else { throw SessionStorageError.notRecording }
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude)
        else { throw SessionStorageError.invalidCoordinate }
        guard horizontalAccuracy.isFinite, horizontalAccuracy >= 0 else {
            throw SessionStorageError.invalidAccuracy
        }
        try validate(observedAt)
        try validate(receivedAt)
        guard monotonicTime.isFinite, monotonicTime >= 0 else { throw SessionStorageError.invalidTime }
        let next = (sequences[sessionID] ?? 0) + 1
        let observation = LocationObservation(
            metadata: metadata(sessionID: sessionID, sequence: next, at: receivedAt, monotonicTime: monotonicTime),
            coordinate: coordinate, horizontalAccuracy: horizontalAccuracy,
            observedAt: observedAt, receivedAt: receivedAt
        )
        try performIO {
            try append(observation, to: sessionDirectory(sessionID).appendingPathComponent("locations.jsonl"))
            // Update state only after synchronization. A later manifest failure also
            // quarantines this instance; only fresh recovery may replay the journal.
            sequences[sessionID] = next
            record.observationCount += 1
            records[sessionID] = record
            try save(record)
        }
    }

    public func setState(sessionID: UUID, state: RecordingState, at: Date, productFinishMethod: String? = nil) throws -> SessionRecord {
        try prepare()
        try validate(at)
        var record = try requireRecord(sessionID)
        if record.state == state { return record }
        guard !record.state.isClosed else { throw SessionStorageError.invalidTransition }
        record.state = state
        record.endedAt = state.isClosed ? at : nil
        if let productFinishMethod {
            guard state.isClosed, ["all_points", "finish_last_point", "interrupted", "inactivity"].contains(productFinishMethod)
            else { throw SessionStorageError.invalidTransition }
            record.productFinishMethod = productFinishMethod
        }
        try commitEvent(record: record, kind: .stateChanged, at: at, state: state,
                        reason: productFinishMethod.map { "productFinish:\($0)" })
        return record
    }

    public func markVisited(sessionID: UUID, poiID: String, at: Date) throws -> SessionRecord {
        try prepare()
        try validate(at)
        var record = try requireRecord(sessionID)
        guard !record.state.isClosed else { throw SessionStorageError.invalidTransition }
        guard record.route.pois.contains(where: { $0.id == poiID }) else { throw SessionStorageError.unknownPOI }
        if record.manualVisitedPOIIDs.contains(poiID) { return record }
        record.manualVisitedPOIIDs.append(poiID)
        try commitEvent(record: record, kind: .manualVisit, at: at, poiID: poiID)
        return record
    }

    public func markAutomaticallyVisited(sessionID: UUID, poiID: String, evidence: AutomaticVisitEvidence) throws -> SessionRecord {
        try prepare(); try validate(evidence.detectedAt)
        var record = try requireRecord(sessionID)
        guard record.state == .recording else { throw SessionStorageError.notRecording }
        guard let poi = record.route.pois.first(where: { $0.id == poiID }) else { throw SessionStorageError.unknownPOI }
        guard poi.visitRadiusMeters == evidence.radiusMeters, poi.minimumDwellSeconds == evidence.requiredDwellSeconds,
              evidence.observedDwellSeconds.isFinite, evidence.observedDwellSeconds >= evidence.requiredDwellSeconds,
              evidence.accuracyMeters.isFinite, evidence.accuracyMeters >= 0 else { throw SessionStorageError.invalidAccuracy }
        guard !record.visitedPOIIDs.contains(poiID), !(record.manualSkippedPOIIDs ?? []).contains(poiID) else { return record }
        record.autoVisitedPOIIDs = (record.autoVisitedPOIIDs ?? []) + [poiID]
        try commitEvent(record: record, kind: .automaticVisit, at: evidence.detectedAt, poiID: poiID, visitEvidence: evidence)
        return record
    }

    public func read(sessionID: UUID) throws -> SessionRecord {
        try prepare()
        return try requireRecord(sessionID)
    }

    /// Rebuild the same descriptive estimate used live. Never bridge a pause,
    /// process segment or invalid sample; absent usable pairs remain unknown.
    public func distanceEstimate(sessionID: UUID) throws -> Double? {
        try prepare()
        _ = try requireRecord(sessionID)
        let directory = sessionDirectory(sessionID)
        let events: ([SessionEvent], Int) = try readJSONLines(at: directory.appendingPathComponent("events.jsonl"))
        let locations: ([LocationObservation], Int) = try readJSONLines(at: directory.appendingPathComponent("locations.jsonl"))
        let states = Dictionary(uniqueKeysWithValues: events.0.map { ($0.metadata.sequence, $0) })
        let observations = Dictionary(uniqueKeysWithValues: locations.0.map { ($0.metadata.sequence, $0) })
        let sequences = (Array(states.keys) + Array(observations.keys)).sorted()
        var distance = WalkDistanceAccumulator()
        var recording = false
        for sequence in sequences {
            if let event = states[sequence] {
                if let state = event.state {
                    recording = state == .recording
                    distance.resetContinuity()
                } else if event.kind == .recovered { distance.resetContinuity() }
            } else if let sample = observations[sequence], recording {
                distance.observe(coordinate: sample.coordinate, accuracy: sample.horizontalAccuracy,
                    observedAt: sample.observedAt, receivedAt: sample.receivedAt, segmentID: sample.metadata.segmentID)
            }
        }
        return distance.meters
    }

    public func markSkipped(sessionID: UUID, poiID: String, at: Date) throws -> SessionRecord {
        try prepare(); try validate(at)
        var record = try requireRecord(sessionID)
        guard record.state == .recording else { throw SessionStorageError.notRecording }
        guard record.route.pois.contains(where: { $0.id == poiID }) else { throw SessionStorageError.unknownPOI }
        guard !(record.manualSkippedPOIIDs ?? []).contains(poiID), !record.visitedPOIIDs.contains(poiID) else { return record }
        record.manualSkippedPOIIDs = (record.manualSkippedPOIIDs ?? []) + [poiID]
        try commitEvent(record: record, kind: .manualSkip, at: at, poiID: poiID)
        return record
    }

    public func list() throws -> [SessionRecord] {
        try prepare()
        return records.values.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Fresh-store recovery first marks an interrupted process as closed so
    /// normal readers never assume continuity. The app can explicitly expose
    /// the latest restart-interrupted session as paused, without sensors.
    public func restoreLatestInterruptedAsPaused(at: Date) throws -> PausedSessionRecovery? {
        try prepare(); try validate(at)
        guard var record = records.values.max(by: { $0.startedAt < $1.startedAt }),
              record.state == .interrupted, record.productFinishMethod == nil else { return nil }
        let directory = sessionDirectory(record.id)
        let journal: ([SessionEvent], Int) = try readJSONLines(at: directory.appendingPathComponent("events.jsonl"))
        guard let last = journal.0.max(by: { $0.metadata.sequence < $1.metadata.sequence }),
              last.kind == .recovered, last.reason?.hasPrefix("appRestart;") == true else { return nil }
        let lastExplicit = journal.0.filter { $0.kind == .created || $0.kind == .stateChanged }
            .max(by: { $0.metadata.sequence < $1.metadata.sequence })
        let pause = lastExplicit?.state == .paused ? lastExplicit?.metadata : nil
        record.state = .paused; record.endedAt = nil
        try commitEvent(record: record, kind: .recovered, at: at, state: .paused,
                        reason: "restoredPaused; continuity=unknown; sensors=off")
        return PausedSessionRecovery(record: record, explicitPauseMetadata: pause,
            hasResearchJournal: fileManager.fileExists(atPath: directory.appendingPathComponent("research.jsonl").path))
    }

    /// Optional, opt-in shadow study. Separate journal never affects product
    /// completion/visits and is included only in an explicit local export.
    public func beginResearch(_ manifest: ResearchManifest) throws {
        try prepare()
        let record = try requireRecord(manifest.sessionID)
        guard record.state == .recording else { throw SessionStorageError.notRecording }
        try performIO {
            let directory = sessionDirectory(manifest.sessionID)
            try encoder().encode(manifest).write(to: directory.appendingPathComponent("research.json"), options: .atomic)
            try protect(directory.appendingPathComponent("research.json"))
            try writeJSONLines([ResearchEvent](), to: directory.appendingPathComponent("research.jsonl"))
        }
    }

    public func saveFeedback(sessionID: UUID, feedback: WalkFeedback) throws {
        try prepare()
        let record = try requireRecord(sessionID)
        guard record.state.isClosed, (1...5).contains(feedback.rating) else { throw SessionStorageError.invalidTransition }
        try performIO {
            let file = sessionDirectory(sessionID).appendingPathComponent("feedback.json")
            try encoder().encode(feedback).write(to: file, options: .atomic)
            try protect(file)
        }
    }

    public func saveFeedbackSkip(sessionID: UUID, at: Date) throws {
        try prepare()
        try validate(at)
        let record = try requireRecord(sessionID)
        guard record.state.isClosed else { throw SessionStorageError.invalidTransition }
        try performIO {
            let file = sessionDirectory(sessionID).appendingPathComponent("feedback_decision.json")
            try encoder().encode(WalkFeedbackDecision(sessionID: sessionID, at: at)).write(to: file, options: .atomic)
            try protect(file)
        }
    }

    public func appendResearch(sessionID: UUID, event: ResearchEvent) throws {
        try prepare()
        _ = try requireRecord(sessionID)
        guard event.elapsed.isFinite, event.elapsed >= 0, event.monotonicTime.isFinite,
              event.sequence > 0 else { throw SessionStorageError.invalidTime }
        try performIO {
            try append(event, to: sessionDirectory(sessionID).appendingPathComponent("research.jsonl"))
        }
    }

    /// Returns three files in a new unique export folder. No network operation is
    /// performed, and the internal data directory is never exposed to a share UI.
    public func export(sessionID: UUID, to directory: URL) throws -> [URL] {
        try prepare()
        let record = try requireRecord(sessionID)
        guard record.state.isClosed else { throw SessionStorageError.exportRequiresClosedSession }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedDestination = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedDestination != resolvedRoot, !resolvedDestination.hasPrefix(resolvedRoot + "/") else {
            throw SessionStorageError.exportInsideStorage
        }
        return try performIO {
            try save(record)
            let destination = directory.appendingPathComponent("walk_\(sessionID.uuidString)_\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            var filenames = ["session.json", "events.jsonl", "locations.jsonl"]
            if fileManager.fileExists(atPath: sessionDirectory(sessionID).appendingPathComponent("feedback.json").path) {
                filenames.append("feedback.json")
            }
            if fileManager.fileExists(atPath: sessionDirectory(sessionID).appendingPathComponent("feedback_decision.json").path) {
                filenames.append("feedback_decision.json")
            }
            let studyFile = sessionDirectory(sessionID).appendingPathComponent("research.jsonl")
            if fileManager.fileExists(atPath: studyFile.path) {
                let study: ([ResearchEvent], Int) = try readJSONLines(at: studyFile)
                let report = ResearchMetrics.calculate(study.0)
                let reportFile = sessionDirectory(sessionID).appendingPathComponent("research_metrics.json")
                try encoder().encode(report).write(to: reportFile, options: .atomic)
                try protect(reportFile)
                filenames += ["research.json", "research.jsonl", "research_metrics.json"]
            }
            var files: [URL] = []
            for filename in filenames {
                let target = destination.appendingPathComponent(filename)
                try fileManager.copyItem(at: sessionDirectory(sessionID).appendingPathComponent(filename), to: target)
                files.append(target)
            }
            return files
        }
    }

    private func prepare() throws {
        try ensureUsable()
        guard !loaded else { return }
        try performIO { try recover() }
    }

    private func recover() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try protect(root)
        let directories = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        // Load committed records and recover only torn trailing lines. A damaged
        // complete line is an error, never silently discarded.
        var recovered: [(SessionRecord, Int, Int)] = []
        for directory in directories {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let manifest = directory.appendingPathComponent("session.json")
            guard fileManager.fileExists(atPath: manifest.path) else { continue }
            var record = try decoder().decode(SessionRecord.self, from: Data(contentsOf: manifest))
            guard directory.lastPathComponent == record.id.uuidString, record.schemaVersion == 1 else {
                throw SessionStorageError.corruptData(manifest.lastPathComponent)
            }
            try record.route.validate()
            let events: ([SessionEvent], Int) = try readJSONLines(at: directory.appendingPathComponent("events.jsonl"))
            let locations: ([LocationObservation], Int) = try readJSONLines(at: directory.appendingPathComponent("locations.jsonl"))
            let allMetadata = events.0.map(\.metadata) + locations.0.map(\.metadata)
            guard allMetadata.allSatisfy({ $0.sessionID == record.id && $0.sequence > 0 && $0.schemaVersion == 1 }),
                  Set(allMetadata.map(\.sequence)).count == allMetadata.count,
                  Set(allMetadata.map(\.id)).count == allMetadata.count,
                  allMetadata.map(\.sequence).sorted() == Array(1...(max(1, allMetadata.count))),
                  events.0.first?.kind == .created else {
                throw SessionStorageError.corruptData(directory.lastPathComponent)
            }
            record.observationCount = locations.0.count
            record.manualVisitedPOIIDs = []
            record.manualSkippedPOIIDs = nil
            record.autoVisitedPOIIDs = nil
            for event in events.0.sorted(by: { $0.metadata.sequence < $1.metadata.sequence }) {
                if let state = event.state {
                    record.state = state
                    record.endedAt = state.isClosed ? (event.endedAt ?? event.metadata.recordedAt) : nil
                }
                if let reason = event.reason, reason.hasPrefix("productFinish:") {
                    record.productFinishMethod = String(reason.dropFirst("productFinish:".count))
                }
                if event.kind == .manualVisit, let poiID = event.poiID,
                   !record.manualVisitedPOIIDs.contains(poiID) { record.manualVisitedPOIIDs.append(poiID) }
                if event.kind == .automaticVisit, let poiID = event.poiID,
                   !(record.autoVisitedPOIIDs ?? []).contains(poiID) {
                    record.autoVisitedPOIIDs = (record.autoVisitedPOIIDs ?? []) + [poiID]
                }
                if event.kind == .manualSkip, let poiID = event.poiID,
                   !(record.manualSkippedPOIIDs ?? []).contains(poiID) {
                    record.manualSkippedPOIIDs = (record.manualSkippedPOIIDs ?? []) + [poiID]
                }
            }
            // The first slice has no automatic completion classifier.
            record.completionLabel = "unknown"
            recovered.append((record, allMetadata.map(\.sequence).max() ?? 0, events.1 + locations.1))
        }
        for (var record, sequence, discardedBytes) in recovered {
            records[record.id] = record
            sequences[record.id] = sequence
            if !record.state.isClosed {
                record.state = .interrupted
                // Restart time is not the last known moment the user was walking.
                // endedAt remains the last persisted observation/event time.
                let interruptionTime = try latestRecordedDate(for: record.id) ?? record.startedAt
                record.endedAt = interruptionTime
                try commitEvent(record: record, kind: .recovered, at: Date(), state: .interrupted,
                                reason: "appRestart; preservedPartialBytes=\(discardedBytes); continuity=unknown")
            } else {
                try save(record)
                if discardedBytes > 0 {
                    try commitEvent(record: record, kind: .recovered, at: Date(),
                                    reason: "preservedPartialBytes=\(discardedBytes)")
                }
            }
        }
        loaded = true
    }

    private func latestRecordedDate(for id: UUID) throws -> Date? {
        let directory = sessionDirectory(id)
        let events: ([SessionEvent], Int) = try readJSONLines(at: directory.appendingPathComponent("events.jsonl"))
        let locations: ([LocationObservation], Int) = try readJSONLines(at: directory.appendingPathComponent("locations.jsonl"))
        return (events.0.map(\.metadata) + locations.0.map(\.metadata))
            .max(by: { $0.sequence < $1.sequence })?.recordedAt
    }

    private func commitEvent(
        record: SessionRecord, kind: SessionEvent.Kind, at: Date,
        state: RecordingState? = nil, poiID: String? = nil, reason: String? = nil,
        visitEvidence: AutomaticVisitEvidence? = nil
    ) throws {
        let next = (sequences[record.id] ?? 0) + 1
        let event = SessionEvent(metadata: metadata(sessionID: record.id, sequence: next, at: at),
                                 kind: kind, state: state, endedAt: record.endedAt, poiID: poiID, reason: reason, visitEvidence: visitEvidence)
        try performIO {
            try append(event, to: sessionDirectory(record.id).appendingPathComponent("events.jsonl"))
            sequences[record.id] = next
            records[record.id] = record
            try save(record)
        }
    }

    private func metadata(sessionID: UUID, sequence: Int, at: Date, monotonicTime: Double? = nil) -> SessionLogMetadata {
        SessionLogMetadata(schemaVersion: 1, id: UUID(), sessionID: sessionID, segmentID: segmentID,
                           sequence: sequence, recordedAt: at,
                           monotonicTime: monotonicTime ?? ProcessInfo.processInfo.systemUptime)
    }

    private func requireRecord(_ id: UUID) throws -> SessionRecord {
        guard let record = records[id] else { throw SessionStorageError.unknownSession }
        return record
    }

    private func ensureUsable() throws {
        guard !quarantined else { throw LocalSessionStoreError.quarantined }
    }

    /// Never compensate by appending an "interrupted" event after uncertain I/O:
    /// that could reuse a sequence already written by the failed operation.
    private func performIO<T>(_ operation: () throws -> T) throws -> T {
        try ensureUsable()
        do { return try operation() }
        catch {
            quarantined = true
            throw error
        }
    }

    private func validate(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw SessionStorageError.invalidTime }
    }

    private func sessionDirectory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func encoder() -> JSONEncoder {
        let result = JSONEncoder()
        result.dateEncodingStrategy = .millisecondsSince1970
        result.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return result
    }

    private func decoder() -> JSONDecoder {
        let result = JSONDecoder()
        result.dateDecodingStrategy = .millisecondsSince1970
        return result
    }

    private func save(_ record: SessionRecord) throws {
        let file = sessionDirectory(record.id).appendingPathComponent("session.json")
        try encoder().encode(record).write(to: file, options: .atomic)
        try protect(file)
    }

    private func writeJSONLines<T: Encodable>(_ values: [T], to file: URL) throws {
        var data = Data()
        for value in values { data.append(try encoder().encode(value)); data.append(0x0A) }
        try data.write(to: file, options: .atomic)
        try protect(file)
    }

    private func append<T: Encodable>(_ value: T, to file: URL) throws {
        var data = try encoder().encode(value)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try afterJournalWrite?()
        try handle.synchronize()
        try handle.close()
    }

    /// Only a torn trailing line is recoverable. Complete malformed lines fail.
    /// Preserve the exact torn bytes for diagnosis before trimming the active
    /// journal. If preservation fails, leave the journal intact and quarantine.
    private func readJSONLines<T: Decodable>(at file: URL) throws -> ([T], Int) {
        let data = try Data(contentsOf: file)
        let completeLength = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        var values: [T] = []
        for line in data.prefix(completeLength).split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
            guard !line.isEmpty else { throw SessionStorageError.corruptData(file.lastPathComponent) }
            do { values.append(try decoder().decode(T.self, from: Data(line))) }
            catch { throw SessionStorageError.corruptData(file.lastPathComponent) }
        }
        let discardedBytes = data.count - completeLength
        if discardedBytes > 0 {
            let diagnostics = file.deletingLastPathComponent().appendingPathComponent("recovery_diagnostics", isDirectory: true)
            try fileManager.createDirectory(at: diagnostics, withIntermediateDirectories: true)
            try protect(diagnostics)
            let diagnostic = diagnostics.appendingPathComponent("\(file.lastPathComponent).torn-\(UUID().uuidString).bin")
            try data.suffix(discardedBytes).write(to: diagnostic, options: .atomic)
            try protect(diagnostic)
            let diagnosticHandle = try FileHandle(forWritingTo: diagnostic)
            defer { try? diagnosticHandle.close() }
            try diagnosticHandle.synchronize()
            try diagnosticHandle.close()
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(completeLength))
            try handle.synchronize()
            try handle.close()
        }
        return (values, discardedBytes)
    }

    private func protect(_ url: URL) throws {
        #if os(iOS)
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
