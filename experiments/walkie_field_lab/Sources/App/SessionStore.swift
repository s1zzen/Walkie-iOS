import Foundation

/// Все файловые операции одной сессии выполняются последовательно.
final class SessionStore: @unchecked Sendable {
    let folder: URL
    private let queue = DispatchQueue(label: "walkie.field-lab.session-writer", qos: .utility)
    private let encoder: JSONEncoder
    private var handles: [String: FileHandle] = [:]
    private var failure: String?
    private var closed = false
    private let flushClock = ContinuousClock()
    private var lastFlush = ContinuousClock().now
    private let onError: @Sendable (String) -> Void
    private var gpxOffset: UInt64 = 0
    private var gpxSegmentOpen = false
    private var gpxNeedsSegment = false
    private var lastGPXDate: Date?

    static var sessionsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    static func sessions() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    init(info: SessionInfo, directory: URL = SessionStore.sessionsDirectory,
         onError: @escaping @Sendable (String) -> Void) throws {
        self.onError = onError
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.timestamp(date))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = formatter.string(from: info.startedAt) + "_" + info.id.uuidString.prefix(8)
        folder = directory.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: Self.protection)
            var unfinished = info
            unfinished.interrupted = true
            try writeDocument(unfinished, name: "meta.json")
            try writeDocument(info.route, name: "route.json")
            for name in ["locations.jsonl", "motion.jsonl", "events.jsonl", "predictions.jsonl", "observed.gpx"] {
                let url = folder.appendingPathComponent(name)
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: Self.protection) else {
                    throw FieldLabError.message("Не удалось создать файл \(name).")
                }
                handles[name] = try FileHandle(forWritingTo: url)
            }
            let header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Walkie Field Lab\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(Self.xml(info.name))</name>\n"
            let data = Data(header.utf8)
            try handles["observed.gpx"]?.write(contentsOf: data)
            gpxOffset = UInt64(data.count)
            try writeGPXFooter()
            try flush()
        } catch {
            closeHandles()
            throw error
        }
    }

    func append<T: Encodable>(_ value: T, to filename: String) {
        perform {
            try self.appendLine(value, to: filename)
        }
    }

    /// Сырые координаты остаются в JSONL; GPX включает только допустимые фиксации.
    func appendLocation<T: Encodable>(_ value: T, gpxSample: LocationSample?) {
        perform {
            try self.appendLine(value, to: "locations.jsonl")
            if let sample = gpxSample {
                try self.appendGPX(sample)
            } else {
                self.gpxNeedsSegment = true
            }
        }
    }

    /// Барьер очереди: вызывающий код может завершить lifecycle callback после синхронизации.
    func flushIfNeeded(force: Bool = false) throws {
        try queue.sync {
            if let failure { throw FieldLabError.message(failure) }
            guard !closed else { return }
            if force || lastFlush.duration(to: flushClock.now) >= .seconds(3) {
                try flush()
            }
        }
    }

    func finish(info: SessionInfo, summary: SessionSummary) throws {
        try queue.sync {
            if let failure { throw FieldLabError.message(failure) }
            guard !closed else { return }
            do {
                try flush()
                try writeDocument(summary, name: "summary.json")
                // Признак завершения меняется последним: сбой раньше оставляет interrupted=true.
                var completed = info
                completed.interrupted = false
                try writeDocument(completed, name: "meta.json")
                closeHandles()
                closed = true
            } catch {
                closeHandles()
                closed = true
                throw error
            }
        }
    }

    func abandon() {
        queue.sync {
            try? flush()
            closeHandles()
            closed = true
        }
    }

    private func perform(_ operation: @escaping () throws -> Void) {
        queue.async {
            guard !self.closed, self.failure == nil else { return }
            do {
                try operation()
                if self.lastFlush.duration(to: self.flushClock.now) >= .seconds(3) {
                    try self.flush()
                }
            } catch {
                let message = "Запись остановлена из-за ошибки сохранения: \(error.localizedDescription)"
                self.failure = message
                self.closeHandles()
                self.closed = true
                self.onError(message)
            }
        }
    }

    private func appendLine<T: Encodable>(_ value: T, to filename: String) throws {
        guard let handle = handles[filename] else {
            throw FieldLabError.message("Файл \(filename) не открыт.")
        }
        var data = try encoder.encode(value)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func writeDocument<T: Encodable>(_ value: T, name: String) throws {
        let url = folder.appendingPathComponent(name)
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(Self.protection, ofItemAtPath: url.path)
    }

    private func appendGPX(_ sample: LocationSample) throws {
        guard let handle = handles["observed.gpx"] else { return }
        let gap = lastGPXDate.map { sample.observedAt.timeIntervalSince($0) }
        let newSegment = !gpxSegmentOpen || gpxNeedsSegment || (gap.map { $0 > 10 || $0 <= 0 } ?? false)
        var body = ""
        if newSegment {
            if gpxSegmentOpen { body += "</trkseg>\n" }
            body += "<trkseg>\n"
            gpxSegmentOpen = true
        }
        body += "<trkpt lat=\"\(sample.latitude)\" lon=\"\(sample.longitude)\">"
        if let altitude = sample.altitude, let accuracy = sample.verticalAccuracy, accuracy >= 0 {
            body += "<ele>\(altitude)</ele>"
        }
        body += "<time>\(Self.timestamp(sample.observedAt))</time></trkpt>\n"
        try handle.seek(toOffset: gpxOffset)
        let data = Data(body.utf8)
        try handle.write(contentsOf: data)
        gpxOffset += UInt64(data.count)
        lastGPXDate = sample.observedAt
        gpxNeedsSegment = false
        try writeGPXFooter()
    }

    private func writeGPXFooter() throws {
        guard let handle = handles["observed.gpx"] else { return }
        let footer = Data((gpxSegmentOpen ? "</trkseg>\n</trk></gpx>\n" : "</trk></gpx>\n").utf8)
        try handle.seek(toOffset: gpxOffset)
        try handle.write(contentsOf: footer)
        try handle.truncate(atOffset: gpxOffset + UInt64(footer.count))
    }

    private func flush() throws {
        for handle in handles.values { try handle.synchronize() }
        lastFlush = flushClock.now
    }

    private func closeHandles() {
        for handle in handles.values { try? handle.close() }
        handles.removeAll()
    }

    private static var protection: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    private static func timestamp(_ date: Date) -> String {
        date.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private static func xml(_ string: String) -> String {
        let legalScalars = string.unicodeScalars.filter { scalar in
            scalar.value == 9 || scalar.value == 10 || scalar.value == 13 ||
            (0x20...0xD7FF).contains(scalar.value) || (0xE000...0xFFFD).contains(scalar.value) ||
            (0x10000...0x10FFFF).contains(scalar.value)
        }
        return String(String.UnicodeScalarView(legalScalars)).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
