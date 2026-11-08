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

    func exec(_ script: String, allowDangerous: Bool = false) async throws -> UbusClient.ExecResult {
        if settings.safeMode, !allowDangerous, let hit = RouterService.isDangerous(script) {
            throw MmError.danger(hit)
        }
        return try await ubus.fileExec(script)
    }

    func execText(_ script: String, allowDangerous: Bool = false) async throws -> String {
        let r = try await exec(script, allowDangerous: allowDangerous)
        return r.stdout
    }

    // MARK: - Модем (medvemodem CGI)

    func modemStatus() async throws -> ModemSnapshot {
        let j = try await http.getJSON(profile.modemPath)
        return ModemSnapshot(j: j)
    }

    /// Список SMS: GET {modemPath}?op=sms_list
    func smsList() async throws -> [Sms] {
        let j = try await http.getJSON("\(profile.modemPath)?op=sms_list")
        return j.list("sms", "messages", "list").map { m in
            Sms(id: m.string("id", "index") ?? UUID().uuidString,
                number: m.string("number", "from", "sender") ?? "",
                text: m.string("text", "body", "content") ?? "",
                ts: m.num("ts", "timestamp", "time").map { Date(timeIntervalSince1970: $0 < 1e12 ? $0 : $0 / 1000) },
                isNew: m.bool("new", "unread"))
        }
    }

    func smsSend(number: String, text: String) async throws {
        _ = try await http.getJSON("\(profile.modemPath)?op=sms_send&number=\(number.enc)&text=\(text.enc)", timeout: 30)
    }

    func smsDelete(id: String) async throws {
        _ = try await http.getJSON("\(profile.modemPath)?op=sms_delete&id=\(id.enc)")
    }

    func ussdStart(code: String) async throws {
        _ = try await http.getJSON("\(profile.modemPath)?op=ussd_start&code=\(code.enc)", timeout: 30)
    }

    /// Статус USSD-сессии.
    func ussdStatus() async throws -> (status: String, reply: String) {
        let j = try await http.getJSON("\(profile.modemPath)?op=ussd_status")
        return (j.string("status", "ussd_status") ?? "", j.string("reply", "text", "ussd_reply") ?? "")
    }

    func sendAt(_ cmd: String) async throws -> String {
        let j = try await http.getJSON("\(profile.modemPath)?op=at&cmd=\(cmd.enc)", timeout: 20)
        return j.string("reply", "response", "at_reply", "text") ?? ""
    }

    /// Лок бэндов. Имя op может отличаться в зависимости от версии medvemodem —
    /// правится здесь, в одном месте.
    func applyBands(_ bands: [String]) async throws {
        let csv = bands.joined(separator: ",")
        _ = try await http.getJSON("\(profile.modemPath)?op=bands_set&bands=\(csv.enc)", timeout: 40)
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
        // Список netifd-интерфейсов из uci + живой статус из ubus.
        let list = try await execText("ubus list 'network.interface.*' | sed 's/network.interface\\.//'")
        var res: [Iface] = []
        for name in list.split(separator: "\n").map(String.init).filter({ !$0.isEmpty }) {
            let st = try? await ubus.callData("network.interface.\(name)", "status")
            var f = Iface(name: name)
            f.proto = st?.string("proto") ?? ""
            f.device = st?.string("device", "l3_device") ?? ""
            f.up = st?.bool("up") ?? false
            f.uptime = st?.int("uptime")
            f.ips = st?.list("ipv4-address").compactMap { $0.sub()?.string("address") } ?? []
            if let route = st?.list("route").first(where: { $0.sub("target")?.string("target") == "0.0.0.0" })?.sub() {
                f.gateway = route.string("gateway") ?? ""
            }
            f.dns = st?.list("dns-server").compactMap { $0.string() } ?? []
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
                res.append(WifiClient(mac: (c.string("mac") ?? "?").uppercased(),
                                      ifname: dev,
                                      signal: c.int("signal"),
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
            "i=0; for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do echo \"$i=$(($(cat $f) / 1000))\"; i=$((i+1)); done"
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

    func uciSet(_ config: String, _ section: String, _ option: String, _ value: String) async throws {
        let v = value.replacingOccurrences(of: "'", with: "'\\''")
        _ = try await exec("uci set \(config.shellQ).\(section.shellQ).\(option.shellQ)='\(v)' && uci commit \(config.shellQ)", allowDangerous: true)
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
