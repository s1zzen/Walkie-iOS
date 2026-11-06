import Combine
import Foundation
import WalkieCore
import UIKit

/// App-scoped: жизненный цикл записи не связан с появлением и исчезновением экрана.
@MainActor
final class WalkSessionCoordinator: ObservableObject {
    @Published private(set) var record: SessionRecord?
    @Published private(set) var latestObservation: SensorObservation?
    @Published private(set) var sensorStatus = "Геолокация включится только при старте прогулки"
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var storageUnavailable = false
    @Published var researchEnabled = false
    @Published private(set) var researchActive = false
    @Published private(set) var researchMarkerCount = 0
    @Published private(set) var latestMotion: ResearchMotion?
    @Published private(set) var researchMetrics: ResearchMetricsReport?
    @Published private(set) var syncStatus: String?
    @Published private(set) var distanceEstimateMeters: Double?
    @Published private(set) var guidanceState = ResearchState.uncertain
    @Published private(set) var productFinishMethod: String?
    struct AutomaticVisitNotice: Identifiable {
        let id = UUID()
        let poi: RoutePOI
        let evidence: AutomaticVisitEvidence
    }
    @Published private(set) var automaticVisitNotice: AutomaticVisitNotice?
    @Published private(set) var pauseTimeoutAt: Date?
    @Published private(set) var recoveryMessage: String?
    @Published private(set) var researchRecoveryReadOnly = false
    @Published private(set) var feedbackSaved = false
    private(set) var pauseTimeoutSeconds: Double
    var onProductEvent: ((String, [String: String]) -> Void)?
    @Published private(set) var completionMessage: String?
    private let store: LocalSessionStore
    private let sensors: any SensorSource
    private let motion: (any MotionSource)?
    private let productSync: ProductWalkSync?
    private var distance = WalkDistanceAccumulator()
    private var study: PairedResearchDetector?
    private var studyEvents: [ResearchEvent] = []
    private var studyStart = 0.0
    private var studySequence = 0
    private var heartbeatTask: Task<Void, Never>?
    private var pauseTimeoutTask: Task<Void, Never>?
    private var pauseDeadline: ContinuousClock.Instant?
    private var automaticVisits = AutomaticVisitDetector()
    private var pendingWrite: Task<Void, Never>?
    private var generation = UUID()
    private var lastTelemetryObservationAt: Date?
    private var candidateStepAnchor: ResearchMotion?
    private var offRouteEpisode = false
    private var explicitPauseStartedAt: ContinuousClock.Instant?

    init(store: LocalSessionStore, sensors: any SensorSource, motion: (any MotionSource)? = nil,
         productSync: ProductWalkSync? = nil, pauseTimeoutSeconds: Double = 1_800) {
        self.store = store
        self.sensors = sensors
        self.motion = motion
        self.productSync = productSync
        self.pauseTimeoutSeconds = pauseTimeoutSeconds.isFinite && pauseTimeoutSeconds > 0 ? pauseTimeoutSeconds : 1_800
        sensors.onObservation = { [weak self] in self?.receive($0) }
        sensors.onStatus = { [weak self] in self?.sensorStatus = $0 }
        motion?.onMotion = { [weak self] in self?.receiveMotion($0) }
    }

    var hasOpenSession: Bool {
        guard let state = record?.state else { return false }
        return state == .recording || state == .paused
    }

    /// Apply server configuration without granting a fresh full timeout to an
    /// already paused walk. Invalid configuration preserves the last value.
    func configurePauseTimeout(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        pauseTimeoutSeconds = seconds
        if record?.state == .paused, let started = explicitPauseStartedAt {
            let elapsed = started.duration(to: .now)
            let components = elapsed.components
            let secondsElapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
            schedulePauseTimeout(after: max(0, seconds - secondsElapsed))
        }
    }

    func restoreLatestSessionIfNeeded() async {
        guard record == nil, !isBusy, !storageUnavailable else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let recovery = try await store.restoreLatestInterruptedAsPaused(at: Date()) else { return }
            record = recovery.record
            feedbackSaved = false
            generation = UUID()
            automaticVisits.reset()
            distanceEstimateMeters = try await store.distanceEstimate(sessionID: recovery.record.id)
            distance = WalkDistanceAccumulator(initialMeters: distanceEstimateMeters)
            latestObservation = nil; latestMotion = nil
            study = nil; researchActive = false
            researchRecoveryReadOnly = recovery.hasResearchJournal
            recoveryMessage = recovery.hasResearchJournal
                ? "Исследовательская запись была прервана. Данные и метки сохранены. Закройте и экспортируйте её; новый пилот начните отдельной сессией."
                : "Незавершённая прогулка восстановлена на паузе. Пропуск работы приложения не считается движением или посещением. Возобновите запись явно."
            sensorStatus = "Восстановлена пауза. Датчики выключены."
            if let pause = recovery.explicitPauseMetadata {
                let wallAge = Date().timeIntervalSince(pause.recordedAt)
                let uptimeAge = ProcessInfo.processInfo.systemUptime - pause.monotonicTime
                // Reboot or clock adjustment makes a cross-process deadline
                // ambiguous. Never infer inactivity from that ambiguity.
                if wallAge >= 0, uptimeAge >= 0, abs(wallAge - uptimeAge) <= 5 {
                    explicitPauseStartedAt = ContinuousClock.now.advanced(by: .seconds(-uptimeAge))
                    schedulePauseTimeout(after: max(0, pauseTimeoutSeconds - uptimeAge))
                } else {
                    recoveryMessage = (recoveryMessage ?? "") + " Старый дедлайн паузы не восстановлен: непрерывность часов неизвестна."
                }
            }
        } catch { fail(error) }
    }

    func start(route: RoutePlan, kind: WalkStartKind = .regular) async {
        guard !isBusy, !hasOpenSession, !storageUnavailable else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        latestObservation = nil
        latestMotion = nil
        distanceEstimateMeters = nil
        distance = WalkDistanceAccumulator()
        syncStatus = nil
        productFinishMethod = nil
        completionMessage = nil
        feedbackSaved = false
        recoveryMessage = nil; researchRecoveryReadOnly = false
        pauseTimeoutTask?.cancel(); pauseTimeoutTask = nil; pauseDeadline = nil; pauseTimeoutAt = nil; explicitPauseStartedAt = nil
        lastTelemetryObservationAt = nil; candidateStepAnchor = nil; offRouteEpisode = false
        automaticVisits.reset(); automaticVisitNotice = nil
        researchMetrics = nil
        researchMarkerCount = 0
        studyEvents = []
        studySequence = 0
        do {
            record = try await store.create(route: route, at: Date(), kind: kind)
            if let record, let productSync {
                do { try await productSync.start(record) }
                catch { syncStatus = "Прогулка сохранена локально. Постановка синхронизации не удалась: \(userFacingError(error))" }
            }
            generation = UUID()
            studyStart = ProcessInfo.processInfo.systemUptime
            study = PairedResearchDetector(route: route)
            guidanceState = .uncertain
            researchActive = researchEnabled
            if researchActive, let record {
                try await store.beginResearch(ResearchManifest(sessionID: record.id, configuration: .init(),
                    startedAt: record.startedAt, monotonicStart: studyStart,
                    systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                    device: UIDevice.current.model))
            }
            startHeartbeat()
            sensors.start()
            motion?.start()
        } catch { fail(error) }
    }

    func pause() async { await transition(to: .paused) }
    @discardableResult
    func complete(atLastPoint: Bool = false) async -> Bool {
        guard let record, hasOpenSession, !isBusy,
              let result = WalkCompletionPolicy.completion(for: record, atLastPoint: atLastPoint) else {
            completionMessage = "Для завершения посети оставшиеся непропущенные места или заверши на последней точке. Если все места пропущены, выбери «Прервать прогулку»."
            return false
        }
        completionMessage = nil
        await transition(to: result.state, forcedFinishMethod: result.method)
        return self.record?.state == .finished
    }

    func interrupt() async { await transition(to: .interrupted, forcedFinishMethod: "interrupted") }

    /// Compatibility for callers that used Finish to stop recording. New UI
    /// actions must explicitly distinguish complete from interrupt.
    func finish(atLastPoint: Bool = false) async {
        if let record, WalkCompletionPolicy.completion(for: record, atLastPoint: atLastPoint) != nil {
            _ = await complete(atLastPoint: atLastPoint)
        } else { await interrupt() }
    }

    func resume() async {
        guard !isBusy, let record, record.state == .paused else { return }
        guard !researchRecoveryReadOnly else {
            recoveryMessage = "Прерванный исследовательский лог доступен для завершения и экспорта. Для нового прохода нужна отдельная сессия."
            return
        }
        if let deadline = pauseDeadline, ContinuousClock.now >= deadline {
            await transition(to: .interrupted, forcedFinishMethod: "inactivity")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            self.record = try await store.setState(sessionID: record.id, state: .recording, at: Date())
            pauseTimeoutTask?.cancel(); pauseTimeoutTask = nil; pauseDeadline = nil; pauseTimeoutAt = nil; explicitPauseStartedAt = nil
            latestObservation = nil
            latestMotion = nil
            distance.resetContinuity()
            candidateStepAnchor = nil; offRouteEpisode = false
            automaticVisits.reset()
            generation = UUID()
            study?.resetAfterPause()
            if study == nil {
                studyStart = ProcessInfo.processInfo.systemUptime
                study = PairedResearchDetector(route: record.route)
                startHeartbeat()
            }
            guidanceState = .uncertain
            if researchActive { enqueueStudyEvent(kind: .resume) }
            sensors.start()
            motion?.start()
        } catch { fail(error) }
    }

    func markVisited(poiID: String) async {
        guard !isBusy, let record, record.state == .recording, !record.visitedPOIIDs.contains(poiID) else { return }
        // Выстраиваем ручное событие после уже доставленных наблюдений.
        isBusy = true
        defer { isBusy = false }
        let previous = pendingWrite
        let token = generation
        let operation = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == token, self.record?.state == .recording,
                  !(self.record?.visitedPOIIDs ?? []).contains(poiID) else { return }
            do {
                let updated = try await self.store.markVisited(sessionID: record.id, poiID: poiID, at: Date())
                guard self.generation == token, self.record?.id == record.id else { return }
                self.record = updated
                if let productSync = self.productSync {
                    do { try await productSync.checkpoint(updated, poiID: poiID, skipped: false, at: Date()) }
                    catch { self.syncStatus = "Отметка сохранена локально; очередь синхронизации недоступна." }
                }
            } catch { self.fail(error) }
        }
        pendingWrite = operation
        await operation.value
        isBusy = false
        await completeAutomaticallyIfEligible()
    }

    func markSkipped(poiID: String) async {
        guard !isBusy, let record, record.state == .recording,
              !(record.manualSkippedPOIIDs ?? []).contains(poiID), !record.visitedPOIIDs.contains(poiID) else { return }
        isBusy = true
        defer { isBusy = false }
        await pendingWrite?.value
        guard self.record?.state == .recording,
              !(self.record?.visitedPOIIDs ?? []).contains(poiID),
              !(self.record?.manualSkippedPOIIDs ?? []).contains(poiID) else { return }
        do {
            let updated = try await store.markSkipped(sessionID: record.id, poiID: poiID, at: Date())
            self.record = updated
            if let productSync {
                do { try await productSync.checkpoint(updated, poiID: poiID, skipped: true, at: Date()) }
                catch { syncStatus = "Пропуск сохранён локально; очередь синхронизации недоступна." }
            }
            isBusy = false
            await completeAutomaticallyIfEligible()
        }
        catch { fail(error) }
    }

    func exportCurrentSession() async -> [URL] {
        guard let record, record.state.isClosed, !isBusy, !storageUnavailable else { return [] }
        isBusy = true
        defer { isBusy = false }
        do {
            return try await store.export(sessionID: record.id,
                to: FileManager.default.temporaryDirectory.appendingPathComponent("WalkieExports", isDirectory: true))
        } catch { errorMessage = userFacingError(error); return [] }
    }

    func saveFeedback(rating: Int, comment: String) async -> Bool {
        guard let record, record.state.isClosed, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await store.saveFeedback(sessionID: record.id, feedback: WalkFeedback(rating: rating, comment: String(comment.prefix(2_000))))
            feedbackSaved = true
            if let productSync {
                do { try await productSync.rating(record, stars: rating, comment: comment) }
                catch { syncStatus = "Оценка сохранена локально; очередь синхронизации недоступна." }
            }
            return true
        } catch { errorMessage = userFacingError(error); return false }
    }

    func skipFeedback() async -> Bool {
        guard let record, record.state.isClosed, !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            // Local acceptance is authoritative for leaving S-24. A broken or
            // offline product outbox must not trap the user on the summary.
            try await store.saveFeedbackSkip(sessionID: record.id, at: Date())
            if let productSync {
                do { try await productSync.skipRating(record) }
                catch { syncStatus = "Пропуск оценки сохранён локально; очередь синхронизации недоступна." }
            }
            return true
        } catch { errorMessage = userFacingError(error); return false }
    }

    private func transition(to state: RecordingState, forcedFinishMethod: String? = nil) async {
        guard !isBusy, let record, hasOpenSession else { return }
        if state == .paused && record.state != .recording { return }
        isBusy = true
        defer { isBusy = false }
        sensors.stop()
        motion?.stop()
        automaticVisits.reset()
        distance.resetContinuity()
        candidateStepAnchor = nil; offRouteEpisode = false
        await pendingWrite?.value
        guard self.record?.state != .interrupted else { return }
        if researchActive {
            enqueueStudyEvent(kind: state == .paused ? .pause : .finish)
            await pendingWrite?.value
            if state.isClosed { researchMetrics = ResearchMetrics.calculate(studyEvents) }
        }
        generation = UUID()
        do {
            if state.isClosed {
                productFinishMethod = forcedFinishMethod ?? (state == .finished ? "all_points" : "interrupted")
            }
            self.record = try await store.setState(sessionID: record.id, state: state, at: Date(), productFinishMethod: productFinishMethod)
            if state.isClosed, let updated = self.record, let productSync {
                do {
                    try await productSync.finish(updated, method: productFinishMethod ?? "interrupted", distanceEstimateMeters: distanceEstimateMeters)
                    syncStatus = await productSync.lastProblem
                } catch { syncStatus = "Итог сохранён локально; очередь синхронизации недоступна." }
            }
            sensorStatus = state == .paused ? "Пауза: координаты не записываются" : "Запись завершена. Датчики выключены."
            if state == .paused { explicitPauseStartedAt = .now; schedulePauseTimeout() }
            if state.isClosed {
                heartbeatTask?.cancel(); heartbeatTask = nil; researchActive = false
                pauseTimeoutTask?.cancel(); pauseTimeoutTask = nil; pauseDeadline = nil; pauseTimeoutAt = nil; explicitPauseStartedAt = nil
            }
        } catch { fail(error) }
    }

    private func receive(_ sample: SensorObservation) {
        guard let record, record.state == .recording else { return }
        latestObservation = sample
        updateDistanceEstimate(sample)
        let elapsed = max(0, sample.monotonicTime - studyStart)
        let pair = study?.observe(coordinate: sample.coordinate, accuracy: sample.accuracy,
            observedAt: sample.observedAt, receivedAt: sample.receivedAt, elapsed: elapsed, motion: latestMotion)
        guidanceState = pair?.b1.state ?? .uncertain
        recordProductDecisions(sample: sample, pair: pair)
        var candidateVisit: (RoutePOI, AutomaticVisitEvidence)?
        if !researchActive, let poi = record.route.pois.first(where: {
            !record.visitedPOIIDs.contains($0.id) && !(record.manualSkippedPOIIDs ?? []).contains($0.id)
        }), let evidence = automaticVisits.observe(poi: poi, coordinate: sample.coordinate, accuracy: sample.accuracy,
            observedAt: sample.observedAt, receivedAt: sample.receivedAt, monotonicTime: sample.monotonicTime,
            qualityAccepted: pair?.b1.state == .onRoute) {
            candidateVisit = (poi, evidence)
        }
        let visit = candidateVisit
        if researchActive {
            enqueueStudyEvent(kind: .location, coordinate: sample.coordinate, accuracy: sample.accuracy,
                observedAt: sample.observedAt, pair: pair, at: sample.receivedAt, uptime: sample.monotonicTime)
        }
        let previous = pendingWrite
        let token = generation
        pendingWrite = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == token, self.record?.state == .recording else { return }
            do {
                try await self.store.appendLocation(
                    sessionID: record.id, coordinate: sample.coordinate, horizontalAccuracy: sample.accuracy,
                    observedAt: sample.observedAt, receivedAt: sample.receivedAt, monotonicTime: sample.monotonicTime
                )
                self.record?.observationCount += 1
                if let (poi, evidence) = visit, !self.researchActive,
                   !(self.record?.visitedPOIIDs ?? []).contains(poi.id),
                   !(self.record?.manualSkippedPOIIDs ?? []).contains(poi.id) {
                    let updated = try await self.store.markAutomaticallyVisited(sessionID: record.id, poiID: poi.id, evidence: evidence)
                    self.record = updated
                    self.automaticVisitNotice = AutomaticVisitNotice(poi: poi, evidence: evidence)
                    if let productSync = self.productSync {
                        do { try await productSync.checkpoint(updated, poiID: poi.id, skipped: false, at: evidence.detectedAt, evidence: evidence) }
                        catch { self.syncStatus = "Автоотметка сохранена локально; очередь синхронизации недоступна." }
                    }
                    if WalkCompletionPolicy.allRequiredVisited(in: updated) {
                        Task { await self.completeAutomaticallyIfEligible() }
                    }
                }
            } catch { self.fail(error) }
        }
    }

    private func fail(_ error: Error) {
        sensors.stop()
        motion?.stop()
        heartbeatTask?.cancel(); heartbeatTask = nil
        pauseTimeoutTask?.cancel(); pauseTimeoutTask = nil; pauseDeadline = nil; pauseTimeoutAt = nil
        generation = UUID()
        storageUnavailable = true
        researchActive = false
        record?.state = .interrupted
        errorMessage = "Запись остановлена: \(userFacingError(error)). Новая запись заблокирована. Освободите место при необходимости и перезапустите приложение для восстановления журналов. Экспорт до восстановления не гарантируется."
        sensorStatus = "Запись прервана"
    }

    /// Only an observer's independent knowledge should be recorded here. The
    /// detector state and GPS coordinate are deliberately absent from this API.
    func labelResearch(geometry: ResearchGeometry, intent: ResearchIntent, note: String) async {
        guard researchActive, hasOpenSession else { return }
        enqueueStudyEvent(kind: .label, geometry: geometry, intent: intent, note: String(note.prefix(1_000)))
        researchMarkerCount += 1
        await pendingWrite?.value
    }

    private func receiveMotion(_ sample: ResearchMotion) {
        guard record?.state == .recording else { return }
        latestMotion = sample
        if researchActive {
            enqueueStudyEvent(kind: .motion, motion: sample, at: sample.receivedAt, uptime: sample.monotonicTime)
        }
    }

    private func updateDistanceEstimate(_ sample: SensorObservation) {
        distance.observe(coordinate: sample.coordinate, accuracy: sample.accuracy,
            observedAt: sample.observedAt, receivedAt: sample.receivedAt, segmentID: generation)
        distanceEstimateMeters = distance.meters
    }

    private func completeAutomaticallyIfEligible() async {
        guard let record, hasOpenSession, !isBusy, !storageUnavailable,
              WalkCompletionPolicy.allRequiredVisited(in: record) else { return }
        _ = await complete()
    }

    private func recordProductDecisions(sample: SensorObservation, pair: ResearchPair?) {
        guard !researchActive, let record, let pair else { return }
        let context = ["walk_id": record.id.uuidString, "route_id": record.route.routeID, "route_version_id": record.route.id]
        if guidanceState == .offRoute { offRouteEpisode = true }
        else if guidanceState == .onRoute, offRouteEpisode {
            onProductEvent?("off_route_self_return", context)
            offRouteEpisode = false
        }
        guard sample.coordinate.isValid,
              lastTelemetryObservationAt.map({ sample.observedAt > $0 }) ?? true else { return }
        lastTelemetryObservationAt = sample.observedAt
        let rawDistance = ResearchDistance.toRoute(sample.coordinate, route: record.route)
        guard rawDistance.isFinite, rawDistance > (study?.configuration.enterMeters ?? 25) else {
            candidateStepAnchor = nil; return
        }
        if candidateStepAnchor == nil, pair.freshSteps { candidateStepAnchor = latestMotion }
        var measurements = context.merging(["distance_m": String(rawDistance), "accuracy_m": String(sample.accuracy)]) { old, _ in old }
        if pair.freshSteps, let origin = candidateStepAnchor, let latestMotion,
           latestMotion.steps >= origin.steps, latestMotion.measuredAt >= origin.measuredAt {
            measurements["steps_in_window"] = String(latestMotion.steps - origin.steps)
        }
        for (detector, decision) in [("A", pair.a), ("B1", pair.b1)] {
            onProductEvent?("off_route_candidate", measurements.merging([
                "detector": detector, "decision": decision.newAlert || decision.state == .offRoute ? "confirmed" : "rejected",
                "reason": decision.reason
            ]) { old, _ in old })
        }
    }

    private func schedulePauseTimeout(after seconds: Double? = nil) {
        pauseTimeoutTask?.cancel()
        let interval = seconds ?? pauseTimeoutSeconds
        let deadline = ContinuousClock.now.advanced(by: .seconds(interval))
        pauseDeadline = deadline
        pauseTimeoutAt = Date().addingTimeInterval(interval)
        pauseTimeoutTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard let self, self.record?.state == .paused, self.pauseDeadline == deadline else { return }
            // Deadline is tied only to the explicit Pause action. Lack of GPS,
            // missing steps or background suspension never starts this timer.
            if self.isBusy {
                // A local write may be finishing. Wait without converting a
                // recording session into inactivity due to callback silence.
                while self.isBusy, self.record?.state == .paused { await Task.yield() }
            }
            guard self.record?.state == .paused, self.pauseDeadline == deadline else { return }
            await self.transition(to: .interrupted, forcedFinishMethod: "inactivity")
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.hasOpenSession else { return }
                // Actual delivery time is written. Suspension creates an observed
                // gap, never imaginary heartbeat observations in the background.
                guard self.record?.state == .recording, !self.isBusy else { continue }
                let time = ProcessInfo.processInfo.systemUptime
                let pair = self.study?.heartbeat(at: max(0, time - self.studyStart))
                self.guidanceState = pair?.b1.state ?? .uncertain
                if self.researchActive { self.enqueueStudyEvent(kind: .heartbeat, pair: pair, uptime: time) }
            }
        }
    }

    private func enqueueStudyEvent(kind: ResearchEvent.Kind, coordinate: Coordinate? = nil,
        accuracy: Double? = nil, observedAt: Date? = nil, motion: ResearchMotion? = nil,
        pair: ResearchPair? = nil, geometry: ResearchGeometry? = nil,
        intent: ResearchIntent? = nil, note: String? = nil, at: Date = Date(), uptime: Double? = nil) {
        guard let record, researchActive else { return }
        let time = uptime ?? ProcessInfo.processInfo.systemUptime
        studySequence += 1
        let event = ResearchEvent(sequence: studySequence, elapsed: max(0, time - studyStart),
            recordedAt: at, monotonicTime: time, kind: kind, coordinate: coordinate, accuracy: accuracy,
            observedAt: observedAt, motion: motion, pair: pair, geometry: geometry, intent: intent, note: note)
        studyEvents.append(event)
        let previous = pendingWrite, token = generation
        pendingWrite = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == token else { return }
            do { try await self.store.appendResearch(sessionID: record.id, event: event) }
            catch { self.fail(error) }
        }
    }
}
