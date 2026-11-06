import Foundation
import Security

struct BackendSession: Codable, Sendable {
    let access_token: String
    let refresh_token: String
    let expires_at: String
    let user_id: String
}

struct BackendProblem: Error, LocalizedError, Decodable, Sendable {
    var status: Int?
    var code: String?
    var detail: String?
    var title: String?
    var retry_after_s: Int?
    var attempts_left: Int?
    var errorDescription: String? {
        for key in [code, title, detail].compactMap({ $0 }) {
            if let message = Self.messages[key] { return message }
        }
        switch status {
        case 401: return Self.messages["unauthorized"]
        case 403: return "Это действие недоступно для твоей учётной записи."
        case 404: return "Данные больше недоступны. Обнови экран или создай новую прогулку."
        case 429: return "Слишком много запросов. Подожди немного и повтори."
        case .some(500...599): return "На сервере произошла ошибка. Попробуй ещё раз позже."
        default: return "Не удалось выполнить запрос. Проверь параметры и попробуй ещё раз."
        }
    }

    // Contract codes remain in the error for diagnostics, never in visible UI.
    static let messages: [String: String] = [
        "unauthorized": "Нужен вход в аккаунт. Войди по почте или Apple; в локальном режиме сначала выйди через профиль.",
        "validation_error": "Сервер не принял параметры. Проверь начало, финиш и время прогулки.",
        "apple_token_invalid": "Не удалось подтвердить вход через Apple. Попробуй войти ещё раз.",
        "email_invalid": "Проверь адрес электронной почты.",
        "code_rate_limited": "Код запрашивали слишком часто. Подожди немного перед повтором.",
        "email_unavailable": "Не удалось отправить письмо. Попробуй позже или войди через Apple.",
        "code_invalid": "Код не подошёл. Проверь цифры в последнем письме.",
        "code_expired": "Срок действия кода истёк. Запроси новый код.",
        "registration_expired": "Время регистрации истекло. Начни вход заново.",
        "session_revoked": "Сессия завершена. Войди в аккаунт ещё раз.",
        "name_invalid": "Проверь имя: от 1 до 30 символов.",
        "auth_method_taken": "Этот способ входа уже связан с другой учётной записью.",
        "question_not_found": "Вопрос анкеты больше недоступен. Открой анкету заново.",
        "question_not_in_flow": "Анкета изменилась. Вернись к её началу и продолжи заполнение.",
        "answer_invalid": "Сервер не принял ответ. Проверь выбранные варианты.",
        "profile_incomplete": "Сначала заполни обязательные вопросы профиля.",
        "id_conflict": "Этот запрос уже использован для других параметров. Начни новую прогулку.",
        "feature_disabled": "Эта функция пока отключена. Попробуй позже.",
        "route_not_found": "Маршрут больше недоступен. Создай новую прогулку.",
        "version_not_found": "Эта версия маршрута больше недоступна. Открой маршрут заново.",
        "route_not_editable": "Этот маршрут уже нельзя изменить. Создай новую прогулку.",
        "route_params_incomplete": "Укажи начало и время прогулки.",
        "context_incomplete": "Ответь на обязательные вопросы про эту прогулку.",
        "budget_out_of_range": "Выбери время прогулки от 30 минут до 4 часов.",
        "finish_unreachable": "До выбранного финиша не успеть за указанное время. Увеличь время или выбери финиш ближе.",
        "route_already_built": "Маршрут уже построен. Открой готовый маршрут или создай новую прогулку.",
        "route_not_built": "Сначала построй маршрут.",
        "alternative_limit_reached": "Варианты маршрута закончились. Измени параметры или оставь текущий маршрут.",
        "correction_not_confirmable": "Не удалось применить пожелание. Переформулируй его и повтори.",
        "walk_started": "Прогулка уже началась. Заверши её, чтобы создать другой маршрут.",
        "generation_in_progress": "Маршрут ещё строится. Дождись завершения.",
        "generation_not_found": "Не удалось найти построение маршрута. Повтори запрос.",
        "not_enough_places": "Не удалось подобрать достаточно мест. Измени точку старта, интересы или время.",
        "no_alternative_places": "Других подходящих мест не осталось. Измени параметры прогулки.",
        "route_not_feasible": "Сервер не смог построить связный пешеходный маршрут. Попробуй передвинуть старт или финиш либо убрать конечную точку.",
        "catalog_unavailable": "Поиск мест временно не работает. Попробуй позже.",
        "routing_unavailable": "Сервис пешеходных маршрутов временно не работает. Попробуй позже.",
        "generation_timeout": "Построение заняло слишком много времени. Попробуй ещё раз.",
        "generation_failed": "Не удалось построить маршрут. Попробуй ещё раз или измени параметры.",
        "walk_not_found": "Прогулка недоступна на сервере. Локальную историю можно открыть в «Мои маршруты».",
        "walk_already_active": "Уже есть активная прогулка. Продолжи или заверши её.",
        "walk_not_active": "Эта прогулка уже закрыта. Открой её в истории.",
        "walk_not_finished": "Сначала заверши прогулку.",
        "no_unvisited_stops": "Все места уже отмечены. Можно завершить прогулку.",
        "stop_not_in_version": "Это место относится к другой версии маршрута. Открой актуальную прогулку.",
        "budget_exhausted": "Времени на дополнительные места не осталось. Увеличь время или заверши прогулку.",
        "link_not_found": "Ссылка больше недоступна. Попроси отправить новую.",
        "invite_own": "Это твоя ссылка-приглашение. Отправь её другу.",
        "invite_expired": "Срок приглашения истёк. Попроси новую ссылку.",
        "friend_not_found": "Друг не найден. Обнови список друзей.",
        "leaderboard_not_joined": "Сначала включи участие в рейтинге в профиле.",
        "week_closed": "Эта неделя уже закрыта для обновления рейтинга.",
        "group_not_found": "Группа недоступна. Проверь приглашение.",
        "group_too_large": "В группе слишком много участников.",
        "not_a_friend": "Сначала добавь этого пользователя в друзья.",
        "group_closed": "Набор в группу уже закрыт.",
        "group_not_ready": "Не все участники готовы. Дождись заполнения анкет.",
        "group_not_voting": "Голосование сейчас не проводится.",
        "group_not_decided": "Участники ещё не выбрали итоговый маршрут.",
        "variant_not_found": "Этот вариант больше недоступен. Обнови список.",
        "not_initiator": "Это действие доступно только организатору.",
        "initiator_cannot_leave": "Организатор может отменить группу, но не выйти из неё.",
        "address_not_found": "Адрес не найден. Уточни запрос или выбери точку на карте.",
        "geo_unavailable": "Поиск адресов временно не работает. Выбери точку на карте.",
        "weather_unavailable": "Не удалось получить погоду. Попробуй позже."
    ]
}

func userFacingError(_ error: Error) -> String {
    if let problem = error as? BackendProblem { return problem.errorDescription! }
    if let url = error as? URLError {
        switch url.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return "Нет доступа к интернету. Проверь подключение и повтори."
        case .timedOut: return "Сервер не ответил вовремя. Попробуй ещё раз."
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost:
            return "Не удалось связаться с сервером. Проверь подключение и попробуй позже."
        case .userAuthenticationRequired: return BackendProblem.messages["unauthorized"]!
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            return "Не удалось установить безопасное соединение с сервером. Нужна проверка адреса и настроек сервера."
        case .cannotParseResponse, .badServerResponse, .cannotDecodeContentData:
            return "Ответ сервера имеет неожиданный формат. Попробуй позже; если ошибка повторяется, сообщи команде."
        case .cancelled: return "Запрос отменён. Можно повторить."
        default: return "Не удалось выполнить сетевой запрос. Проверь соединение и повтори."
        }
    }
    if error is DecodingError { return "Не удалось прочитать ответ или сохранённые данные. Сообщи команде; не удаляй локальные записи." }
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain {
        if ns.code == CocoaError.fileWriteOutOfSpace.rawValue { return "На устройстве не хватает свободного места. Освободи место и повтори сохранение." }
        return "Не удалось прочитать или сохранить данные на устройстве. Проверь свободное место и повтори."
    }
    if let text = (error as? LocalizedError)?.errorDescription,
       text.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil { return text }
    return "Не удалось выполнить действие. Попробуй ещё раз; если ошибка повторяется, сообщи команде."
}

/// Session tokens never enter profile, research logs or telemetry.
enum BackendKeychain {
    static func data(for key: String) -> Data? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.walkie.backend", kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func set(_ data: Data?, for key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.walkie.backend", kSecAttrAccount as String: key]
        if let data {
            let values: [String: Any] = [kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            if status == errSecItemNotFound {
                guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                    throw URLError(.cannotWriteToFile)
                }
            } else if status != errSecSuccess { throw URLError(.cannotWriteToFile) }
        } else { SecItemDelete(query as CFDictionary) }
    }
}

actor BackendClient {
    static let shared = BackendClient()
    let baseURL: URL
    private let transport: URLSession
    private var refreshing: Task<BackendSession, Error>?
    let allowsInsecureHTTP: Bool
    static var developmentHTTPAllowed: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    static var configuredBaseURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "WalkieBackendURL") as? String,
           let url = URL(string: raw), url.host != nil { return url }
        return URL(string: "http://178.72.149.13/api")!
    }
    static func validateTransport(_ url: URL, allowsInsecureHTTP: Bool) throws {
        guard url.host != nil, url.user == nil, url.password == nil,
              url.scheme == "https" || (allowsInsecureHTTP && url.scheme == "http") else {
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }
    }

    init(baseURL: URL = BackendClient.configuredBaseURL, transport: URLSession = .shared, allowsInsecureHTTP: Bool = BackendClient.developmentHTTPAllowed) {
        self.baseURL = baseURL
        self.transport = transport
        self.allowsInsecureHTTP = allowsInsecureHTTP
    }
    func currentSession() -> BackendSession? {
        guard let data = BackendKeychain.data(for: "session") else { return nil }
        return try? JSONDecoder().decode(BackendSession.self, from: data)
    }
    func saveSession(_ session: BackendSession) throws {
        try BackendKeychain.set(JSONEncoder().encode(session), for: "session")
    }
    func clearSession() throws { try BackendKeychain.set(nil, for: "session") }
    func request(path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true) async throws -> Data {
        try await perform(path: path, method: method, body: body, authenticated: authenticated, retry: true)
    }
    func request(path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true, expectedUserID: String) async throws -> Data {
        guard currentSession()?.user_id == expectedUserID else { throw URLError(.userAuthenticationRequired) }
        return try await perform(path: path, method: method, body: body, authenticated: authenticated, retry: true, expectedUserID: expectedUserID)
    }
    private func perform(path: String, method: String, body: Data?, authenticated: Bool, retry: Bool, expectedUserID: String? = nil) async throws -> Data {
        try Self.validateTransport(baseURL, allowsInsecureHTTP: allowsInsecureHTTP)
        // The client has no arbitrary external URL entry point and never accepts GPS logs.
        guard path.hasPrefix("/v1/"), !path.contains("://"), !path.contains(".."),
              !path.contains("/track"), !path.contains("/return-path") else { throw URLError(.unsupportedURL) }
        guard let url = URL(string: baseURL.absoluteString + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        var sentOwnerID: String?
        if authenticated {
            guard let session = currentSession(), expectedUserID == nil || session.user_id == expectedUserID else {
                throw BackendProblem(status: 401, code: "unauthorized", detail: "Для маршрутов с сервера нужен вход по почте или Apple. В локальном режиме открой «Профиль → Учётная запись → Выйти», затем войди в аккаунт.")
            }
            sentOwnerID = session.user_id
            request.setValue("Bearer \(session.access_token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 401, authenticated, retry, let old = currentSession() {
            guard old.user_id == sentOwnerID else { throw URLError(.userAuthenticationRequired) }
            let task: Task<BackendSession, Error>
            if let refreshing { task = refreshing } else {
                task = Task {
                    let body = try JSONSerialization.data(withJSONObject: ["refresh_token": old.refresh_token])
                    let data = try await self.perform(path: "/v1/auth/refresh", method: "POST", body: body, authenticated: false, retry: false)
                    let session = try JSONDecoder().decode(BackendSession.self, from: data)
                    guard session.user_id == old.user_id else { throw URLError(.badServerResponse) }
                    guard self.currentSession()?.refresh_token == old.refresh_token else { throw URLError(.userAuthenticationRequired) }
                    try self.saveSession(session)
                    return session
                }
                refreshing = task
            }
            do { _ = try await task.value; refreshing = nil }
            catch { refreshing = nil; throw error }
            return try await perform(path: path, method: method, body: body, authenticated: true, retry: false, expectedUserID: sentOwnerID)
        }
        guard (200..<300).contains(response.statusCode) else {
            var problem = (try? JSONDecoder().decode(BackendProblem.self, from: data)) ?? BackendProblem()
            problem.status = response.statusCode
            throw problem
        }
        // An in-flight response must never populate the next account's models.
        if authenticated, currentSession()?.user_id != sentOwnerID {
            throw URLError(.userAuthenticationRequired)
        }
        return data
    }
}
