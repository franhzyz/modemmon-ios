import Foundation

// MARK: - Свободный JSON (сервер может отдавать snake_case или camelCase)

struct J {
    let v: Any

    init(_ any: Any) { v = any }
    init?(data: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: data) else { return nil }
        v = o
    }

    var dict: [String: Any] { v as? [String: Any] ?? [:] }
    var array: [Any] { v as? [Any] ?? [] }
    var strings: [String] { array.compactMap { $0 as? String } }

    func value(_ keys: String...) -> Any? {
        for k in keys { if let x = dict[k], !(x is NSNull) { return x } }
        return nil
    }

    func string(_ keys: String...) -> String? {
        if keys.isEmpty {
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
        for k in keys {
            if let x = dict[k], !(x is NSNull) {
                if let s = x as? String { return s }
                if let n = x as? NSNumber { return n.stringValue }
            }
        }
        return nil
    }

    func stringsSafe(_ keys: String...) -> [String] {
        for k in keys {
            if let a = dict[k] as? [Any] {
                return a.compactMap { el -> String? in
                    if let s = el as? String { return s }
                    if let n = el as? NSNumber { return n.stringValue }
                    return nil
                }
            }
            if let s = dict[k] as? String {
                return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        return []
    }

    func numList(_ keys: String...) -> [Double] {
        for k in keys {
            if let a = dict[k] as? [Any] {
                return a.compactMap { el -> Double? in
                    if let n = el as? NSNumber { return n.doubleValue }
                    if let s = el as? String { return Double(s) }
                    return nil
                }
            }
        }
        return []
    }

    func sub(_ keys: String...) -> J? {
        if keys.isEmpty { return self }
        if let x = valueArr(keys) as? [String: Any] { return J(x) }
        return nil
    }

    func num(_ keys: String...) -> Double? { numArr(keys) }

    func int(_ keys: String...) -> Int? {
        guard let d = numArr(keys) else { return nil }
        return Int(d)
    }

    func bool(_ keys: String...) -> Bool { boolArr(keys) }

    func list(_ keys: String...) -> [J] { listArr(keys) }

    // Внутренние версии с обычным массивом (Swift не разворачивает массив в variadic)
    private func valueArr(_ keys: [String]) -> Any? {
        for k in keys { if let x = dict[k], !(x is NSNull) { return x } }
        return nil
    }

    private func numArr(_ keys: [String]) -> Double? {
        guard let x = valueArr(keys) else { return nil }
        switch x {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.replacingOccurrences(of: ",", with: "."))
        default: return nil
        }
    }

    private func boolArr(_ keys: [String]) -> Bool {
        guard let x = valueArr(keys) else { return false }
        switch x {
        case let b as NSNumber: return b.boolValue
        case let s as String: return ["1", "true", "yes", "on", "up"].contains(s.lowercased())
        default: return false
        }
    }

    private func listArr(_ keys: [String]) -> [J] {
        guard let a = valueArr(keys) as? [Any] else { return [] }
        return a.map { J($0) }
    }
}

// MARK: - Модем

struct NeighborCell: Identifiable {
    let id = UUID()
    var rat: String = ""
    var earfcn: Int?
    var pci: Int?
    var rsrp: Double?
    var rsrq: Double?
    var band: String = ""
}

struct Sms: Identifiable {
    var id: String
    var number: String = ""
    var text: String = ""
    var ts: Date?
    var isNew: Bool = false
}

struct SimInfo {
    var imsi: String = ""
    var iccid: String = ""
    var imei: String = ""
}

struct ModemSnapshot {
    var operatorName: String = ""
    var operatorCode: String = ""
    var registration: String = ""      // registered / searching / denied …
    var rat: String = ""               // LTE / NR / 5G-SA …
    var mode: String = ""              // режим работы модема
    var sim: SimInfo = SimInfo()

    var lteRsrp: Double?
    var lteRsrq: Double?
    var lteSinr: Double?
    var lteRssi: Double?

    var nrRsrp: Double?
    var nrRsrq: Double?
    var nrSinr: Double?

    var cellId: Int?
    var earfcn: Int?
    var pci: Int?
    var band: String = ""

    var supportedBands: [String] = []
    var activeBands: [String] = []

    var tempModem: Double?
    var tempPa: Double?
    var tempSkin: Double?
    var tempSource: String = ""
    var tempStatus: String = ""

    var qualityPercent: Double?
    var signalHistory: [Double] = []
    var neighbors: [NeighborCell] = []

    var modelName: String = ""
    var fwVersion: String = ""

    var ussdReply: String = ""
    var ussdStatus: String = ""

    static let empty = ModemSnapshot()

    init() {}

    init(j: J) {
        operatorName = j.string("operator_name", "operatorName", "operator") ?? ""
        operatorCode = j.string("operator_code", "operatorCode") ?? ""
        registration = j.string("registration_type", "registrationType", "registration") ?? ""
        rat = j.string("rat", "network_type", "technology", "mode") ?? ""
        mode = j.string("modem_mode", "netmode") ?? ""
        sim.imsi = j.string("imsi_masked", "imsi") ?? ""
        sim.iccid = j.string("iccid_masked", "iccid") ?? ""
        sim.imei = j.string("imei") ?? ""

        lteRsrp = j.num("lte_rsrp", "rsrp")
        lteRsrq = j.num("lte_rsrq", "rsrq")
        lteSinr = j.num("lte_sinr", "sinr")
        lteRssi = j.num("lte_rssi", "rssi")
        nrRsrp = j.num("nr_rsrp")
        nrRsrq = j.num("nr_rsrq")
        nrSinr = j.num("nr_sinr")

        cellId = j.int("cell_id", "cellId", "cid")
        earfcn = j.int("earfcn", "earfcn_dl")
        pci = j.int("pci")
        band = j.string("band", "bands") ?? ""

        supportedBands = j.stringsSafe("supported_bands", "supportedBands")
        activeBands = j.stringsSafe("bands", "active_bands")

        tempModem = j.num("temp_c", "temperature", "modem_temp")
        tempPa = j.num("temp_pa_c")
        tempSkin = j.num("temp_skin_c")
        tempSource = j.string("temp_source") ?? ""
        tempStatus = j.string("temp_status") ?? ""

        qualityPercent = j.num("signal_quality_percent", "signalQualityPercent")
        signalHistory = j.numList("signal_history", "signalHistory")
        neighbors = j.list("neighbors", "neighbor_cells").map { c in
            NeighborCell(rat: c.string("rat") ?? "",
                         earfcn: c.int("earfcn"),
                         pci: c.int("pci"),
                         rsrp: c.num("rsrp"),
                         rsrq: c.num("rsrq"),
                         band: c.string("band") ?? "")
        }
        modelName = j.string("model_name", "modelName", "model") ?? ""
        fwVersion = j.string("fw_version", "firmware") ?? ""
        ussdReply = j.string("ussd_reply", "ussdReply") ?? ""
        ussdStatus = j.string("ussd_status", "ussdStatus") ?? ""
    }

    var bestRsrp: Double? { nrRsrp ?? lteRsrp }
    var bestSinr: Double? { nrSinr ?? lteSinr }
}

// MARK: - Сеть

struct Iface: Identifiable {
    var id: String { name }
    var name: String
    var proto: String = ""
    var device: String = ""
    var up: Bool = false
    var uptime: Int?
    var ips: [String] = []
    var gateway: String = ""
    var dns: [String] = []
    var rxBytes: Int64?
    var txBytes: Int64?
    var metric: Int?
    var auto: Bool = true
}

struct Lease: Identifiable {
    var id: String { mac + ip }
    var hostname: String
    var ip: String
    var mac: String
    var expires: String
}

struct WifiAp {
    var ssid: String = ""
    var radio: String = ""
    var ifname: String = ""
    var mode: String = ""
    var hidden: Bool = false
    var disabled: Bool = false
}

struct WifiClient: Identifiable {
    var id: String { mac }
    var mac: String
    var ifname: String = ""
    var signal: Int?
    var noise: Int?
    var rxRate: Double?
    var txRate: Double?
    var connectedFor: Int?
    var hostname: String = ""
}

struct ScanResult: Identifiable {
    var id: String { bssid + ssid }
    var ssid: String
    var bssid: String
    var channel: Int?
    var band: String = ""
    var signal: Int?
    var width: String = ""
    var encryption: String = ""
}

struct Route: Identifiable {
    var id = UUID()
    var iface: String
    var target: String
    var gateway: String
    var source: String
    var metric: Int?
    var proto: String
}

// MARK: - Система

struct Package: Identifiable {
    var id: String { name }
    var name: String
    var version: String = ""
    var size: String = ""
    var desc: String = ""
}

struct ServiceStatus: Identifiable {
    var id: String { name }
    var name: String
    var enabled: Bool = false
    var running: Bool = false
}

struct ProcInfo: Identifiable {
    var id: Int
    var user: String = ""
    var cpu: Double? = nil
    var mem: Double? = nil
    var rss: Int64? = nil
    var command: String = ""
}

struct LedInfo: Identifiable {
    var id: String { name }
    var name: String
    var brightness: Int?
    var maxBrightness: Int?
    var trigger: String = ""
}

struct BackupFile: Identifiable {
    var id: String { path }
    var path: String
    var size: Int64?
    var mtime: Date?
}

struct CpuCore: Identifiable {
    var id: Int
    var freqMhz: Int?
    var load: Double?
}

struct SysOverview {
    var hostname: String = ""
    var model: String = ""
    var firmware: String = ""
    var kernel: String = ""
    var uptime: Int = 0
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    var memTotalKb: Int64 = 0
    var memFreeKb: Int64 = 0
    var memCachedKb: Int64 = 0
    var cpuTemp: Double?
    var cores: [CpuCore] = []
}

// MARK: - UCI

struct UciOption: Identifiable {
    var id: String { name }
    var name: String
    var value: String
}

struct UciSection: Identifiable {
    var id: UUID = UUID()
    var name: String       //匿名 → @type[idx]
    var type: String
    var anon: Bool = false
    var options: [UciOption] = []
}

struct UciConfig {
    var name: String
    var sections: [UciSection] = []
}

// MARK: - VPN

struct VpnPeer: Identifiable {
    var id: String { publicKey }
    var name: String = ""
    var publicKey: String
    var endpoint: String = ""
    var allowedIps: String = ""
    var latestHandshake: Date?
    var rx: Int64?
    var tx: Int64?
    var keepalive: Int?
}

struct VpnInstance: Identifiable {
    var id: String { name }
    var name: String
    var kind: String   // wg | awg
    var up: Bool = false
    var address: String = ""
    var listenPort: Int?
    var publicKey: String = ""
    var peers: [VpnPeer] = []
}

// MARK: - WoL / Терминал / Разное

struct WolTarget: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var mac: String
    var iface: String
}

struct TermLine: Identifiable {
    let id = UUID()
    var text: String
    var isCmd: Bool
}

struct HistoryPoint {
    var t: Date
    var rsrp: Double?
    var sinr: Double?
    var quality: Double?
    var rxKbps: Double?
    var txKbps: Double?
}

struct FileEntry: Identifiable {
    var id: String { name }
    var name: String
    var size: Int64?
    var isDir: Bool
    var mode: String = ""
    var mtime: Date?
}

struct UplinkState: Equatable {
    enum St: Equatable { case unknown, checking, ok, fail }
    var st: St = .unknown
    var latencyMs: Double?
    var path: String = ""        // через какой интерфейс
    var checkedAt: Date?
    var detail: String = ""
}
