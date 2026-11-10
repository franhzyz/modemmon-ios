import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Conn: Equatable {
        case disconnected
        case connecting
        case connected
        case demo
    }

    // MARK: - Публикуемое состояние

    @Published var profiles: [RouterProfile] {
        didSet { Store.saveProfiles(profiles) }
    }
    @Published var activeId: UUID? {
        didSet { Store.saveActiveId(activeId) }
    }
    @Published var settings: MmSettings {
        didSet { Store.saveSettings(settings) }
    }
    @Published var conn: Conn = .disconnected
    @Published var connError: String?
    @Published var banner: String?

    @Published var modem: ModemSnapshot?
    @Published var sys: SysOverview?
    @Published var ifaceRates: [String: Double] = [:]      // iface → rx+tx kbit/s
    @Published var trends: [HistoryPoint] = []
    @Published var uplink = UplinkState()
    @Published var aclOk: Bool?

    // MARK: - Внутреннее

    private(set) var ubus: UbusClient?
    private(set) var activeProfile: RouterProfile?
    private var pollTask: Task<Void, Never>?
    private var prevNetDev: [String: (rx: Int64, tx: Int64, t: Date)] = [:]
    private var failCount = 0

    init() {
        profiles = Store.loadProfiles()
        activeId = Store.loadActiveId()
        settings = Store.loadSettings()
        if activeId == nil || !profiles.contains(where: { $0.id == activeId }) {
            activeId = profiles.first?.id
        }
    }

    var active: RouterProfile? {
        if let id = activeId, let p = profiles.first(where: { $0.id == id }) { return p }
        return profiles.first
    }

    var isConnected: Bool { conn == .connected || conn == .demo }

    // MARK: - Пароли

    func password(for p: RouterProfile) -> String { Keychain.password(for: p.id.uuidString) }
    func savePassword(_ v: String, for p: RouterProfile) { Keychain.setPassword(v, for: p.id.uuidString) }

    // MARK: - Подключение

    func connect(_ p: RouterProfile, password: String) async {
        conn = .connecting
        connError = nil
        banner = nil
        savePassword(password, for: p)
        let client = UbusClient(base: p.baseURL)
        do {
            try await client.login(user: p.user, pass: password)
            ubus = client
            activeProfile = p
            conn = .connected
            // ACL: если его ещё нет — ставим синхронно и перелогиниваемся,
            // потому что установка перезапускает rpcd и старая сессия умирает
            let has = (try? await Install.aclInstalled(client)) ?? false
            if !has {
                try? await Install.installAcl(client)
                try? await client.login(user: p.user, pass: password)
            }
            startPolling()
        } catch {
            ubus = nil
            conn = .disconnected
            connError = error.localizedDescription
        }
    }

    func connectDemo() {
        settings.demo = true
        conn = .demo
        connError = nil
        activeProfile = RouterProfile.default
        startPolling()
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        ubus = nil
        conn = .disconnected
        modem = nil
        sys = nil
        trends = []
        uplink = UplinkState()
    }

    // MARK: - Доступ к сервису

    var service: RouterService? {
        guard let p = activeProfile else { return nil }
        return RouterService(ubus: ubus ?? UbusClient(base: p.baseURL),
                             http: HttpJson(base: p.baseURL),
                             profile: p,
                             settings: settings)
    }

    /// Выполнить действие с роутером; ошибки показываются в баннере.
    func run<T>(_ body: @escaping (RouterService) async throws -> T) async -> T? {
        guard var svc = service, isConnected else { return nil }
        do {
            let r = try await body(svc)
            failCount = 0
            return r
        } catch MmError.sessionExpired {
            // одна попытка перелогина
            guard let p = activeProfile else { return nil }
            do {
                try await svc.ubus.login(user: p.user, pass: password(for: p))
                return try await body(svc)
            } catch {
                banner = "Сессия истекла, перелогин не удался: \(error.localizedDescription)"
                return nil
            }
        } catch {
            banner = error.localizedDescription
            return nil
        }
    }

    func clearBanner() { banner = nil }

    // MARK: - Поллинг

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let dt = await (self?.settings.pollInterval ?? 2.0)
                try? await Task.sleep(nanoseconds: UInt64(dt * 1_000_000_000))
            }
        }
    }

    private func pollOnce() async {
        if conn == .demo {
            modem = DemoSource.modem()
            sys = DemoSource.sys()
            appendTrend(rxKbps: DemoSource.jitter(1800, 300), txKbps: DemoSource.jitter(900, 200))
            if uplink.st == .unknown || (uplink.checkedAt.map { Date().timeIntervalSince($0) > 30 } ?? true) {
                uplink = UplinkState(st: .ok, latencyMs: DemoSource.jitter(38, 12), path: "wwan0", checkedAt: Date(), detail: "demo")
            }
            return
        }
        guard let svc = service else { return }

        // Живость связи: системный опрос обязателен
        do {
            sys = try await svc.quickSys()
            failCount = 0
        } catch {
            // сессия могла умереть (например, ставили ACL — rpcd перезапускался)
            if case MmError.sessionExpired = error { await relogin(); return }
            if case MmError.ubus(let code) = error, code == 6 { await relogin(); return }
            failCount += 1
            if failCount >= 3 {
                disconnect()
                connError = "Связь потеряна (шаг: системный опрос): \(error.localizedDescription)"
            }
            return
        }
        // Остальное — по возможности
        if let devs = try? await svc.netDev() { updateRates(devs) }
        // Данные модема (CGI medvemodem) — необязательны: их может не быть на роутере
        if let mres = try? await svc.modemStatus() {
            modem = mres
            // телеметрия сама говорит про интернет — не гоняем лишний curl
            if let on = mres.online {
                uplink = UplinkState(st: on ? .ok : .fail,
                                     latencyMs: mres.reachLatencyMs ?? uplink.latencyMs,
                                     path: "wwan0",
                                     checkedAt: Date(),
                                     detail: "telemetry")
            }
        }
        appendTrend()
        if uplink.st == .unknown || (uplink.checkedAt.map { Date().timeIntervalSince($0) > 30 } ?? true) {
            await checkUplink()
        }
    }

    /// Перелогин с сохранением подключения.
    private func relogin() async {
        guard let p = activeProfile, let svc = service else { return }
        do {
            try await svc.ubus.login(user: p.user, pass: password(for: p))
            failCount = 0
        } catch {
            disconnect()
            connError = "Сессия истекла, перелогин не удался: \(error.localizedDescription)"
        }
    }

    private func updateRates(_ rows: [RouterService.NetDevRow]) {
        let now = Date()
        var rates: [String: Double] = [:]
        for r in rows {
            if let prev = prevNetDev[r.iface] {
                let dt = max(0.1, now.timeIntervalSince(prev.t))
                let kbps = (Double(r.rx - prev.rx) + Double(r.tx - prev.tx)) / dt * 8 / 1000
                rates[r.iface] = max(0, kbps)
            }
            prevNetDev[r.iface] = (r.rx, r.tx, now)
        }
        ifaceRates = rates
    }

    private func appendTrend(rxKbps: Double? = nil, txKbps: Double? = nil) {
        let mainIface = ifaceRates.max { $0.value < $1.value }?.key
        let rx = rxKbps ?? (mainIface.map { ifaceRates[$0] ?? 0 } ?? 0)
        let tx = txKbps ?? 0
        let p = HistoryPoint(t: Date(),
                             rsrp: modem?.bestRsrp,
                             sinr: modem?.bestSinr,
                             quality: modem?.qualityPercent,
                             rxKbps: rx,
                             txKbps: tx)
        trends.append(p)
        if trends.count > 300 { trends.removeFirst(trends.count - 300) }
    }

    // MARK: - Аплинк

    func checkUplink() async {
        uplink.st = .checking
        if conn == .demo {
            uplink = UplinkState(st: .ok, latencyMs: DemoSource.jitter(40, 10), path: "wwan0", checkedAt: Date(), detail: "demo")
            return
        }
        guard let svc = service else { return }
        let ifaces = ["wwan0", "wwan1", "eth1", "usb0"]
        for f in ifaces {
            if let probe = try? await svc.uplinkProbe(iface: f), probe.ok {
                uplink = UplinkState(st: .ok,
                                     latencyMs: probe.seconds.map { $0 * 1000 },
                                     path: f,
                                     checkedAt: Date(),
                                     detail: "HTTP \(probe.httpCode ?? 0)")
                return
            }
        }
        uplink = UplinkState(st: .fail, latencyMs: nil, path: "", checkedAt: Date(), detail: "204 нет ни на одном интерфейсе")
    }

    // MARK: - Меню (кастомизация, как modemmon_menu в Android)

    struct SectionItem: Identifiable {
        var key: String
        var title: String
        var icon: String
        var id: String { key }
    }

    static let sections: [SectionItem] = [
        SectionItem(key: "overview", title: "Обзор модема", icon: "antenna.radiowaves.left.and.right"),
        SectionItem(key: "cells", title: "Соты и сота", icon: "dot.radiowaves.left.and.right"),
        SectionItem(key: "bands", title: "Бэнды", icon: "slider.horizontal.3"),
        SectionItem(key: "sms", title: "SMS · USSD · AT", icon: "message"),
        SectionItem(key: "network", title: "Сеть", icon: "network"),
        SectionItem(key: "wifi", title: "Wi-Fi", icon: "wifi"),
        SectionItem(key: "vpn", title: "VPN (WireGuard)", icon: "shield.lefthalf.filled"),
        SectionItem(key: "forkop", title: "Форкоп (sing-box)", icon: "arrow.triangle.swap"),
        SectionItem(key: "routes", title: "Маршруты", icon: "arrow.triangle.branch"),
        SectionItem(key: "system", title: "Система", icon: "gearshape.2"),
        SectionItem(key: "services", title: "Службы", icon: "list.bullet.rectangle.portrait"),
        SectionItem(key: "config", title: "Конфиг UCI", icon: "list.bullet.indent"),
        SectionItem(key: "terminal", title: "Терминал", icon: "terminal"),
        SectionItem(key: "files", title: "Файлы", icon: "folder"),
        SectionItem(key: "wol", title: "Wake-on-LAN", icon: "bolt"),
        SectionItem(key: "diag", title: "Диагностика", icon: "stethoscope"),
        SectionItem(key: "links", title: "LuCI и телеметрия", icon: "safari"),
    ]

    var visibleSections: [SectionItem] {
        AppState.sections.filter { !settings.hiddenMenu.contains($0.key) }
    }

    func toggleMenu(_ key: String) {
        if settings.hiddenMenu.contains(key) { settings.hiddenMenu.remove(key) }
        else { settings.hiddenMenu.insert(key) }
    }
}
