import Foundation

enum MmError: Error, LocalizedError {
    case badURL(String)
    case http(Int)
    case badReply(String)
    case ubus(Int)
    case sessionExpired
    case danger(String)
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let u): return L("Некорректный адрес: \(u)", "Invalid address: \(u)")
        case .http(let c): return L("HTTP-ошибка \(c)", "HTTP error \(c)")
        case .badReply(let d): return L("Странный ответ от роутера: \(d)", "Odd response from the router: \(d)")
        case .ubus(let c): return MmError.ubusText(c)
        case .sessionExpired: return L("Сессия истекла", "Session expired")
        case .danger(let c): return L("Заблокировано безопасным режимом: \(c)", "Blocked by safe mode: \(c)")
        case .backend(let m): return m
        }
    }

    static func ubusText(_ code: Int) -> String {
        switch code {
        case 0: return "OK"
        case 1: return L("ubus: неверная команда", "ubus: invalid command")
        case 2: return L("ubus: неверный аргумент", "ubus: invalid argument")
        case 3: return L("ubus: метод не найден", "ubus: method not found")
        case 4: return L("ubus: не найдено", "ubus: not found")
        case 5: return L("ubus: нет данных", "ubus: no data")
        case 6: return L("ubus: нет прав (сессия истекла?)", "ubus: permission denied (session expired?)")
        case 7: return L("ubus: таймаут", "ubus: timeout")
        case 8: return L("ubus: не поддерживается", "ubus: not supported")
        case 10: return L("ubus: соединение не удалось", "ubus: connection failed")
        default: return L("ubus: ошибка \(code)", "ubus: error \(code)")
        }
    }
}

/// ubus JSON-RPC клиент (rpcd, /ubus).
actor UbusClient {
    static let anonSession = "00000000000000000000000000000000"

    let baseURL: URL
    private(set) var session: String = UbusClient.anonSession
    private(set) var user: String = ""
    private var nextId = 1

    private let http: URLSession

    init(base: URL) {
        self.baseURL = base
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 90
        cfg.httpShouldUsePipelining = false
        self.http = URLSession(configuration: cfg)
    }

    private var rpcURL: URL {
        // base = scheme://host[:port]; путь /ubus (или иной, если указан)
        if baseURL.path.isEmpty {
            return URL(string: baseURL.absoluteString + "/ubus") ?? baseURL
        }
        return baseURL
    }

    func setSession(_ s: String, user: String) {
        self.session = s
        self.user = user
    }

    private func post(_ params: [Any], timeout: Double = 12) async throws -> [Any] {
        var req = URLRequest(url: rpcURL)
        req.timeoutInterval = timeout
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let id = nextId
        nextId += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "call", "params": params]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await http.data(for: req)
        } catch {
            throw MmError.backend(L("Нет связи с роутером: \(error.localizedDescription)", "No connection to the router: \(error.localizedDescription)"))
        }
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            throw MmError.http(h.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [Any] else {
            let s = String(data: data.prefix(200), encoding: .utf8) ?? "?"
            throw MmError.badReply(s)
        }
        guard let status = (result.first as? NSNumber)?.intValue else {
            throw MmError.badReply(L("result без статуса", "result without status"))
        }
        if status != 0 {
            if status == 6 { throw MmError.sessionExpired }
            throw MmError.ubus(status)
        }
        return Array(result.dropFirst())
    }

    func login(user: String, pass: String) async throws {
        let data = try await post([UbusClient.anonSession, "session", "login",
                                   ["username": user, "password": pass, "timeout": 21_600]])
        guard let d = data.first as? [String: Any],
              let token = d["ubus_rpc_session"] as? String else {
            throw MmError.backend(L("Логин не удался: нет сессии (проверьте логин/пароль)", "Login failed: no session (check login/password)"))
        }
        session = token
        self.user = user
    }

    func keepalive() async throws {
        _ = try await post([session, "session", "keepalive", ["ubus_rpc_session": session]])
    }

    /// Вызов ubus: возвращает данные (result без первого элемента-статуса).
    func call(_ object: String, _ method: String, _ args: [String: Any] = [:], timeout: Double = 12) async throws -> [Any] {
        try await post([session, object, method, args], timeout: timeout)
    }

    func callData(_ object: String, _ method: String, _ args: [String: Any] = [:], timeout: Double = 12) async throws -> J {
        let r = try await call(object, method, args, timeout: timeout)
        guard let d = r.first else { return J([String: Any]()) }
        return J(d)
    }

    // MARK: - file (exec / read / write / list)

    struct ExecResult {
        var code: Int
        var stdout: String
        var stderr: String
        var ok: Bool { code == 0 }
    }

    func fileExec(_ script: String, timeout: Double = 12) async throws -> ExecResult {
        func run(_ key: String) async throws -> ExecResult {
            let d = try await callData("file", "exec", [key: "/bin/sh", "params": ["-c", script]], timeout: timeout)
            return ExecResult(code: d.int("code") ?? -1,
                              stdout: d.string("stdout") ?? "",
                              stderr: d.string("stderr") ?? "")
        }
        // Новые rpcd (OpenWrt 25.x) ждут "command", старые — "path"
        do {
            return try await run("command")
        } catch MmError.ubus(let code) where code == 2 || code == 3 {
            return try await run("path")
        }
    }

    func fileRead(_ path: String) async throws -> Data {
        let d = try await callData("file", "read", ["path": path])
        guard let b64 = d.string("data"), let raw = Data(base64Encoded: b64) else {
            throw MmError.backend(L("Не удалось прочитать \(path)", "Failed to read \(path)"))
        }
        return raw
    }

    func fileReadText(_ path: String) async throws -> String {
        let raw = try await fileRead(path)
        return String(data: raw, encoding: .utf8) ?? ""
    }

    func fileWrite(_ path: String, data: Data, append: Bool = false) async throws {
        _ = try await callData("file", "write", ["path": path, "data": data.base64EncodedString(), "append": append])
    }

    func fileWriteText(_ path: String, _ text: String, append: Bool = false) async throws {
        try await fileWrite(path, data: Data(text.utf8), append: append)
    }

    func fileList(_ path: String) async throws -> [FileEntry] {
        let d = try await callData("file", "list", ["path": path])
        return d.list("entries").map { e in
            FileEntry(name: e.string("name") ?? "?",
                      size: e.int("size").map(Int64.init),
                      isDir: (e.string("type") ?? "file") == "directory",
                      mode: e.string("mode") ?? "",
                      mtime: e.int("mtime").map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
    }
}

/// Простые HTTP-запросы к CGI роутера (medvemodem и т.п.).
struct HttpJson {
    let base: URL

    private func url(_ pathAndQuery: String) throws -> URL {
        guard var comps = URLComponents(string: base.absoluteString) else { throw MmError.badURL(base.absoluteString) }
        let parts = pathAndQuery.split(separator: "?", maxSplits: 1).map(String.init)
        comps.path = parts.first ?? "/"
        if parts.count > 1 { comps.percentEncodedQuery = parts[1] }
        guard let url = comps.url else { throw MmError.badURL(pathAndQuery) }
        return url
    }

    func getJSON(_ pathAndQuery: String, timeout: Double = 10) async throws -> J {
        var req = URLRequest(url: try url(pathAndQuery))
        req.timeoutInterval = timeout
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw MmError.backend(L("Нет связи с роутером: \(error.localizedDescription)", "No connection to the router: \(error.localizedDescription)"))
        }
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            throw MmError.http(h.statusCode)
        }
        guard let j = J(data: data) else {
            let s = String(data: data.prefix(200), encoding: .utf8) ?? "?"
            throw MmError.badReply(s)
        }
        return j
    }

    func getText(_ pathAndQuery: String, timeout: Double = 15) async throws -> String {
        var req = URLRequest(url: try url(pathAndQuery))
        req.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
