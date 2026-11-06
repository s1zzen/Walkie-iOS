import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// GPX — заранее заданный эталонный маршрут, а не записанная во время теста геопозиция.
enum RouteImport {
    static let maximumFileBytes = 5 * 1_024 * 1_024
    static let maximumPoints = 10_000

    static func gpx(data: Data, name: String) throws -> TestRoute {
        guard !data.isEmpty else { throw FieldLabError.message("GPX-файл пуст.") }
        guard data.count <= maximumFileBytes else {
            throw FieldLabError.message("GPX-файл больше 5 МБ. Сократите маршрут перед импортом.")
        }
        // Убираем нулевые байты только для проверки: так маркер обнаруживается
        // также в UTF-16/UTF-32. Исходный XML передаётся парсеру без изменений.
        // GPX не требует DTD; отклоняем её до запуска XMLParser, поскольку он
        // не всегда сообщает делегату об отключённых внешних объявлениях.
        let declarationBytes = data.filter { $0 != 0 }
        guard declarationBytes.range(of: Data("<!DOCTYPE".utf8)) == nil else {
            throw FieldLabError.message("GPX с DOCTYPE/DTD не поддерживается. Экспортируйте обычный GPX без XML-сущностей.")
        }
        let delegate = GPXRouteDelegate(maximumPoints: maximumPoints)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        if let error = delegate.failure { throw error }
        guard parsed else {
            throw FieldLabError.message("Не удалось прочитать GPX: файл повреждён или не является XML.")
        }
        guard delegate.hasGPXRoot, !delegate.segments.isEmpty else {
            throw FieldLabError.message("В GPX нет маршрута: нужны trk/trkseg/trkpt или rte/rtept. Отдельных wpt недостаточно.")
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = TestRoute(
            name: title.isEmpty ? "Импортированный маршрут" : title,
            source: "GPX — импорт файла; сегменты сохранены отдельно",
            segments: delegate.segments
        )
        guard route.isValid else { throw FieldLabError.message("GPX содержит некорректный маршрут.") }
        return route
    }
}

private final class GPXRouteDelegate: NSObject, XMLParserDelegate {
    let maximumPoints: Int
    var segments: [[GeoPoint]] = []
    var failure: FieldLabError?
    var hasGPXRoot = false
    private var elements: [String] = []
    private var activeSegment: [GeoPoint]?
    private var pointCount = 0

    init(maximumPoints: Int) { self.maximumPoints = maximumPoints }

    private func fail(_ message: String, parser: XMLParser) {
        if failure == nil { failure = .message(message) }
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let parent = elements.last
        if elements.isEmpty {
            guard elementName == "gpx" else {
                fail("Ожидался GPX-файл с корневым элементом gpx.", parser: parser)
                return
            }
            hasGPXRoot = true
        }
        elements.append(elementName)

        switch elementName {
        case "trk":
            guard parent == "gpx" else { fail("Некорректная структура trk в GPX.", parser: parser); return }
        case "trkseg", "rte":
            let expectedParent = elementName == "trkseg" ? "trk" : "gpx"
            guard parent == expectedParent, activeSegment == nil else {
                fail("Некорректная вложенность сегментов GPX.", parser: parser)
                return
            }
            activeSegment = []
        case "trkpt", "rtept":
            let expectedParent = elementName == "trkpt" ? "trkseg" : "rte"
            guard parent == expectedParent, activeSegment != nil else {
                fail("Точка GPX находится вне подходящего сегмента.", parser: parser)
                return
            }
            guard let latitudeText = attributeDict["lat"], let longitudeText = attributeDict["lon"],
                  let latitude = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let longitude = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                fail("У точки GPX отсутствуют числовые координаты lat/lon. Импорт остановлен.", parser: parser)
                return
            }
            let point = GeoPoint(latitude: latitude, longitude: longitude)
            guard point.isValid else {
                fail("Координаты точки GPX вне допустимого диапазона. Импорт остановлен.", parser: parser)
                return
            }
            pointCount += 1
            guard pointCount <= maximumPoints else {
                fail("В GPX больше 10 000 точек. Упростите маршрут перед импортом.", parser: parser)
                return
            }
            activeSegment?.append(point)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard failure == nil else { return }
        if elementName == "trkseg" || elementName == "rte" {
            guard let segment = activeSegment, segment.count >= 2 else {
                fail("Каждый сегмент GPX должен содержать минимум две точки; пустые и одиночные сегменты не пропускаются.", parser: parser)
                return
            }
            segments.append(segment)
            activeSegment = nil
        }
        if !elements.isEmpty { elements.removeLast() }
    }

    // Не раскрываем внешние сущности и не допускаем определения пользовательских
    // сущностей. Для маршрута они не нужны; это также ограничивает XML entity expansion.
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail("Внешние XML-сущности в GPX не поддерживаются.", parser: parser)
        return nil
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail("XML-сущности в GPX не поддерживаются.", parser: parser)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        fail("Внешние XML-сущности в GPX не поддерживаются.", parser: parser)
    }
}
