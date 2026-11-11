import Foundation

/// Всё взаимодействие с роутером: exec через ubus file, CGI medvemodem, iwinfo, wg и т.д.
struct RouterService {
    let ubus: UbusClient
    let http: HttpJson
    let profile: RouterProfile
    let settings: MmSettings

    // Регэксп опасных команд из Android-версии.
    static let dangerRegex = try? NSRegularExpression(
        pattern: "(?:^|[;&|\\s])(?:network\\s+reload|reboot|sysupgrade|firstboot|mkfs|dd\\s+if=|mtd\\s+write|rm\\s+-rf\\s+/(?:\\s|$))"
    )

    static func isDangerous(_ script: String) -> String? {
        guard let re = dangerRegex else { return nil }
        let r = Range(re.rangeOfFirstMatch(in: script, range: NSRange(script.startIndex..., in: script)), in: script)
        return r.map { String(script[$0]) }
    }

    // MARK: - exec

    func exec(_ script: String, allowDangerous: Bool = false, timeout: Double = 12) async throws -> UbusClient.ExecResult {
        if settings.safeMode, !allowDangerous, let hit = RouterService.isDangerous(script) {
            throw MmError.danger(hit)
        }
        return try await ubus.fileExec(script, timeout: timeout)
    }

    func execText(_ script: String, allowDangerous: Bool = false) async throws -> String {
        let r = try await exec(script, allowDangerous: allowDangerous)
        return r.stdout
    }

    // MARK: - Модем (medvemodem CGI + ModemManager/mmcli)

    /// Старый CGI medvemodem; на новых прошивках его нет — кидает http(404).
    private func cgi(_ pathAndQuery: String, timeout: Double = 10) async throws -> J {
        try await http.getJSON(pathAndQuery, timeout: timeout)
    }

    /// mmcli — ModemManager (есть на OpenWrt 24.10+/25.x)
    private func mm(_ args: String, timeout: Double = 25) async throws -> String {
        let r = try await exec("mmcli \(args) 2>&1")
        return r.stdout
    }

    func modemStatus() async throws -> ModemSnapshot {
        do {
            let j = try await http.getJSON(profile.modemPath)
            return ModemSnapshot(j: j)
        } catch MmError.http(let code) where code == 404 {
            // Новые medvemodem отдают телеметрию по другому пути (schema 2)
            let j = try await http.getJSON("/cgi-bin/modem-telemetry")
            return ModemSnapshot(telemetry: j)
        }
    }

    // MARK: SMS

    func smsList() async throws -> [Sms] {
        do {
            let j = try await cgi("\(profile.modemPath)?op=sms_list")
            return j.list("sms", "messages", "list").map { m in
                Sms(id: m.string("id", "index") ?? UUID().uuidString,
                    number: m.string("number", "from", "sender") ?? "",
                    text: m.string("text", "body", "content") ?? "",
                    ts: m.num("ts", "timestamp", "time").map { Date(timeIntervalSince1970: $0 < 1e12 ? $0 : $0 / 1000) },
                    isNew: m.bool("new", "unread"))
            }
        } catch MmError.http(let code) where code == 404 {
            return try await smsListViaMm()
        }
    }

    private func smsListViaMm() async throws -> [Sms] {
        let out = try await mm("-m any --messaging-list-sms")
        var ids: [Int] = []
        for chunk in out.split(separator: "/") {
            let part = chunk.prefix(while: { $0.isNumber })
            if let n = Int(part), !ids.contains(n) { ids.append(n) }
        }
        guard !ids.isEmpty else { return [] }
        var res: [Sms] = []
        for id in ids.suffix(60) {
            let dump = try await mm("-s \(id)")
            res.append(parseMmSms(id, dump))
        }
        return res.reversed()
    }

    private func parseMmSms(_ id: Int, _ dump: String) -> Sms {
        var number = "", state = "received", ts: Date?
        var textLines: [String] = []
        var collecting = false
        for raw in dump.split(separator: "\n") {
            guard raw.contains("|") else { continue }
            let seg = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let t = seg.trimmingCharacters(in: .whitespaces)
            if collecting {
                if t.hasPrefix("pdu type:") || t.hasPrefix("state:") || t.hasPrefix("storage:") || t.hasPrefix("smsc:") || t.hasPrefix("timestamp:") {
                    collecting = false
                } else {
                    textLines.append(t)
                    continue
                }
            }
            if t.hasPrefix("number:") { number = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("text:") { collecting = true; textLines.append(String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            if t.hasPrefix("state:") { state = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("timestamp:") { ts = parseMmDate(String(t.dropFirst(10)).trimmingCharacters(in: .whitespaces)) }
        }
        let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Sms(id: String(id), number: number, text: text.isEmpty ? "(без текста)" : text, ts: ts, isNew: state == "received")
    }

    private func parseMmDate(_ s: String) -> Date? {
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        for f in ["yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss"] {
            let df = DateFormatter()
            df.dateFormat = f
            df.locale = Locale(identifier: "en_US_POSIX")
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    func smsSend(number: String, text: String) async throws {
        let cleaned = number.filter { !$0.isWhitespace && $0 != "-" && $0 != "(" && $0 != ")" }
        let digits = cleaned.hasPrefix("+") ? String(cleaned.dropFirst()) : cleaned
        guard !digits.isEmpty, digits.count <= 20,
              digits.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              !text.isEmpty, !text.contains("\0") else {
            throw MmError.backend("Укажите корректный номер и непустой текст SMS")
        }
        do {
            let reply = try await cgi("\(profile.modemPath)?op=sms_send&number=\(cleaned.enc)&text=\(text.enc)", timeout: 30)
            if let err = reply.string("error"), !err.isEmpty, err != "0" {
                throw MmError.backend("Отправка SMS: \(err)")
            }
            if let ok = reply.value("success") as? Bool, !ok {
                throw MmError.backend("Роутер отклонил отправку SMS")
            }
        } catch MmError.http(let code) where code == 404 {
            try await smsSendViaMm(number: cleaned, text: text)
        }
    }

    /// Создаём сообщение, затем отправляем командой mmcli -s ID --send.
    /// Не повторяем отправку автоматически после сбоя: результат может быть неизвестен.
    private func smsSendViaMm(number: String, text: String) async throws {
        let capabilities = try await exec("mmcli --help-messaging 2>&1")
        guard capabilities.ok else { throw MmError.backend("ModemManager недоступен: \(capabilities.stdout.prefix(200))") }
        let options = "number='\(number)'"
        let createCommand: String
        if capabilities.stdout.contains("--messaging-create-sms-with-text") {
            let encoded = Data(text.utf8).base64EncodedString()
            createCommand = "umask 077; f=$(mktemp /tmp/modemmon-sms.XXXXXX) || exit 1; " +
                "trap 'rm -f \"$f\"' EXIT; printf '%s' '\(encoded)' | base64 -d > \"$f\" || exit 1; " +
                "mmcli -m any --messaging-create-sms='\(options.shellQ)' --messaging-create-sms-with-text=\"$f\" 2>&1"
        } else {
            guard !(text.contains("'") && text.contains("\"")) else {
                throw MmError.backend("Эта версия mmcli не поддерживает текст с обоими видами кавычек. Обновите ModemManager или измените текст.")
            }
            let quote = text.contains("'") ? "\"" : "'"
            let arguments = "\(options),text=\(quote)\(text)\(quote)"
            createCommand = "mmcli -m any --messaging-create-sms='\(arguments.shellQ)' 2>&1"
        }
        let created = try await exec(createCommand, timeout: 60)
        guard created.ok else { throw MmError.backend("Не удалось создать SMS: \(created.stdout.prefix(250))") }
        let prefix = "/org/freedesktop/ModemManager1/SMS/"
        guard let range = created.stdout.range(of: prefix) else {
            throw MmError.backend("ModemManager не вернул ID SMS: \(created.stdout.prefix(200))")
        }
        let id = String(created.stdout[range.upperBound...].prefix(while: { $0.isNumber }))
        guard !id.isEmpty else { throw MmError.backend("ModemManager вернул некорректный ID SMS") }
        let sent = try await exec("mmcli -s \(id) --send 2>&1", timeout: 70)
        guard sent.ok else { throw MmError.backend("SMS не отправлена: \(sent.stdout.prefix(250))") }
    }

    func smsDelete(id: String) async throws {
        do {
            _ = try await cgi("\(profile.modemPath)?op=sms_delete&id=\(id.enc)")
        } catch MmError.http(let code) where code == 404 {
            _ = try await mm("-m any --messaging-delete-sms=/org/freedesktop/ModemManager1/SMS/\(id)")
        }
    }

    // MARK: USSD

    /// Отправить USSD и вернуть ответ сети (CGI или mmcli).
    func ussdRun(code: String) async throws -> String {
        do {
            _ = try await cgi("\(profile.modemPath)?op=ussd_start&code=\(code.enc)", timeout: 30)
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let j = try await cgi("\(profile.modemPath)?op=ussd_status")
                let reply = j.string("reply", "text", "ussd_reply") ?? ""
                let st = j.string("status", "ussd_status") ?? ""
                if !reply.isEmpty { return reply }
                if st.contains("fail") || st.contains("error") { return "Ошибка сети: \(st)" }
            }
            return "(нет ответа за 20 с)"
        } catch MmError.http(let c) where c == 404 {
            let out = try await mm("-m any --3gpp-ussd-initiate='\(code.shellQ)'", timeout: 60)
            if let r = out.range(of: "reply from network:") {
                var s = String(out[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("'") { s = String(s.dropFirst()) }
                if s.hasSuffix("'") { s = String(s.dropLast()) }
                return s
            }
            return out.isEmpty ? "(пустой ответ)" : out
        }
    }

    // MARK: AT

    func sendAt(_ cmd: String) async throws -> String {
        do {
            let j = try await cgi("\(profile.modemPath)?op=at&cmd=\(cmd.enc)", timeout: 20)
            return j.string("reply", "response", "at_reply", "text") ?? ""
        } catch MmError.http(let code) where code == 404 {
            return try await sendAtViaTty(cmd)
        }
    }

    /// AT напрямую в последовательный порт модема (ммcli без debug-режима запрещает --command).
    private func sendAtViaTty(_ cmd: String) async throws -> String {
        let port = try await findAtPort()
        let script = "P=/dev/\(port); stty -F $P 115200 raw -echo 2>/dev/null; " +
            "(sleep 1; printf '%s\\r' '\(cmd.shellQ)' > $P) & timeout 4 cat $P 2>/dev/null | tr -d '\\r'"
        let out = try await execText(script)
        var lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == cmd { lines.removeFirst() }
        let clean = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "(нет ответа)" : clean
    }

    private func findAtPort() async throws -> String {
        for p in ["ttyUSB2", "ttyUSB3", "ttyUSB1", "ttyUSB0"] {
            let script = "(sleep 1; printf 'ATI\\r' > /dev/\(p)) & timeout 3 cat /dev/\(p) 2>/dev/null | tr -d '\\r'"
            let out = (try? await execText(script)) ?? ""
            if out.contains("Manufacturer") || out.contains("OK") || out.contains("ERROR") { return p }
        }
        throw MmError.backend("AT-порт модема не найден (проверял ttyUSB0-3)")
    }

    // MARK: Бэнды

    struct BandsInfo { var supported: [String]; var allowed: [String] }

    func bandsInfo() async throws -> BandsInfo {
        do {
            let j = try await cgi("\(profile.modemPath)?op=status")
            let sup = j.stringsSafe("supported_bands", "supportedBands")
            let act = j.stringsSafe("bands", "active_bands")
            if !sup.isEmpty { return BandsInfo(supported: sup, allowed: act) }
        } catch MmError.http(let code) where code == 404 {
            // mmcli ниже
        }
        let out = try await mm("-m any 2>&1")
        return parseMmBands(out)
    }

    private func parseMmBands(_ out: String) -> BandsInfo {
        var supported: [String] = []
        var allowed: [String] = []
        var target: [String]? = nil

        func collect(_ seg: String) {
            guard var arr = target else { return }
            for tok in seg.split(whereSeparator: { $0 == "," || $0 == " " }) {
                let s = tok.trimmingCharacters(in: .whitespaces)
                if s.isEmpty || s == "|" { continue }
                arr.append(s)
                target = arr
            }
        }

        for raw in out.split(separator: "\n") {
            guard raw.contains("|") else { continue }
            let seg = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let t = seg.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("supported:") { target = supported; collect(String(t.dropFirst(10))) }
            else if t.hasPrefix("current:") { target = allowed; collect(String(t.dropFirst(8))) }
            else if t == "IP" { target = nil }
            else if target != nil { collect(t) }
        }
        // дедуп с сохранением порядка
        func dedup(_ a: [String]) -> [String] {
            var seen = Set<String>(); var res: [String] = []
            for x in a where !seen.contains(x) { seen.insert(x); res.append(x) }
            return res
        }
        return BandsInfo(supported: dedup(supported), allowed: dedup(allowed))
    }

    /// Лок бэндов: CGI (старые прошивки) или mmcli --set-allowed-bands.
    func applyBands(_ bands: [String]) async throws {
        do {
            let csv = bands.joined(separator: ",")
            _ = try await cgi("\(profile.modemPath)?op=bands_set&bands=\(csv.enc)", timeout: 40)
        } catch MmError.http(let code) where code == 404 {
            let mmNames = bands.map { bandToMm($0) }
            guard !mmNames.isEmpty else { return }
            let list = mmNames.joined(separator: ",")
            let out = try await mm("-m any --set-allowed-bands=\(list)", timeout: 60)
            if out.lowercased().contains("error") { throw MmError.backend("Лок бэндов: \(out.prefix(200))") }
        }
    }

    private func bandToMm(_ b: String) -> String {
        let s = b.lowercased().replacingOccurrences(of: " ", with: "")
        if s.hasPrefix("b"), let n = Int(s.dropFirst()) { return "eutran-\(n)" }
        if s.hasPrefix("n"), let n = Int(s.dropFirst()) { return "ngran-\(n)" }
        if s.hasPrefix("w"), let n = Int(s.dropFirst()) { return "utran-\(n)" }
        return s
    }

    // MARK: - Быстрый системный опрос (дашборд)

    func quickSys() async throws -> SysOverview {
        let script = """
        echo "hostname=$(uci -q get system.@system[0].hostname)"
        echo "model=$(cat /tmp/sysinfo/model 2>/dev/null)"
        echo "fw=$(sed -n 's/.*DISTRIB_DESCRIPTION=.\\(.*\\).$/\\1/p' /etc/openwrt_release 2>/dev/null)"
        echo "kernel=$(uname -r)"
        echo "uptime=$(cut -d. -f1 /proc/uptime)"
        echo "load=$(cut -d' ' -f1,2,3 /proc/loadavg | tr ' ' ',')"
        echo "memtotal=$(awk '/MemTotal/{print $2}' /proc/meminfo)"
        echo "memavail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
        echo "cputemp=$(cut -c1-2 /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
        """
        let out = try await execText(script)
        var o = SysOverview()
        for line in out.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = String(kv[0]), val = String(kv[1]).trimmingCharacters(in: .whitespaces)
            switch k {
            case "hostname": o.hostname = val
            case "model": o.model = val
            case "fw": o.firmware = val.replacingOccurrences(of: "'", with: "")
            case "kernel": o.kernel = val
            case "uptime": o.uptime = Int(val) ?? 0
            case "load":
                let p = val.split(separator: ",").compactMap { Double($0) }
                o.load1 = p.count > 0 ? p[0] : 0
                o.load5 = p.count > 1 ? p[1] : 0
                o.load15 = p.count > 2 ? p[2] : 0
            case "memtotal": o.memTotalKb = Int64(val) ?? 0
            case "memavail": o.memFreeKb = Int64(val) ?? 0
            case "cputemp": o.cpuTemp = Double(val)
            default: break
            }
        }
        return o
    }

    struct NetDevRow { var iface: String; var rx: Int64; var tx: Int64 }

    func netDev() async throws -> [NetDevRow] {
        let out = try await execText("cat /proc/net/dev")
        var rows: [NetDevRow] = []
        for line in out.split(separator: "\n").dropFirst(2) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let nums = parts[1].split(separator: " ").filter { !$0.isEmpty }
            guard nums.count >= 9 else { continue }
            rows.append(NetDevRow(iface: name, rx: Int64(nums[0]) ?? 0, tx: Int64(nums[8]) ?? 0))
        }
        return rows
    }

    // MARK: - Сеть: интерфейсы

    func interfaces() async throws -> [Iface] {
        // Список netifd-интерфейсов + живой статус. Статус берём через шелл:
        // прямой ubus-вызов может быть закрыт ACL, а из-под root-шелла работает всегда.
        let list = try await execText("ubus list 'network.interface.*' | sed 's/network\\.interface\\.//'")
        var res: [Iface] = []
        for name in list.split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
            var f = Iface(name: name)
            if let raw = try? await execText("ubus call network.interface.\(name) status"),
               let data = raw.data(using: .utf8), let st = J(data: data) {
                f.proto = st.string("proto") ?? ""
                f.device = st.string("l3_device") ?? st.string("device") ?? ""
                f.up = st.bool("up")
                f.uptime = st.int("uptime")
                f.ips = st.list("ipv4-address").compactMap { $0.sub()?.string("address") }
                if let route = st.list("route").first(where: { $0.sub("target")?.string("target") == "0.0.0.0" })?.sub() {
                    f.gateway = route.string("gateway") ?? ""
                }
                f.dns = st.list("dns-server").compactMap { $0.string() }
            }
            res.append(f)
        }
        // трафик с /proc/net/dev
        if let rows = try? await netDev() {
            for i in res.indices {
                if let row = rows.first(where: { $0.iface == res[i].device }) {
                    res[i].rxBytes = row.rx
                    res[i].txBytes = row.tx
                }
            }
        }
        // metric из uci
        if let uci = try? await uciShow("network") {
            for i in res.indices {
                if let m = uci.section(type: "interface", named: res[i].name)?.option("metric") {
                    res[i].metric = Int(m)
                }
            }
        }
        return res
    }

    func ifaceToggle(_ name: String, up: Bool) async throws {
        _ = try await ubus.callData("network.interface.\(name)", up ? "up" : "down")
    }

    func ifaceRenew(_ name: String) async throws {
        _ = try await ubus.callData("network.interface.\(name)", "renew")
    }

    func ifaceSetMetric(_ name: String, metric: Int) async throws {
        _ = try await exec("uci set network.\(name.shellQ).metric='\(metric)' && uci commit network && /etc/init.d/network reload", allowDangerous: true)
    }

    func networkReload() async throws {
        _ = try await ubus.callData("network", "reload")
    }

    // MARK: - DHCP-аренды

    func leases() async throws -> [Lease] {
        let out = try await execText("cat /tmp/dhcp.leases 2>/dev/null")
        let df = DateFormatter()
        df.dateFormat = "dd.MM HH:mm"
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ").map(String.init)
            guard p.count >= 3 else { return nil }
            var exp = "*"
            if let ts = Double(p[0]) {
                exp = df.string(from: Date(timeIntervalSince1970: ts))
            }
            return Lease(hostname: p.count > 3 ? p[3] : "*",
                         ip: p[2], mac: p[1],
                         expires: exp)
        }
    }

    // MARK: - Маршруты

    func routes() async throws -> [Route] {
        let out = try await execText("ip -4 route show")
        return out.split(separator: "\n").compactMap { line in
            let s = String(line)
            let p = s.split(separator: " ").map(String.init)
            guard !p.isEmpty else { return nil }
            var r = Route(iface: "", target: p[0], gateway: "", source: "", metric: nil, proto: "")
            if let i = p.firstIndex(of: "dev"), i + 1 < p.count { r.iface = p[i + 1] }
            if let i = p.firstIndex(of: "via"), i + 1 < p.count { r.gateway = p[i + 1] }
            if let i = p.firstIndex(of: "src"), i + 1 < p.count { r.source = p[i + 1] }
            if let i = p.firstIndex(of: "metric"), i + 1 < p.count { r.metric = Int(p[i + 1]) }
            r.proto = p.count > 1 ? p[1] : ""
            return r
        }
    }

    // MARK: - Wi-Fi (iwinfo)

    func wifiDevices() async throws -> [String] {
        let d = try await ubus.callData("iwinfo", "devices")
        return d.list("devices").compactMap { $0.string("name") ?? $0.string() }
    }

    /// Точки доступа (из uci wireless).
    func wifiAps() async throws -> [WifiAp] {
        let uci = try await uciShow("wireless")
        var aps: [WifiAp] = []
        for s in uci.sections where s.type == "wifi-iface" {
            var ap = WifiAp()
            ap.ssid = s.option("ssid") ?? ""
            ap.radio = s.option("device") ?? ""
            ap.mode = s.option("mode") ?? "ap"
            ap.hidden = (s.option("hidden") ?? "0") == "1"
            ap.disabled = (s.option("disabled") ?? "0") == "1"
            aps.append(ap)
        }
        return aps
    }

    /// Информация по радио через iwinfo info.
    func wifiInfo(_ device: String) async throws -> J {
        try await ubus.callData("iwinfo", "info", ["device": device])
    }

    func wifiClients() async throws -> [WifiClient] {
        var res: [WifiClient] = []
        for dev in try await wifiDevices() {
            let d = try await ubus.callData("iwinfo", "assoclist", ["device": dev])
            for c in d.list("results") {
                let sig = c.int("signal")
                res.append(WifiClient(mac: (c.string("mac") ?? "?").uppercased(),
                                      ifname: dev,
                                      signal: (sig != nil && sig != 0) ? sig : nil,
                                      noise: c.int("noise"),
                                      rxRate: c.sub("rx")?.num("rate") ?? c.num("rx", "rate"),
                                      txRate: c.sub("tx")?.num("rate") ?? c.num("tx", "rate"),
                                      connectedFor: c.int("connected_time"),
                                      hostname: c.string("hostname") ?? ""))
            }
        }
        return res
    }

    func wifiScan(_ device: String) async throws -> [ScanResult] {
        let d = try await ubus.callData("iwinfo", "scan", ["device": device])
        return d.list("results").map { c in
            let ch = c.int("channel") ?? 0
            let band = ch <= 14 ? "2.4" : (ch >= 32 && ch <= 177 ? "5" : "6")
            return ScanResult(ssid: c.string("ssid") ?? "(скрытая)",
                              bssid: (c.string("bssid") ?? "?").uppercased(),
                              channel: c.int("channel"),
                              band: band,
                              signal: c.int("signal"),
                              width: c.string("channel_width") ?? "",
                              encryption: c.string("encryption")?.isEmpty == false ? (c.string("encryption")!) : "")
        }
    }

    // MARK: - VPN (WireGuard / AmneziaWG)

    func vpnInstances() async throws -> [VpnInstance] {
        let out = try await execText("wg show all dump 2>/dev/null || awg show all dump 2>/dev/null")
        var byIface: [String: VpnInstance] = [:]
        var order: [String] = []
        for line in out.split(separator: "\n") {
            let p = line.split(separator: "\t").map(String.init)
            guard let name = p.first else { continue }
            if p.count == 5 {
                // интерфейс: name, priv, pub, listen, fwmark
                if byIface[name] == nil {
                    byIface[name] = VpnInstance(name: name,
                                                kind: name.lowercased().contains("awg") || out.contains("awg") ? "awg" : "wg",
                                                listenPort: Int(p[3]) ?? nil,
                                                publicKey: p.count > 2 ? p[2] : "")
                    order.append(name)
                } else if var inst = byIface[name] {
                    inst.listenPort = Int(p[3]) ?? inst.listenPort
                    if p.count > 2 { inst.publicKey = p[2] }
                    byIface[name] = inst
                }
            } else if p.count >= 8 {
                // пир: iface, pub, psk, endpoint, allowed, latest, rx, tx, ka
                let peer = VpnPeer(publicKey: p[1],
                                   endpoint: p[3] == "(none)" ? "" : p[3],
                                   allowedIps: p[4],
                                   latestHandshake: Double(p[5]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                                   rx: Int64(p[6]) ?? 0,
                                   tx: Int64(p[7]) ?? 0,
                                   keepalive: Int(p[8]) ?? nil)
                if byIface[name] == nil {
                    byIface[name] = VpnInstance(name: name, kind: name.lowercased().contains("awg") ? "awg" : "wg")
                    order.append(name)
                }
                byIface[name]?.peers.append(peer)
            }
        }
        // адрес интерфейса из списка iface
        if let ifaces = try? await interfaces() {
            for i in ifaces where byIface[i.name] != nil {
                byIface[i.name]?.up = i.up
                byIface[i.name]?.address = i.ips.joined(separator: ", ")
            }
        }
        return order.compactMap { byIface[$0] }
    }

    func vpnToggle(_ name: String, up: Bool) async throws {
        _ = try await ubus.callData("network.interface.\(name)", up ? "up" : "down")
    }

    // MARK: - Система

    func sysOverview() async throws -> SysOverview {
        var o = try await quickSys()
        // частоты и загрузка ядер
        let coresOut = try? await execText(
            "i=0; for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do [ -f \"$f\" ] || continue; echo \"$i=$(awk '{printf \"%d\", $1/1000}' $f)\"; i=$((i+1)); done"
        )
        var cores: [CpuCore] = []
        for line in (coresOut ?? "").split(separator: "\n") {
            let kv = line.split(separator: "=")
            guard kv.count == 2, let idx = Int(kv[0]) else { continue }
            cores.append(CpuCore(id: idx, freqMhz: Int(kv[1]) ?? nil, load: nil))
        }
        o.cores = cores
        return o
    }

    func packages() async throws -> [Package] {
        let out = try await execText("apk info -v 2>/dev/null || opkg list-installed 2>/dev/null")
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let name = p.first, !name.isEmpty else { return nil }
            return Package(name: name, version: p.count > 1 ? p[1] : "")
        }
    }

    enum PkgAction: String { case install, remove, upgrade }

    func packageAction(_ name: String, _ action: PkgAction) async throws {
        let cmd = action == .upgrade
            ? "apk upgrade \(name) 2>&1 || opkg upgrade \(name) 2>&1"
            : "\(action == .install ? "apk add" : "apk del") \(name) 2>&1 || opkg \(action.rawValue) \(name) 2>&1"
        _ = try await exec(cmd)
    }

    func services() async throws -> [ServiceStatus] {
        let names = try await execText("ls /etc/init.d/ | grep -v '^\\.'")
        let enabled = try await execText("for s in /etc/init.d/*; do $s enabled 2>/dev/null && basename $s; done")
        let running = try await execText("for s in /etc/init.d/*; do $s status >/dev/null 2>&1 && basename $s; done")
        let enSet = Set(enabled.split(separator: "\n").map(String.init))
        let runSet = Set(running.split(separator: "\n").map(String.init))
        return names.split(separator: "\n").map(String.init).sorted().map {
            ServiceStatus(name: $0, enabled: enSet.contains($0), running: runSet.contains($0))
        }
    }

    enum SvcAction: String { case enable, disable, start, stop, restart }

    func serviceAction(_ name: String, _ action: SvcAction) async throws {
        let r = try await exec("/etc/init.d/\(name.shellQ) \(action.rawValue) 2>&1; echo done")
        if r.stdout.contains("not found") { throw MmError.backend("Сервис не найден") }
    }

    func processes() async throws -> [ProcInfo] {
        let out = try await execText("ps w | head -n 100")
        var res: [ProcInfo] = []
        for (idx, line) in out.split(separator: "\n").enumerated() {
            if idx == 0 { continue } // заголовок
            let p = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard p.count >= 5, let pid = Int(p[0]) else { continue }
            let cmd = p.count > 4 ? p[4...].joined(separator: " ") : ""
            res.append(ProcInfo(id: pid, user: p[1], cpu: nil, mem: nil, rss: nil, command: cmd))
        }
        return res
    }

    func killProc(pid: Int) async throws {
        _ = try await exec("kill \(pid) 2>&1; echo done")
    }

    func crontabText() async throws -> String {
        try await execText("cat /etc/crontabs/root 2>/dev/null")
    }

    func saveCrontab(_ text: String) async throws {
        _ = try await exec("mkdir -p /etc/crontabs && cat > /etc/crontabs/root << 'MMEOF'\n\(text)\nMMEOF\n/etc/init.d/cron restart 2>/dev/null; echo saved")
    }

    func createBackup() async throws -> String {
        let name = "/tmp/modemmon-backup-\(Int(Date().timeIntervalSince1970)).tar.gz"
        let r = try await exec("sysupgrade -b \(name) 2>&1; test -f \(name) && echo ok || echo fail", allowDangerous: true)
        guard r.stdout.contains("ok") else { throw MmError.backend("sysupgrade -b не сработал: \(r.stdout) \(r.stderr)") }
        return name
    }

    func backups() async throws -> [BackupFile] {
        let out = try await execText("ls -l /tmp/modemmon-backup-*.tar.gz /tmp/sysupgrade-*.tar.gz 2>/dev/null")
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard p.count >= 7 else { return nil }
            let path = p.last ?? ""
            let size = Int64(p[4]) ?? nil
            let date = p[5] + " " + (p.count > 6 ? p[6] : "")
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            return BackupFile(path: path, size: size, mtime: df.date(from: date))
        }
    }

    func deleteBackup(_ path: String) async throws {
        _ = try await exec("rm -f \(path.shellQ); echo done", allowDangerous: true)
    }

    func logRead(lines: Int = 80) async throws -> String {
        try await execText("logread | tail -n \(lines) 2>/dev/null")
    }

    func leds() async throws -> [LedInfo] {
        let out = try await execText(
            "for d in /sys/class/leds/*; do echo \"$d|$(cat $d/brightness 2>/dev/null)|$(cat $d/max_brightness 2>/dev/null)|$(cat $d/trigger 2>/dev/null | tr '\\n' ' ')\"; done"
        )
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 4 else { return nil }
            let name = p[0].split(separator: "/").last.map(String.init) ?? p[0]
            let triggers = p[3].split(separator: " ").map(String.init)
            let active = triggers.first { $0.hasPrefix("[") && $0.hasSuffix("]") }
            return LedInfo(name: name,
                           brightness: Int(p[1]) ?? nil,
                           maxBrightness: Int(p[2]) ?? nil,
                           trigger: active.map { String($0.dropFirst().dropLast()) } ?? triggers.first ?? "")
        }
    }

    // MARK: - UCI

    func uciConfigs() async throws -> [String] {
        let out = try await execText("ls /etc/config/")
        return out.split(separator: "\n").map(String.init).sorted()
    }

    func uciShow(_ name: String) async throws -> UciConfig {
        let out = try await execText("uci show \(name.shellQ) 2>&1")
        var cfg = UciConfig(name: name)
        for line in out.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])                                   // network.lan.proto
            let val = String(kv[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let parts = key.split(separator: ".").map(String.init)
            guard parts.count >= 2, parts[0] == name else { continue }
            let secRaw = parts[1]
            let secName = secRaw
            var secType = ""
            var anon = false
            if secRaw.hasPrefix("@") {
                anon = true
                let rest = secRaw.dropFirst().split(separator: "[")
                secType = String(rest[0])
            }
            if parts.count == 2 {
                // network.lan=interface — объявление секции
                if !anon {
                    if !cfg.sections.contains(where: { $0.name == secName }) {
                        cfg.sections.append(UciSection(name: secName, type: val, anon: false))
                    }
                } else if !cfg.sections.contains(where: { $0.name == secName }) {
                    cfg.sections.append(UciSection(name: secName, type: secType, anon: true))
                }
                continue
            }
            if !cfg.sections.contains(where: { $0.name == secName }) {
                cfg.sections.append(UciSection(name: secName, type: secType, anon: anon))
            }
            if let si = cfg.sections.firstIndex(where: { $0.name == secName }) {
                let opt = parts[2...].joined(separator: ".")
                cfg.sections[si].options.append(UciOption(name: opt, value: val))
            }
        }
        return cfg
    }

    /// Экранируем весь аргумент, а не только отдельные кавычки.
    private func uciArg(_ value: String) -> String { "'\(value.shellQ)'" }

    private func checkedUci(_ script: String) async throws {
        let result = try await exec(script, allowDangerous: true)
        guard result.ok else {
            let detail = (result.stderr + " " + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MmError.backend("Не удалось сохранить настройки UCI (код \(result.code)): \(detail.prefix(250))")
        }
    }

    func uciSet(_ config: String, _ section: String, _ option: String, _ value: String) async throws {
        let assignment = uciArg("\(config).\(section).\(option)=\(value)")
        try await checkedUci("uci set \(assignment) 2>&1 && uci commit \(uciArg(config)) 2>&1")
    }

    // MARK: - Файлы

    func listDir(_ path: String) async throws -> [FileEntry] {
        try await ubus.fileList(path)
    }

    func readFile(_ path: String) async throws -> String {
        do {
            return try await ubus.fileReadText(path)
        } catch {
            return try await execText("cat \(path.shellQ) 2>&1")
        }
    }

    func writeFile(_ path: String, _ text: String) async throws {
        // резервная копия, как в Android-версии
        _ = try await exec("test -f \(path.shellQ) && cp \(path.shellQ) \(path.shellQ).bak-$(date +%s) 2>/dev/null; echo ok")
        do {
            try await ubus.fileWriteText(path, text)
        } catch {
            _ = try await exec("cat > \(path.shellQ) << 'MMFEOF'\n\(text)\nMMFEOF\necho written")
        }
    }

    // MARK: - WoL

    func wolAvailable() async -> Bool {
        guard let r = try? await execText("command -v /usr/bin/etherwake >/dev/null && echo yes || echo no") else { return false }
        return r.contains("yes")
    }

    func wolInstall() async throws {
        let r = try await exec("apk add etherwake >/dev/null 2>&1; opkg install etherwake >/dev/null 2>&1; command -v etherwake >/dev/null && echo ok || echo fail")
        guard r.stdout.contains("ok") else { throw MmError.backend("Не удалось установить etherwake") }
    }

    func wolSend(mac: String, iface: String) async throws {
        let r = try await exec("/usr/bin/etherwake -i \(iface.shellQ) \(mac.shellQ) 2>&1; echo sent")
        guard r.stdout.contains("sent") else { throw MmError.backend("etherwake: \(r.stderr)") }
    }

    // MARK: - Диагностика

    func ping(host: String, count: Int = 4) async throws -> String {
        try await execText("ping -c \(count) -W 3 \(host.shellQ) 2>&1")
    }

    struct UplinkProbe { var iface: String; var httpCode: Int?; var seconds: Double?; var ok: Bool }

    func uplinkProbe(iface: String) async throws -> UplinkProbe {
        let out = try await execText(
            "curl -s -o /dev/null --interface \(iface.shellQ) --max-time 6 -w '%{http_code} %{time_total}' http://connectivitycheck.gstatic.com/generate_204 2>&1"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let p = out.split(separator: " ")
        let code = p.first.flatMap { Int($0) }
        let secs = p.count > 1 ? Double(p[1]) : nil
        return UplinkProbe(iface: iface, httpCode: code, seconds: secs, ok: code == 204)
    }

    // MARK: - Терминатор операций (reboot и т.п.)

    func rebootRouter() async throws {
        _ = try await exec("reboot", allowDangerous: true)
    }

    // MARK: - Forkop (sing-box менеджер)

    struct ForkopStatus {
        var service: String = ""
        var processes: [String] = []
        var versions: [String] = []
        var ports: [String] = []
        var clashVersion: String = ""
        var clashAlive: Bool = false
    }

    func forkopStatus() async throws -> ForkopStatus {
        var s = ForkopStatus()
        s.service = try await execText("/etc/init.d/forkop status 2>&1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s.processes = ((try? await execText("ps w | grep -E 'sing-box|forkop' | grep -v grep")) ?? "")
            .split(separator: "\n").map(String.init)
        s.versions = ((try? await execText(
            "sing-box version 2>/dev/null | head -1; apk info -v 2>/dev/null | grep -E '^(forkop|luci-app-forkop|sing-box-forkop)'"
        )) ?? "").split(separator: "\n").map(String.init)
        s.ports = ((try? await execText("netstat -tlnp 2>/dev/null | grep sing-box | awk '{print $4}'")) ?? "")
            .split(separator: "\n").map(String.init)
        if let j = try? await clashGet("/version") {
            s.clashAlive = true
            s.clashVersion = j.string("version") ?? ""
        }
        return s
    }

    func forkopConfig() async throws -> UciConfig {
        try await uciShow("forkop")
    }

    func forkopSet(_ section: String, _ option: String, _ value: String) async throws {
        try await uciSet("forkop", section, option, value)
    }

    func forkopAction(_ action: SvcAction) async throws {
        let stateAction = (action == .start || action == .restart) ? "restart" : action.rawValue
        let r = try await exec("/etc/init.d/forkop \(action.rawValue) 2>&1 && /etc/init.d/forkop-state \(stateAction) 2>&1", allowDangerous: true, timeout: 45)
        guard r.ok else { throw MmError.backend("Команда службы Форкоп: \(r.stdout.prefix(250))") }
    }

    func forkopLog() async throws -> String {
        try await execText("logread | grep -iE 'forkop|sing-box' | tail -n 60 2>/dev/null")
    }

    // MARK: Clash API (sing-box external controller :9090)

    private var clashBase: URL? {
        URL(string: "\(profile.scheme)://\(profile.host):9090")
    }

    func clashGet(_ path: String) async throws -> J {
        guard let base = clashBase, let url = URL(string: base.absoluteString + path) else {
            throw MmError.badURL(path)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            throw MmError.http(h.statusCode)
        }
        guard let j = J(data: data) else { throw MmError.badReply("clash \(path)") }
        return j
    }

    func clashSelect(group: String, node: String) async throws {
        guard let base = clashBase else { throw MmError.badURL("clash") }
        let enc = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        guard let url = URL(string: base.absoluteString + "/proxies/\(enc)") else {
            throw MmError.badURL(group)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": node])
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            throw MmError.http(h.statusCode)
        }
    }

    struct ClashGroup: Identifiable {
        var name: String
        var type: String
        var now: String
        var all: [String]
        var id: String { name }
    }

    func clashGroups() async throws -> [ClashGroup] {
        let j = try await clashGet("/proxies")
        let groupTypes = ["Selector", "URLTest", "Fallback", "LoadBalance"]
        var res: [ClashGroup] = []
        for (name, v) in j.dict {
            let g = J(v)
            let type = g.string("type") ?? ""
            guard groupTypes.contains(type), g.string("now") != nil else { continue }
            res.append(ClashGroup(name: name, type: type, now: g.string("now") ?? "", all: g.stringsSafe("all")))
        }
        return res.sorted { $0.name < $1.name }
    }

    struct ClashTraffic {
        var downTotal: Int64 = 0
        var upTotal: Int64 = 0
        var active: Int = 0
    }

    func clashConnections() async throws -> ClashTraffic {
        let j = try await clashGet("/connections")
        var t = ClashTraffic()
        t.downTotal = Int64(j.num("downloadTotal") ?? 0)
        t.upTotal = Int64(j.num("uploadTotal") ?? 0)
        t.active = j.list("connections").count
        return t
    }

    // MARK: Forkop: дашборд

    struct ForkopCoreStats {
        var cpuPercent: Double?
        var memMB: Double?
        var uptimeSec: Int?
    }

    func forkopCoreStats() async throws -> ForkopCoreStats {
        var s = ForkopCoreStats()
        let out = try await execText(
            "P=$(pidof sing-box | awk '{print $1}'); " +
            "if [ -n \"$P\" ]; then " +
            "A=$(awk '{print $14+$15}' /proc/$P/stat 2>/dev/null); " +
            "R=$(awk '/VmRSS/{print int($2/1024)}' /proc/$P/status 2>/dev/null); " +
            "sleep 1; B=$(awk '{print $14+$15}' /proc/$P/stat 2>/dev/null); " +
            "UP=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1); ST=$(awk '{print $22}' /proc/$P/stat 2>/dev/null); " +
            "echo cpu=$((B-A)); echo rss=$R; echo up=$((UP-ST/100)); fi"
        )
        for line in out.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "cpu": s.cpuPercent = Double(kv[1])
            case "rss": s.memMB = Double(kv[1])
            case "up": s.uptimeSec = Int(kv[1])
            default: break
            }
        }
        return s
    }

    func clashTestGroup(_ group: String, url: String = "https://www.gstatic.com/generate_204") async throws -> [String: Int] {
        let enc = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        let j = try await clashGet("/group/\(enc)/delay?url=\(url.enc)&timeout=5000")
        var res: [String: Int] = [:]
        for (name, v) in j.dict {
            if let n = J(v).int() { res[name] = n }
        }
        return res
    }

    func clashNodeDelays() async throws -> [String: Int] {
        let j = try await clashGet("/proxies")
        var res: [String: Int] = [:]
        for (name, v) in j.dict {
            let g = J(v)
            if let h = g.list("history").last, let delay = h.int("delay"), delay > 0 {
                res[name] = delay
            }
        }
        return res
    }

    func forkopStateRestart() async throws {
        _ = try await exec("/etc/init.d/forkop-state restart 2>&1; echo done", allowDangerous: true)
    }

    // MARK: Forkop: диагностика

    struct ForkopCheck: Identifiable {
        let id = UUID()
        var name: String
        var ok: Bool
        var detail: String
    }

    func forkopDiagnostics() async throws -> [ForkopCheck] {
        var res: [ForkopCheck] = []

        let svc = try await execText("/etc/init.d/forkop status 2>&1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        res.append(ForkopCheck(name: "Сервис forkop", ok: svc.contains("running"), detail: svc))

        let chk = try await execText("sing-box check -c /etc/sing-box/config.json 2>&1; echo EXIT=$?")
        let chkOK = chk.contains("EXIT=0") && !chk.lowercased().contains("error")
        res.append(ForkopCheck(name: "Конфиг sing-box", ok: chkOK, detail: chkOK ? "валиден" : String(chk.prefix(220))))

        var clashOK = false
        var clashV = ""
        if let j = try? await clashGet("/version") {
            clashOK = true
            clashV = j.string("version") ?? ""
        }
        res.append(ForkopCheck(name: "Clash API (:9090)", ok: clashOK, detail: clashOK ? clashV : "недоступен"))

        let ports = try await execText("netstat -tln 2>/dev/null | grep -E ':9090|:2080|:53 ' | awk '{print $4}'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        res.append(ForkopCheck(name: "Порты 9090 / 2080 / 53", ok: !ports.isEmpty,
                               detail: ports.isEmpty ? "не слушаются" : ports.replacingOccurrences(of: "\n", with: " · ")))

        let dns = try await execText("nslookup google.com 127.0.0.42 2>&1 | tail -2")
        let dnsOK = dns.lowercased().contains("address")
        res.append(ForkopCheck(name: "DNS sing-box (127.0.0.42)", ok: dnsOK, detail: dnsOK ? "отвечает" : String(dns.prefix(160))))

        let px = try await execText("curl -s -o /dev/null -w '%{http_code} %{time_total}' -x http://127.0.0.1:2080 --max-time 8 https://www.gstatic.com/generate_204 2>&1")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        res.append(ForkopCheck(name: "Прокси-цепочка (:2080 → gstatic)", ok: px.hasPrefix("204"),
                               detail: px.hasPrefix("204") ? "204 OK — цепочка работает" : "не прошёл: \(px)"))

        let errs = try await execText("logread | grep -iE 'forkop|sing-box' | grep -iE 'error|fail' | tail -3")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        res.append(ForkopCheck(name: "Свежие ошибки в логе", ok: errs.isEmpty, detail: errs.isEmpty ? "нет" : errs))

        return res
    }

    // MARK: Forkop: управление секциями и ссылками

    /// Сохранить поля секции (nil = не менять). lists — точный состав community_lists
    /// (перезаписывается через delete + add_list, потому что uci set не умеет списки).
    func forkopSaveSection(id: String, label: String?, enabled: Bool?, lists: [String]?) async throws {
        let prefix = "forkop.\(id)"
        var commands: [String] = []
        if let label { commands.append("uci set \(uciArg("\(prefix).label=\(label)"))") }
        if let enabled { commands.append("uci set \(uciArg("\(prefix).enabled=\(enabled ? "1" : "0")"))") }
        if let lists {
            let key = uciArg("\(prefix).community_lists")
            commands.append("(if uci -q get \(key) >/dev/null; then uci delete \(key); fi)")
            for item in lists where !item.isEmpty {
                commands.append("uci add_list \(uciArg("\(prefix).community_lists=\(item)"))")
            }
        }
        guard !commands.isEmpty else { return }
        commands.append("uci commit forkop")
        try await checkedUci(commands.joined(separator: " && ") + " 2>&1")
    }

    func forkopDeleteSection(id: String) async throws {
        try await checkedUci("uci delete \(uciArg("forkop.\(id)")) 2>&1 && uci commit forkop 2>&1")
    }

    func forkopAddSection(label: String, lists: [String]) async throws {
        // $NEW генерируется самим UCI; значения передаются отдельными безопасными аргументами.
        var cmds = ["NEW=$(uci add forkop section) || exit 1",
                    "uci set \"forkop.$NEW.label=\"\(uciArg(label))",
                    "uci set \"forkop.$NEW.enabled=1\"",
                    "uci set \"forkop.$NEW.action=connection\""]
        for item in lists where !item.isEmpty {
            cmds.append("uci add_list \"forkop.$NEW.community_lists=\"\(uciArg(item))")
        }
        cmds.append("uci commit forkop")
        try await checkedUci(cmds.joined(separator: " && ") + " 2>&1")
    }

    func forkopSaveLink(id: String, name: String?, uri: String?) async throws {
        var cmds: [String] = []
        if let name { cmds.append("uci set \(uciArg("forkop.\(id).name=\(name)"))") }
        if let uri { cmds.append("uci set \(uciArg("forkop.\(id).uri=\(uri)"))") }
        guard !cmds.isEmpty else { return }
        cmds.append("uci commit forkop")
        try await checkedUci(cmds.joined(separator: " && ") + " 2>&1")
    }

    func forkopDeleteLink(id: String) async throws {
        try await checkedUci("uci delete \(uciArg("forkop.\(id)")) 2>&1 && uci commit forkop 2>&1")
    }

    func forkopAddLink(section: String, name: String, uri: String) async throws {
        let cmds = ["NEW=$(uci add forkop connection_link) || exit 1",
                    "uci set \"forkop.$NEW.section=\"\(uciArg(section))",
                    "uci set \"forkop.$NEW.name=\"\(uciArg(name))",
                    "uci set \"forkop.$NEW.uri=\"\(uciArg(uri))",
                    "uci set \"forkop.$NEW.order=0\"", "uci commit forkop"]
        try await checkedUci(cmds.joined(separator: " && ") + " 2>&1")
    }

}

// MARK: - UciSection helpers

extension UciSection {
    func option(_ name: String) -> String? {
        options.first { $0.name == name }?.value
    }
}

// MARK: - Строковые хелперы для шелла/URL

extension String {
    /// Безопасно вставить строку в одинарные кавычки внутри shell.
    var shellQ: String {
        self.replacingOccurrences(of: "'", with: "'\\''")
    }

    /// Экранирование для вставки внутрь двойных кавычек shell.
    var shellDQ: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    /// URL-кодирование параметров запроса.
    var enc: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

extension UciConfig {
    func section(type t: String, named n: String) -> UciSection? {
        sections.first { $0.type == t && $0.name == n }
    }
}
