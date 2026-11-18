import SwiftUI
import Charts

// MARK: - Обзор модема (ModemScreen + MonitorScreen)

struct OverviewView: View {
    @EnvironmentObject var app: AppState
    @State private var channels: [(Int, String)] = [] // (метрика, устройство)
    @State private var channelsLoaded = false
    @State private var switchingDev: String?
    @State private var channelsError: String?

    var body: some View {
        List {
            if let m = app.modem {
                statusCard(m)
                modemSwitchCard
                signalCard(m)
                qualityCard(m)
                if let s = app.sys { sysCard(s) }
                cellCard(m)
                tempCard(m)
                simCard(m)
                antennasCard(m)
                bearerCard(m)
                trafficCard(m)
                devicesCard
            } else {
                Section { ProgressView(L("Ждём данные…", "Waiting for data…")).frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle(L("Обзор модема", "Modem overview"))
        .refreshable { await app.checkUplink(); await loadChannels() }
        .onAppear {
            if modemDevices.isEmpty && app.conn != .demo { Task { await loadDevices() } }
            if !channelsLoaded { Task { await loadChannels() } }
        }
    }

    @State private var modemDevices: [RouterService.ModemDevice] = []
    @State private var netClients: [(String, String, String?, String?)] = [] // mac, ip, host, iface
    @State private var netClientsBusy = false

    // MARK: - Переключение между модемами

    /// Какой канал держит маршрут по умолчанию (основной/резерв).
    /// Переключение: uci-метрики (90/110) + reload; демон medvemodem следует.
    private var modemSwitchCard: some View {
        Section(L("Переключение модемов", "Modem switching")) {
            if !channelsLoaded && switchingDev == nil {
                Text(L("Загрузка…", "Loading…")).foregroundStyle(.secondary)
            }
            ForEach(Array(channels.enumerated()), id: \.offset) { idx, ch in
                HStack {
                    Text(Self.devLabel(ch.1))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(idx == 0 ? L("основной", "primary") : L("резерв", "backup"))
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                        .foregroundStyle(idx == 0 ? Color.green : Color.secondary)
                    if idx != 0 {
                        Button {
                            Task { await switchChannel(ch.1) }
                        } label: {
                            Text(L("Сделать основным", "Make primary"))
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .disabled(switchingDev != nil)
                    }
                }
            }
            if let sw = switchingDev {
                HStack {
                    ProgressView().padding(.trailing, 6)
                    Text(L("Переключаю на \(Self.devLabel(sw))… (~20-40 с)", "Switching to \(Self.devLabel(sw))… (~20-40 s)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let e = channelsError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            Text(L("Переключение меняет приоритет каналов (метрики). Автопереключение ", "Switching changes channel priority (metrics). Auto-failover ") +
                 L("при пропадании интернета продолжает работать; модем при смене перезванивает.", "keeps working when internet drops; the modem redials on switch."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func loadChannels() async {
        guard let svc = app.service else { return }
        let out = (try? await svc.execText(
            "ip route show default | while read -r line; do " +
            "dev=\"$(echo \"$line\" | sed -n \"s/.* dev \\([^ ]*\\).*/\\1/p\")\"; " +
            "met=\"$(echo \"$line\" | sed -n \"s/.* metric \\([0-9]*\\).*/\\1/p\")\"; " +
            "echo \"${met:-0} $dev\"; done | sort -n; exit 0"
        )) ?? ""
        let list = out
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { line -> (Int, String)? in
                let p = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard let m = p.first.flatMap({ Int($0) }), let d = p.dropFirst().first else { return nil }
                return (m, d)
            }
            .sorted { $0.0 < $1.0 }
        if !list.isEmpty {
            channels = list
            channelsLoaded = true
        }
    }

    private func switchChannel(_ dev: String) async {
        guard let svc = app.service, switchingDev == nil else { return }
        switchingDev = dev
        channelsError = nil
        let safe = dev.filter { "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".contains($0) }
        let script =
            "TARGET=\(safe); j=$(ubus call network.interface dump); " +
            "for d in $(ip route show default | sed -n \"s/.* dev \\([^ ]*\\).*/\\1/p\" | sort -u); do " +
            "s=$(jsonfilter -s \"$j\" -e \"@.interface[@.l3_device=\\\"$d\\\"].interface\" | head -1); " +
            "[ -n \"$s\" ] || continue; " +
            "if [ \"$d\" = \"$TARGET\" ]; then uci set network.$s.metric=\"90\"; " +
            "else uci set network.$s.metric=\"110\"; fi; done; " +
            "uci commit network; /etc/init.d/network reload >/dev/null 2>&1; echo switched"
        do {
            _ = try await svc.execText(script)
        } catch {
            channelsError = error.localizedDescription
            switchingDev = nil
            return
        }
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await loadChannels()
            if channels.first?.1 == dev {
                switchingDev = nil
                return
            }
        }
        channelsError = L("Переключение затянулось — проверь статус каналов", "Switching is taking too long — check channel status")
        switchingDev = nil
    }

    private static func devLabel(_ dev: String) -> String {
        if dev.hasPrefix("wwan") || dev.hasPrefix("qmi") { return L("Модем LTE (\(dev))", "LTE modem (\(dev))") }
        if dev.hasPrefix("usb") { return L("USB-модем (\(dev))", "USB modem (\(dev))") }
        if dev.hasPrefix("pppoe") || dev.contains("wan") || dev.hasPrefix("eth") { return L("Кабель (\(dev))", "Cable (\(dev))") }
        return dev
    }

    private func loadDevices() async {
        modemDevices = await app.run { svc in try await svc.modemDevices() } ?? []
    }

    // MARK: - Клиенты в сети (DHCP + ARP + Wi-Fi)

    private var clientsSection: some View {
        Section {
            Button {
                Task { await loadNetClients() }
            } label: {
                HStack {
                    if netClientsBusy { ProgressView().padding(.trailing, 6) }
                    Label(L("Обновить", "Refresh"), systemImage: "arrow.clockwise.circle")
                }
            }
            if netClients.isEmpty && !netClientsBusy {
                Text(L("Клиентов нет", "No clients")).foregroundStyle(.secondary)
            }
            ForEach(Array(netClients.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.2 ?? c.1).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(c.3 ?? "").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(c.1).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(c.0).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("Клиенты в сети", "Network clients"))
        } footer: {
            Text(L("DHCP-аренды + ARP-таблица + Wi-Fi-ассоциации, склеены по MAC.", "DHCP leases + ARP table + Wi-Fi associations, merged by MAC."))
        }
    }

    private func loadNetClients() async {
        netClientsBusy = true
        defer { netClientsBusy = false }
        if app.conn == .demo {
            netClients = [("AA:BB:CC:DD:EE:01", "192.168.2.50", "demo-pc", "phy0-ap0")]
            return
        }
        let script = "echo \"[leases]\"; cat /tmp/dhcp.leases 2>/dev/null | awk '{print $2\" \"$3\" \"$4}'; echo \"[arp]\"; ip neigh show 2>/dev/null | awk '$0 ~ /lladdr/ {ip=$1; dev=$3; mac=\"\"; for(i=1;i<=NF;i++) if($i==\"lladdr\") mac=$(i+1); print mac\" \"$1\" \"$3; exit 0'; echo \"[wifi]\"; for d in $(iwinfo 2>/dev/null | awk '/ESSID/{print $1}'); do iwinfo \"$d\" assoclist 2>/dev/null | awk -v d=\"$d\" '/^[0-9A-Fa-f][0-9A-Fa-f]:/{print $1\" \"d}'; done; exit 0"
        let out = await app.run({ svc in try? await svc.execText(script) }) ?? ""
        var lease: [String: (String, String)] = [:]
        var arp: [String: (Set<String>, String)] = [:]
        var wifi: [String: String] = [:]
        var sec = ""
        for line in out.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l == "[leases]" { sec = "leases"; continue }
            if l == "[arp]" { sec = "arp"; continue }
            if l == "[wifi]" { sec = "wifi"; continue }
            let p = l.split(separator: " ").map(String.init)
            guard p.count >= 2 else { continue }
            let mac = p[0].uppercased()
            if sec == "leases" { lease[mac] = (p[1], p.count > 2 ? p[2] : "") }
            if sec == "arp" {
                let old = arp[mac] ?? ([], "")
                var ips = old.0; ips.insert(p[1])
                arp[mac] = (ips, p.count > 2 ? p[2] : "")
            }
            if sec == "wifi" { wifi[mac] = p.count > 1 ? p[1] : "" }
        }
        var rows: [(String, String, String?, String?)] = []
        for m in Array(Set(lease.keys).union(arp.keys).union(wifi.keys)).sorted() {
            var ips = Array(arp[m]?.0 ?? [])
            if let li = lease[m]?.0, !li.isEmpty { ips.append(li) }
            let host = lease[m]?.1.isEmpty == false ? lease[m]!.1 : nil
            let iface = wifi[m]?.isEmpty == false ? wifi[m] : (arp[m]?.1.isEmpty == false ? arp[m]!.1 : nil)
            rows.append((m, ips.filter { !$0.isEmpty }.joined(separator: ", "), host, iface))
        }
        netClients = rows.sorted { ($0.2 ?? $0.1) < ($1.2 ?? $1.1) }
    }

    private var devicesCard: some View {
        Section(L("Устройства медвемодема", "MedveModem devices")) {
            if modemDevices.isEmpty {
                Text("—").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(modemDevices) { d in
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.id).font(.caption.monospaced())
                    if !d.device.isEmpty {
                        Text("device: \(d.device)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func antennasCard(_ m: ModemSnapshot) -> some View {
        Section(L("Антенны", "Antennas")) {
            if m.antennas.isEmpty {
                Text("—").foregroundStyle(.secondary)
            }
            ForEach(m.antennas) { a in
                HStack {
                    Text(L("Антенна \(a.chain + 1)", "Antenna \(a.chain + 1)")).font(.subheadline)
                    if !a.tuned { MmBadge(text: L("не настроена", "not configured"), tone: .warn) }
                    Spacer()
                    Text(a.rsrp.map { String(format: "%.1f dBm", $0) } ?? "—")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(rsrpColor(a.rsrp))
                    Text(a.power.map { String(format: "%.1f dBm", $0) } ?? "")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func bearerCard(_ m: ModemSnapshot) -> some View {
        let bi = m.bearerIface ?? ""
        return Section(L("Bearer (подключение к сети)", "Bearer (network connection)")) {
            KVRow(key: "APN", value: m.bearerApn.isEmpty ? "—" : m.bearerApn)
            KVRow(key: "IPv4", value: m.bearerIPv4.isEmpty ? "—" : m.bearerIPv4)
            KVRow(key: "MTU", value: m.bearerMtu.map(String.init) ?? "—")
            KVRow(key: L("Интерфейс", "Interface"), value: bi.isEmpty ? "—" : bi)
        }
    }

    private func trafficCard(_ m: ModemSnapshot) -> some View {
        Section(L("Трафик сессии", "Session traffic")) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                StatTile(title: L("Всего ↓", "Total ↓"), value: Fmt.bytes(m.trafficDl))
                StatTile(title: L("Всего ↑", "Total ↑"), value: Fmt.bytes(m.trafficUl))
                StatTile(title: L("Сессия", "Session"), value: m.connectTimeSec.map(Fmt.uptime) ?? "—")
            }
        }
    }

    private func statusCard(_ m: ModemSnapshot) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    SignalBars(rsrp: m.bestRsrp, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.operatorName.isEmpty ? "—" : m.operatorName)
                            .font(.title3.weight(.semibold))
                        HStack(spacing: 6) {
                            if !m.rat.isEmpty { MmBadge(text: m.rat, tone: .info) }
                            if !m.band.isEmpty { MmBadge(text: m.band, tone: .neutral) }
                            MmBadge(text: m.registration.isEmpty ? "?" : m.registration,
                                    tone: m.registration.contains("registered") ? .ok : .warn)
                        }
                    }
                    Spacer()
                }
                uplinkRow
            }
            .padding(.vertical, 4)
        }
    }

    private var uplinkRow: some View {
        HStack {
            switch app.uplink.st {
            case .ok:
                Image(systemName: "checkmark.icloud").foregroundStyle(.green)
                Text(L("Интернет через", "Internet via") + " \(app.uplink.path) · \(app.uplink.latencyMs.map { String(format: L("%.0f мс", "%.0f ms"), $0) } ?? "—")")
            case .fail:
                Image(systemName: "icloud.slash").foregroundStyle(.red)
                Text(L("Интернета нет", "No internet")).foregroundStyle(.red)
            case .checking:
                ProgressView().controlSize(.small)
                Text(L("Проверяем аплинк…", "Checking uplink…"))
            case .unknown:
                Image(systemName: "questionmark.icloud").foregroundStyle(.secondary)
                Text(L("Аплинк не проверен", "Uplink not checked"))
            }
            Spacer()
            Button(L("Проверить", "Check")) { Task { await app.checkUplink() } }
                .buttonStyle(.borderless)
                .font(.subheadline)
        }
        .font(.subheadline)
    }

    private func signalCard(_ m: ModemSnapshot) -> some View {
        Section(L("Сигнал", "Signal")) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if m.lteRsrp != nil || m.nrRsrp == nil {
                    StatTile(title: "LTE RSRP", value: Fmt.dbm(m.lteRsrp), tone: rsrpColor(m.lteRsrp))
                    StatTile(title: "RSRQ", value: Fmt.db(m.lteRsrq))
                    StatTile(title: "SINR", value: m.lteSinr.map { String(format: "%.1f dB", $0) } ?? "—", tone: sinrColor(m.lteSinr))
                }
                if m.lteRssi != nil {
                    StatTile(title: "RSSI", value: Fmt.dbm(m.lteRssi))
                }
                if m.nrRsrp != nil {
                    StatTile(title: "NR RSRP", value: Fmt.dbm(m.nrRsrp), tone: rsrpColor(m.nrRsrp))
                    StatTile(title: "NR RSRQ", value: Fmt.db(m.nrRsrq))
                    StatTile(title: "NR SINR", value: m.nrSinr.map { String(format: "%.1f dB", $0) } ?? "—", tone: sinrColor(m.nrSinr))
                }
            }
            if app.trends.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("RSRP, последние \(app.trends.count) замеров", "RSRP, last \(app.trends.count) samples"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Chart(app.trends, id: \.t) { p in
                        if let v = p.rsrp {
                            LineMark(x: .value("t", p.t), y: .value("rsrp", v))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(rsrpColor(p.rsrp))
                        }
                    }
                    .chartYScale(domain: -120 ... -60)
                    .frame(height: 110)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func qualityCard(_ m: ModemSnapshot) -> some View {
        Section {
            ProgressRow(label: L("Качество сигнала", "Signal quality"),
                        value: (m.qualityPercent ?? 0) / 100,
                        caption: m.qualityPercent.map { String(format: "%.0f%%", $0) },
                        color: rsrpColor(m.bestRsrp))
        }
    }

    private func sysCard(_ s: SysOverview) -> some View {
        Section(L("Роутер", "Router")) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                StatTile(title: L("Загрузка (1 мин)", "Load (1 min)"), value: String(format: "%.2f", s.load1), sub: String(format: "%.2f / %.2f", s.load5, s.load15))
                StatTile(title: L("Память", "Memory"), value: Fmt.bytes((s.memTotalKb - s.memFreeKb) * 1024), sub: L("всего \(Fmt.bytes(s.memTotalKb * 1024))", "total \(Fmt.bytes(s.memTotalKb * 1024))"))
                StatTile(title: "Uptime", value: Fmt.uptime(s.uptime))
                StatTile(title: "CPU", value: Fmt.temp(s.cpuTemp), sub: L("\(s.cores.count) ядер", "\(s.cores.count) cores"))
            }
            KVRow(key: L("Модель", "Model"), value: s.model)
            KVRow(key: L("Прошивка", "Firmware"), value: s.firmware)
            KVRow(key: L("Ядро", "Kernel"), value: s.kernel)
        }
    }

    private func cellCard(_ m: ModemSnapshot) -> some View {
        Section(L("Сота", "Cell")) {
            KVRow(key: "Cell ID", value: m.cellId.map { String($0) } ?? "—")
            KVRow(key: "EARFCN", value: m.earfcn.map { String($0) } ?? "—")
            KVRow(key: "PCI", value: m.pci.map { String($0) } ?? "—")
            KVRow(key: L("Бэнд", "Band"), value: m.band)
            NavigationLink(L("Соты вокруг →", "Cells around →"), value: "cells")
                .font(.subheadline)
        }
    }

    private func tempCard(_ m: ModemSnapshot) -> some View {
        Section(L("Температуры", "Temperatures")) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                StatTile(title: L("Модем", "Modem"), value: Fmt.temp(m.tempModem), tone: m.tempModem.map { $0 > 65 ? Color.red : ($0 > 55 ? .orange : .green) } ?? .primary)
                StatTile(title: "PA", value: Fmt.temp(m.tempPa))
            }
            if !m.tempSource.isEmpty {
                KVRow(key: L("Источник", "Source"), value: m.tempSource)
            }
        }
    }

    private func simCard(_ m: ModemSnapshot) -> some View {
        Section(L("SIM / модем", "SIM / modem")) {
            KVRow(key: L("Оператор", "Operator"), value: "\(m.operatorName) (\(m.operatorCode))")
            KVRow(key: "IMSI", value: m.sim.imsi)
            KVRow(key: "ICCID", value: m.sim.iccid)
            KVRow(key: "IMEI", value: m.sim.imei)
            KVRow(key: L("Модель", "Model"), value: m.modelName)
            KVRow(key: L("Прошивка", "Firmware"), value: m.fwVersion)
        }
    }
}

// MARK: - Соты (CellScreen)

struct CellsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        List {
            if let m = app.modem {
                Section(L("Текущая сота", "Current cell")) {
                    KVRow(key: "RAT", value: m.rat)
                    KVRow(key: "Cell ID", value: m.cellId.map { String($0) } ?? "—")
                    KVRow(key: "EARFCN", value: m.earfcn.map { String($0) } ?? "—")
                    KVRow(key: "PCI", value: m.pci.map { String($0) } ?? "—")
                    KVRow(key: L("Бэнд", "Band"), value: m.band)
                    KVRow(key: "RSRP", value: Fmt.dbm(m.bestRsrp), valueTone: rsrpColor(m.bestRsrp))
                    KVRow(key: "SINR", value: m.bestSinr.map { String(format: "%.1f dB", $0) } ?? "—", valueTone: sinrColor(m.bestSinr))
                }
                Section(L("Соседние соты (\(m.neighbors.count))", "Neighbor cells (\(m.neighbors.count))")) {
                    if m.neighbors.isEmpty {
                        Text(L("Нет данных от medvemodem", "No data from medvemodem")).foregroundStyle(.secondary)
                    }
                    ForEach(m.neighbors) { c in
                        HStack(spacing: 10) {
                            SignalBars(rsrp: c.rsrp, size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    MmBadge(text: c.rat.isEmpty ? "?" : c.rat, tone: .info)
                                    if !c.band.isEmpty { Text(c.band).font(.caption).foregroundStyle(.secondary) }
                                }
                                Text("EARFCN \(c.earfcn.map(String.init) ?? "—") · PCI \(c.pci.map(String.init) ?? "—")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Fmt.dbm(c.rsrp)).font(.callout.monospacedDigit()).foregroundStyle(rsrpColor(c.rsrp))
                                Text(Fmt.db(c.rsrq)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle(L("Соты", "Cells"))
    }
}

// MARK: - Бэнды (BandsScreen)

struct BandsView: View {
    @EnvironmentObject var app: AppState
    @State private var supported: [String] = []
    @State private var allowed: [String] = []
    @State private var selected: Set<String> = []
    @State private var loaded = false
    @State private var loading = false
    @State private var busy = false

    var body: some View {
        List {
            Section(L("Сейчас разрешены", "Currently allowed")) {
                Text(allowed.isEmpty ? "—" : allowed.joined(separator: ", "))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Section {
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if supported.isEmpty {
                    Text(L("Список бэндов недоступен. Проверьте соединение и повторите попытку.", "Band list unavailable. Check the connection and try again."))
                        .foregroundStyle(.secondary)
                    Button(L("Повторить", "Retry")) { Task { await load() } }
                } else {
                    ForEach(supported, id: \.self) { b in
                        Button {
                            if selected.contains(b) { selected.remove(b) } else { selected.insert(b) }
                        } label: {
                            HStack {
                                Text(b).font(.system(.body, design: .monospaced).weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selected.contains(b) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(b) ? Color.accentColor : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
            } header: {
                Text(L("Лок бэндов (выберите разрешённые)", "Band lock (choose allowed)"))
            } footer: {
                Text(L("Пустой выбор = автоматический выбор бэндов. Применение может временно прервать связь.", "Empty selection = automatic band selection. Applying may briefly drop the connection."))
            }
            Section {
                Button {
                    Task { await apply() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 8) }
                        Text(L("Применить (\(selected.count))", "Apply (\(selected.count))")).bold()
                        Spacer()
                    }
                }
                .disabled(busy || loading || supported.isEmpty)
                Button(L("Сбросить ограничения (авто)", "Reset restrictions (auto)")) { selected.removeAll() }
                    .foregroundStyle(.secondary)
                    .disabled(busy || loading || supported.isEmpty)
            }
        }
        .navigationTitle(L("Бэнды", "Bands"))
        .onAppear {
            if !loaded {
                loaded = true
                Task { await load() }
            }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if app.conn == .demo {
            supported = ["B1", "B3", "B7", "B20", "n78"]
            allowed = ["B3", "n78"]
            selected = Set(allowed)
            return
        }
        if let info = await app.run({ svc in try await svc.bandsInfo() }) {
            supported = info.supported
            allowed = info.allowed
            selected = Set(info.allowed.filter { info.supported.contains($0) })
        }
    }

    private func apply() async {
        guard app.conn != .demo else { app.banner = L("В демо-режиме бэнды не применяются", "Bands are not applied in demo mode"); return }
        guard let service = app.service else { app.banner = L("Нет подключения к роутеру", "Not connected to the router"); return }
        busy = true
        defer { busy = false }
        do {
            try await service.applyBands(Array(selected).sorted())
            if let info = await app.run({ svc in try await svc.bandsInfo() }) {
                allowed = info.allowed
                supported = info.supported
                selected = Set(info.allowed.filter { info.supported.contains($0) })
            } else {
                app.banner = L("Команда отправлена, но проверить результат не удалось. Обновите список.", "The command was sent but the result could not be checked. Refresh the list.")
            }
        } catch {
            app.banner = L("Бэнды: \(error.localizedDescription)", "Bands: \(error.localizedDescription)")
        }
    }
}

// MARK: - SMS / USSD / AT (SmsCard + UssdCard + AtCard + ConsoleBox)

struct SmsUssdAtView: View {
    var body: some View {
        TabView {
            SmsTab()
                .tabItem { Label("SMS", systemImage: "message") }
            UssdTab()
                .tabItem { Label("USSD", systemImage: "number.square") }
            AtTab()
                .tabItem { Label("AT", systemImage: "chevron.left.forwardslash.chevron.right") }
        }
        .navigationTitle("SMS · USSD · AT")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SmsTab: View {
    @EnvironmentObject var app: AppState
    @State private var sms: [Sms] = []
    @State private var loading = false
    @State private var showSend = false
    @State private var newNumber = ""
    @State private var newText = ""

    var body: some View {
        List {
            Section {
                Button {
                    showSend = true
                } label: {
                    Label(L("Написать SMS", "Compose SMS"), systemImage: "square.and.pencil")
                }
            }
            Section(L("Входящие (\(sms.count))", "Inbox (\(sms.count))")) {
                if loading && sms.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if sms.isEmpty {
                    Text(L("Пусто", "Empty")).foregroundStyle(.secondary)
                }
                ForEach(sms) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(m.number).font(.subheadline.weight(.semibold))
                            if m.isNew { MmBadge(text: L("новое", "new"), tone: .info) }
                            Spacer()
                            Text(Fmt.time(m.ts)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(m.text).font(.callout)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                await app.run { svc in try await svc.smsDelete(id: m.id) }
                                sms.removeAll { $0.id == m.id }
                            }
                        } label: { Label(L("Удалить", "Delete"), systemImage: "trash") }
                    }
                }
            }
        }
        .refreshable { await load() }
        .onAppear { if sms.isEmpty { Task { await load() } } }
        .alert(L("Новое SMS", "New SMS"), isPresented: $showSend) {
            TextField(L("Номер", "Number"), text: $newNumber)
                .keyboardType(.phonePad)
            TextField(L("Текст", "Text"), text: $newText)
            Button(L("Отправить", "Send")) { Task { await send() } }
            Button(L("Отмена", "Cancel"), role: .cancel) { }
        } message: {
            Text(L("SMS уйдёт через модем роутера", "SMS goes via the router modem"))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if app.conn == .demo {
            sms = DemoSource.smsList()
            return
        }
        let r = await app.run { svc in try await svc.smsList() }
        if let r { sms = r }
    }

    private func send() async {
        let num = newNumber, txt = newText
        guard app.conn != .demo else { app.banner = L("В демо-режиме SMS не отправляются", "SMS is not sent in demo mode"); return }
        guard let _: Void = await app.run({ svc in try await svc.smsSend(number: num, text: txt) }) else { return }
        newNumber = ""; newText = ""
        await load()
    }
}

struct UssdTab: View {
    @EnvironmentObject var app: AppState
    @State private var code = "*100#"
    @State private var status = ""
    @State private var reply = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section(L("Запрос", "Request")) {
                TextField(L("USSD-код", "USSD code"), text: $code)
                    .keyboardType(.numbersAndPunctuation)
                    .font(.system(.body, design: .monospaced))
                Button {
                    Task { await start() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 8) }
                        Text(L("Отправить", "Send")).bold()
                        Spacer()
                    }
                }
                .disabled(busy)
            }
            if !status.isEmpty {
                Section(L("Статус", "Status")) {
                    Text(status).foregroundStyle(.secondary)
                }
            }
            if !reply.isEmpty {
                Section(L("Ответ", "Response")) {
                    Text(reply)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func start() async {
        busy = true
        reply = ""
        status = L("отправляем…", "sending…")
        if app.conn == .demo {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            status = L("готово", "done")
            reply = L("На счету 312.45 руб. Демо.", "Balance 312.45 RUB. Demo.")
            busy = false
            return
        }
        let r = await app.run { svc in try await svc.ussdRun(code: code) }
        busy = false
        if let r {
            status = L("готово", "done")
            reply = r
        } else {
            status = L("ошибка — см. баннер", "error — see the banner")
        }
    }
}

struct AtTab: View {
    @EnvironmentObject var app: AppState
    @State private var cmd = "AT+CSQ"
    @State private var out: [String] = []
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(out.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.opacity(0.85))
            .foregroundStyle(.green)
            Divider()
            HStack(spacing: 8) {
                TextField(L("AT-команда", "AT command"), text: $cmd)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit { Task { await send() } }
                if busy { ProgressView().controlSize(.small) }
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(busy || cmd.isEmpty)
            }
            .padding(10)
        }
        .navigationTitle(L("AT-консоль", "AT console"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() async {
        let c = cmd
        cmd = "AT"
        out.append("→ \(c)")
        busy = true
        if app.conn == .demo {
            out.append(c == "AT+CSQ" ? "+CSQ: 21,99" : L("OK (демо)", "OK (demo)"))
            busy = false
            return
        }
        let r = await app.run { svc in try await svc.sendAt(c) }
        busy = false
        out.append(r ?? L("(ошибка — см. баннер)", "(error — see the banner)"))
        if out.count > 300 { out.removeFirst(out.count - 300) }
    }
}
