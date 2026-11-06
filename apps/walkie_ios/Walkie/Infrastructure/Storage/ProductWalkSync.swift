import Foundation
import WalkieCore

/// Durable product operations only. Raw locations, steps and research annotations
/// are absent from the outbox and wire schemas.
actor ProductWalkSync {
    private struct Job: Codable, Sendable {
        let id: UUID
        let ownerID: String
        let walkID: UUID
        let path: String
        let method: String
        let body: Data
    }
    private struct RegisteredWalk: Codable, Sendable {
        let ownerID: String
        let versionID: String
        let placeIDs: [String]
        var routeID: String?
        var startedAt: Date?
        var kind: String?
    }
    private struct State: Codable, Sendable {
        var jobs: [Job] = []
        var walks: [String: RegisteredWalk] = [:]
        var blockedFinishes: [String: BlockedFinish] = [:]
        var finishes: [String: ProductWalkFinishAcknowledgement] = [:]
        var problems: [String: String] = [:]
        var summaryDecisionIDs: Set<String> = []
        init() {}
        private enum CodingKeys: String, CodingKey { case jobs, walks, blockedFinishes, finishes, problems, summaryDecisionIDs }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            jobs = try values.decodeIfPresent([Job].self, forKey: .jobs) ?? []
            walks = try values.decodeIfPresent([String: RegisteredWalk].self, forKey: .walks) ?? [:]
            blockedFinishes = try values.decodeIfPresent([String: BlockedFinish].self, forKey: .blockedFinishes) ?? [:]
            finishes = try values.decodeIfPresent([String: ProductWalkFinishAcknowledgement].self, forKey: .finishes) ?? [:]
            problems = try values.decodeIfPresent([String: String].self, forKey: .problems) ?? [:]
            // A pending legacy rating/skip operation is durable evidence of the
            // S-24 decision. A finish acknowledgement alone is not.
            summaryDecisionIDs = try values.decodeIfPresent(Set<String>.self, forKey: .summaryDecisionIDs)
                ?? Set(jobs.filter { $0.path.hasSuffix("/rating") }.map { $0.walkID.uuidString })
        }
    }
    private struct BlockedFinish: Codable, Sendable {
        let endedAt: Date
        let method: String
        let reason: String
        var startedAt: Date?
    }
    private struct FinishResult: Decodable {
        struct Walk: Decodable {
            struct Progress: Decodable { let visited_orders: [Int]; let skipped_orders: [Int]; let total: Int }
            let id: UUID
            let route_id: String
            let version_id: String
            let kind: String
            let status: String
            let started_at: String
            let finish_method: String?
            let progress: Progress
        }
        let walk: Walk
        let show_pro_offer: Bool
    }

    private let url: URL
    private let metadataURL: URL
    private let client: any RouteBackendTransport
    private let owner: @Sendable () async -> String?
    private let sessionStore: LocalSessionStore?
    private let automaticallyFlush: Bool
    private var state: State
    private var flushing = false
    private var reconciling = false
    private var corrupt = false
    private(set) var lastProblem: String?

    init(url: URL, metadataURL: URL, client: any RouteBackendTransport = BackendClient.shared,
         owner: @escaping @Sendable () async -> String? = { await BackendClient.shared.currentSession()?.user_id },
         sessionStore: LocalSessionStore? = nil, automaticallyFlush: Bool = true) {
        self.url = url; self.metadataURL = metadataURL; self.client = client; self.owner = owner
        self.sessionStore = sessionStore
        self.automaticallyFlush = automaticallyFlush
        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(State.self, from: data) { state = saved }
            else { state = State(); corrupt = true }
        } else { state = State() }
    }

    func start(_ record: SessionRecord) async throws {
        guard !record.route.isDemo, state.walks[record.id.uuidString] == nil, let ownerID = await owner(),
              let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode([String: LiveRouteDetails].self, from: data),
              let route = metadata[record.route.id],
              UUID(uuidString: route.routeID) != nil, UUID(uuidString: route.versionID) != nil else { return }
        let previous = state
        state.walks[record.id.uuidString] = RegisteredWalk(ownerID: ownerID, versionID: route.versionID,
            placeIDs: record.route.pois.map(\.id), routeID: route.routeID, startedAt: record.startedAt, kind: record.kind.rawValue)
        do {
            try enqueue(walkID: record.id, ownerID: ownerID, path: "/v1/walks", method: "POST", body: [
                "id": record.id.uuidString, "route_id": route.routeID, "version_id": route.versionID,
                "kind": record.kind.rawValue, "started_at": stamp(record.startedAt)
            ])
        } catch { state = previous; throw error }
        triggerFlush()
    }

    func checkpoint(_ record: SessionRecord, poiID: String, skipped: Bool, at: Date, evidence: AutomaticVisitEvidence? = nil) throws {
        guard let walk = state.walks[record.id.uuidString], let index = walk.placeIDs.firstIndex(of: poiID) else { return }
        var item: [String: Any] = ["id": UUID().uuidString, "kind": skipped ? "skipped" : "visited",
            "stop_order": index + 1, "version_id": walk.versionID, "at": stamp(at)]
        if let evidence, !skipped {
            item["accuracy_m"] = evidence.accuracyMeters
            item["dwell_s"] = Int(evidence.observedDwellSeconds.rounded(.down))
        }
        try enqueue(walkID: record.id, ownerID: walk.ownerID, path: "/v1/walks/\(record.id.uuidString)/checkpoints", method: "POST", body: ["items": [item]])
        triggerFlush()
    }

    func finish(_ record: SessionRecord, method: String, distanceEstimateMeters: Double?) async throws {
        guard let walk = state.walks[record.id.uuidString], let endedAt = record.endedAt,
              state.finishes[record.id.uuidString] == nil,
              !state.jobs.contains(where: { $0.walkID == record.id && $0.path.hasSuffix("/finish") }) else { return }
        var distance = distanceEstimateMeters
        if distance == nil, let sessionStore { distance = try await sessionStore.distanceEstimate(sessionID: record.id) }
        guard let distance, distance.isFinite, distance >= 0, distance < Double(Int.max) else {
            let previous = state
            state.blockedFinishes[record.id.uuidString] = BlockedFinish(endedAt: endedAt, method: method,
                reason: "missing_distance_estimate", startedAt: record.startedAt)
            state.problems[record.id.uuidString] = missingDistanceMessage
            do { try save() } catch { state = previous; throw error }
            lastProblem = missingDistanceMessage
            return
        }
        try enqueueFinish(walkID: record.id, walk: walk, startedAt: record.startedAt, endedAt: endedAt,
            method: method, distance: distance)
        triggerFlush()
    }

    func rating(_ record: SessionRecord, stars: Int, comment: String) throws {
        guard record.state.isClosed, let walk = state.walks[record.id.uuidString], (1...5).contains(stars) else { return }
        let previous = state
        state.summaryDecisionIDs.insert(record.id.uuidString)
        do {
            try enqueue(walkID: record.id, ownerID: walk.ownerID, path: "/v1/walks/\(record.id.uuidString)/rating", method: "PUT",
                body: ["kind": "rating", "stars": stars, "comment": String(comment.prefix(500))])
        } catch { state = previous; throw error }
        triggerFlush()
    }

    func skipRating(_ record: SessionRecord) throws {
        guard record.state.isClosed, let walk = state.walks[record.id.uuidString] else { return }
        let previous = state
        state.summaryDecisionIDs.insert(record.id.uuidString)
        do {
            try enqueue(walkID: record.id, ownerID: walk.ownerID, path: "/v1/walks/\(record.id.uuidString)/rating", method: "PUT", body: ["kind": "skip"])
        } catch { state = previous; throw error }
        triggerFlush()
    }

    func pendingCount() -> Int { state.jobs.count + state.blockedFinishes.count }

    func snapshot(for walkID: UUID) async -> ProductWalkSyncStatus {
        if corrupt {
            return .init(phase: .queued, pendingOperations: 0, showProOffer: false,
                problem: "Не удалось прочитать локальную очередь синхронизации. Исходный файл сохранён без изменений; автоматическая отправка остановлена.")
        }
        let key = walkID.uuidString
        guard let walk = state.walks[key], await owner() == walk.ownerID else {
            return .init(phase: .localOnly, pendingOperations: 0, showProOffer: false, problem: nil)
        }
        let jobs = state.jobs.filter { $0.walkID == walkID }.count
        if state.blockedFinishes[key] != nil {
            return .init(phase: .requiresDistance, pendingOperations: jobs + 1, showProOffer: false, problem: state.problems[key] ?? missingDistanceMessage)
        }
        if let finish = state.finishes[key] {
            return .init(phase: jobs > 0 ? .queued : .acknowledged, pendingOperations: jobs,
                showProOffer: finish.showProOffer && !finish.proOfferShown && state.summaryDecisionIDs.contains(key), problem: state.problems[key])
        }
        return .init(phase: .queued, pendingOperations: jobs, showProOffer: false, problem: state.problems[key])
    }

    func nextPendingProOffer() async -> UUID? {
        guard let ownerID = await owner() else { return nil }
        return state.finishes.values.filter {
            $0.showProOffer && !$0.proOfferShown && state.summaryDecisionIDs.contains($0.walkID.uuidString)
                && state.walks[$0.walkID.uuidString]?.ownerID == ownerID
        }.sorted { $0.acknowledgedAt < $1.acknowledgedAt }.first?.walkID
    }

    func markProOfferShown(walkID: UUID) async throws {
        let key = walkID.uuidString
        guard let walk = state.walks[key], await owner() == walk.ownerID,
              state.summaryDecisionIDs.contains(key), var ack = state.finishes[key], ack.showProOffer else { return }
        let previous = state
        ack.proOfferShown = true; state.finishes[key] = ack
        do { try save() } catch { state = previous; throw error }
    }

    /// Retry is explicit as well as part of flush. Network recovery is not a
    /// source of distance truth: only persisted accepted observations qualify.
    func retryPendingFinishes() async {
        guard !corrupt, !reconciling, let sessionStore else { return }
        reconciling = true; defer { reconciling = false }
        guard let ownerID = await owner() else { return }
        let blocked = state.blockedFinishes
        for (key, blockedFinish) in blocked {
            guard let walkID = UUID(uuidString: key), let walk = state.walks[key], walk.ownerID == ownerID,
                  state.blockedFinishes[key] != nil else { continue }
            do {
                let record = try await sessionStore.read(sessionID: walkID)
                guard record.state.isClosed, let distance = try await sessionStore.distanceEstimate(sessionID: walkID),
                      distance.isFinite, distance >= 0, distance < Double(Int.max) else { continue }
                guard await owner() == ownerID else { return }
                try enqueueFinish(walkID: walkID, walk: walk, startedAt: blockedFinish.startedAt ?? record.startedAt,
                    endedAt: blockedFinish.endedAt, method: blockedFinish.method, distance: distance)
            } catch {
                state.problems[key] = "Не удалось восстановить оценку из локального журнала: \(userFacingError(error))"
                try? save(); lastProblem = state.problems[key]
            }
        }
    }

    func flush() async {
        guard !flushing, !corrupt else { return }
        flushing = true; defer { flushing = false }
        await retryPendingFinishes()
        while let ownerID = await owner(), let index = state.jobs.firstIndex(where: {
            $0.ownerID == ownerID && (!$0.path.hasSuffix("/rating") || state.finishes[$0.walkID.uuidString] != nil)
        }) {
            let job = state.jobs[index]
            do {
                let data: Data
                if let backend = client as? BackendClient {
                    data = try await backend.request(path: job.path, method: job.method, body: job.body,
                        authenticated: true, expectedUserID: job.ownerID)
                } else { data = try await client.request(path: job.path, method: job.method, body: job.body, authenticated: true) }
                guard await owner() == ownerID else { return }
                let acknowledgement = job.path.hasSuffix("/finish") ? try decodeFinish(data, job: job) : nil
                let previous = state
                if let acknowledgement { state.finishes[job.walkID.uuidString] = acknowledgement }
                state.jobs.removeAll { $0.id == job.id }
                state.problems.removeValue(forKey: job.walkID.uuidString)
                do { try save() } catch { state = previous; throw error }
                lastProblem = nil
            } catch {
                state.problems[job.walkID.uuidString] = userFacingError(error)
                try? save(); lastProblem = userFacingError(error)
                return
            }
        }
        if let ownerID = await owner(),
           let key = state.blockedFinishes.keys.first(where: { state.walks[$0]?.ownerID == ownerID }) {
            lastProblem = state.problems[key] ?? missingDistanceMessage
        }
    }

    private func decodeFinish(_ data: Data, job: Job) throws -> ProductWalkFinishAcknowledgement {
        guard let result = try? JSONDecoder().decode(FinishResult.self, from: data),
              result.walk.id == job.walkID, let walk = state.walks[job.walkID.uuidString],
              result.walk.version_id == walk.versionID,
              walk.routeID == nil || result.walk.route_id == walk.routeID,
              ["regular", "repeat", "joint"].contains(result.walk.kind),
              walk.kind == nil || result.walk.kind == walk.kind,
              ["completed", "not_completed"].contains(result.walk.status),
              result.walk.progress.total > 0,
              result.walk.progress.visited_orders.allSatisfy({ $0 >= 1 && $0 <= result.walk.progress.total }),
              result.walk.progress.skipped_orders.allSatisfy({ $0 >= 1 && $0 <= result.walk.progress.total }),
              validTimestamp(result.walk.started_at) else { throw ProductWalkSyncError.invalidFinishResponse }
        return .init(walkID: job.walkID, status: result.walk.status, finishMethod: result.walk.finish_method,
            showProOffer: result.show_pro_offer, acknowledgedAt: Date(), proOfferShown: false)
    }

    private func enqueueFinish(walkID: UUID, walk: RegisteredWalk, startedAt: Date, endedAt: Date, method: String, distance: Double) throws {
        guard state.finishes[walkID.uuidString] == nil,
              !state.jobs.contains(where: { $0.walkID == walkID && $0.path.hasSuffix("/finish") }) else { return }
        let previous = state
        state.blockedFinishes.removeValue(forKey: walkID.uuidString)
        state.problems.removeValue(forKey: walkID.uuidString)
        do {
            try enqueue(walkID: walkID, ownerID: walk.ownerID, path: "/v1/walks/\(walkID.uuidString)/finish", method: "POST", body: [
                "method": method, "ended_at": stamp(endedAt), "stats": [
                    "duration_s": max(0, Int(endedAt.timeIntervalSince(startedAt))), "distance_m": Int(distance.rounded())]
            ])
        } catch { state = previous; throw error }
    }

    private var missingDistanceMessage: String {
        "Прогулка и оценка сохранены на iPhone. В журнале нет пригодной оценки расстояния, а API требует distance_m. Нужен контракт для неизвестного расстояния; повтор сети сам по себе не решит это. Можно повторить проверку локального журнала."
    }
    private func validTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }
    private func enqueue(walkID: UUID, ownerID: String, path: String, method: String, body: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        let job = Job(id: UUID(), ownerID: ownerID, walkID: walkID, path: path, method: method, body: data)
        state.jobs.append(job)
        do { try save() } catch { state.jobs.removeAll { $0.id == job.id }; throw error }
    }
    private func triggerFlush() { if automaticallyFlush { Task { await flush() } } }
    private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func save() throws {
        guard !corrupt else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        var protected = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
}
