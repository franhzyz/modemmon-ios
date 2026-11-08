import SwiftUI

// MARK: - Сеть (NetworkScreen)

struct NetworkView: View {
    @EnvironmentObject var app: AppState
    @State private var ifaces: [Iface]?
    @State private var leasesList: [Lease]?

    var body: some View {
        List {
            uplinkCard
            ifacesCard
            if let l = leasesList { leasesCard(l) }
        }
        .navigationTitle("Сеть")
        .refreshable { await load() }
        .onAppear { if ifaces == nil { Task { await load() } } }
    }

    private var uplinkCard: some View {
        Section("Аплинк") {
            HStack {
                switch app.uplink.st {
                case .ok: MmBadge(text: "OK через \(app.uplink.path)", tone: .ok)
                case .fail: MmBadge(text: "FAIL", tone: .bad)
                case .checking: MmBadge(text: "проверка…", tone: .info)
                case .unknown: MmBadge(text: "?", tone: .neutral)
                }
                Spacer()
                Text(app.uplink.latencyMs.map { String(format: "%.0f мс", $0) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(Fmt.ago(app.uplink.checkedAt)).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await app.checkUplink() }
            } label: {
                Label("Проверить 204 (gstatic)", systemImage: "arrow.triangle.pull")
            }
        }
    }

    private var ifacesCard: some View {
        Section("Интерфейсы") {
            if let ifs = ifaces {
                if ifs.isEmpty { Text("Пусто").foregroundStyle(.secondary) }
                ForEach(ifs) { f in
                    IfaceRow(iface: f) { Task { await load() } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Button {
                Task {
                    await app.run { svc in try await svc.networkReload() }
                    await load()
                }
            } label: {
                Label("Перечитать сеть (network reload)", systemImage: "arrow.clockwise.circle")
            }
        }
    }

    private func leasesCard(_ list: [Lease]) -> some View {
        Section("DHCP-аренды (\(list.count))") {
            ForEach(list) { l in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(l.hostname).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(l.ip).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text("\(l.mac) · до \(l.expires)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() async {
        if app.conn == .demo {
            ifaces = DemoSource.ifaces()
            leasesList = [
                Lease(hostname: "franh-phone", ip: "192.168.2.50", mac: "A4:83:E7:AA:12:34", expires: "23:41"),
                Lease(hostname: "tv-samsung", ip: "192.168.2.51", mac: "5C:AA:FD:BB:56:78", expires: "22:07"),
            ]
            return
        }
        ifaces = await app.run { svc in try await svc.interfaces() }
        leasesList = await app.run { svc in try await svc.leases() }
    }
}

struct IfaceRow: View {
    @EnvironmentObject var app: AppState
    let iface: Iface
    var changed: () -> Void
    @State private var busy = false
    @State private var showEdit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(iface.name).font(.subheadline.weight(.semibold))
                MmBadge(text: iface.proto.isEmpty ? "?" : iface.proto, tone: .neutral)
                if !iface.device.isEmpty { Text(iface.device).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                MmBadge(text: iface.up ? "up" : "down", tone: iface.up ? .ok : .bad)
            }
            if !iface.ips.isEmpty {
                Text(iface.ips.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let rx = iface.rxBytes, let tx = iface.txBytes {
                    Label(Fmt.bytes(rx), systemImage: "arrow.down").font(.caption2).foregroundStyle(.secondary)
                    Label(Fmt.bytes(tx), systemImage: "arrow.up").font(.caption2).foregroundStyle(.secondary)
                }
                if let m = iface.metric {
                    Text("metric \(m)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                smallButton(iface.up ? "ifdown" : "ifup") { Task { await toggle() } }
                if iface.proto == "dhcp" {
                    smallButton("renew") { Task { await renew() } }
                }
                Button {
                    showEdit = true
                } label: {
                    Text("править").font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $showEdit) {
            NavigationStack {
                IfaceEditView(iface: iface) { Task { await changedReload() } }
            }
        }
    }

    private func changedReload() async {
        changed()
    }

    @ViewBuilder
    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if busy { ProgressView().controlSize(.small) } else { Text(title).font(.caption.weight(.semibold)) }
        }
        .buttonStyle(.borderless)
        .disabled(busy)
    }

    private func toggle() async {
        busy = true
        defer { busy = false }
        await app.run { svc in try await svc.ifaceToggle(iface.name, up: !iface.up) }
        changed()
    }

    private func renew() async {
        busy = true
        defer { busy = false }
        await app.run { svc in try await svc.ifaceRenew(iface.name) }
        changed()
    }
}

// MARK: - Правка интерфейса (IfaceEditScreen)

struct IfaceEditView: View {
    @EnvironmentObject var app: AppState
    let iface: Iface
    var saved: () -> Void
    @State private var cfg: UciConfig?
    @State private var metricDraft: String = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("Живой статус") {
                KVRow(key: "Статус", value: iface.up ? "up" : "down")
                KVRow(key: "IP", value: iface.ips.joined(separator: ", "))
                KVRow(key: "Шлюз", value: iface.gateway)
                KVRow(key: "DNS", value: iface.dns.joined(separator: ", "))
            }
            if let c = cfg, let sec = c.sections.first(where: { $0.name == iface.name }) {
                Section("UCI: network.\(iface.name)") {
                    ForEach(sec.options) { o in
                        UciOptionEditor(config: "network", section: sec.name, option: o) { Task { await load() } }
                    }
                }
            }
            Section {
                TextField("metric", text: $metricDraft)
                    .keyboardType(.numberPad)
                Button {
                    Task { await saveMetric() }
                } label: {
                    HStack { Spacer(); Text("Сохранить metric"); Spacer() }
                }
                .disabled(busy || Int(metricDraft) == nil)
            } header: {
                Text("Metric (failover-порядок)")
            } footer: {
                Text("Чем меньше metric, тем приоритетнее интерфейс. У wwan обычно 10, у резервного канала выше.")
            }
        }
        .navigationTitle("if: \(iface.name)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if cfg == nil { Task { await load() } }
            metricDraft = iface.metric.map(String.init) ?? ""
        }
    }

    private func load() async {
        if app.conn == .demo {
            cfg = DemoSource.uciNetwork()
            return
        }
        cfg = await app.run { svc in try await svc.uciShow("network") }
    }

    private func saveMetric() async {
        guard let m = Int(metricDraft) else { return }
        busy = true
        defer { busy = false }
        await app.run { svc in try await svc.ifaceSetMetric(iface.name, metric: m) }
        saved()
    }
}

// MARK: - Маршруты (RoutesScreen)

struct RoutesView: View {
    @EnvironmentObject var app: AppState
    @State private var routes: [Route]?

    var body: some View {
        List {
            Section {
                if let r = routes {
                    ForEach(r) { rt in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(rt.target)
                                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                                if rt.target == "default" { MmBadge(text: "default", tone: .info) }
                                Spacer()
                                Text("dev \(rt.iface)").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 10) {
                                if !rt.gateway.isEmpty { Text("via \(rt.gateway)") }
                                if !rt.source.isEmpty { Text("src \(rt.source)") }
                                if let m = rt.metric { Text("metric \(m)") }
                            }
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                Text("ip -4 route")
            }
        }
        .navigationTitle("Маршруты")
        .refreshable { await load() }
        .onAppear { if routes == nil { Task { await load() } } }
    }

    private func load() async {
        if app.conn == .demo {
            routes = DemoSource.routes()
            return
        }
        routes = await app.run { svc in try await svc.routes() }
    }
}

// MARK: - Wi-Fi (WifiScreen + ChannelsScreen)

struct WifiView: View {
    @EnvironmentObject var app: AppState
    @State private var aps: [WifiAp] = []
    @State private var clients: [WifiClient] = []
    @State private var devices: [String] = []
    @State private var loaded = false
    @State private var showScan = false

    var body: some View {
        List {
            Section("Радио") {
                if devices.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                ForEach(devices, id: \.self) { d in
                    HStack {
                        Image(systemName: "dot.radiowaves.right")
                        Text(d).font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        Button("скан") { showScan = true }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
            Section("Точки доступа") {
                if aps.isEmpty { Text("—").foregroundStyle(.secondary) }
                ForEach(aps, id: \.ssid) { ap in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ap.ssid.isEmpty ? "(без имени)" : ap.ssid)
                            Text("\(ap.radio) · \(ap.mode)\(ap.hidden ? " · скрытая" : "")\(ap.disabled ? " · выключена" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if ap.disabled { MmBadge(text: "off", tone: .bad) }
                    }
                }
            }
            Section("Подключённые клиенты (\(clients.count))") {
                if clients.isEmpty { Text("Нет клиентов").foregroundStyle(.secondary) }
                ForEach(clients) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(c.hostname.isEmpty ? c.mac : c.hostname)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(c.signal.map(String.init) ?? "—") dBm")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle((c.signal ?? -100) > -65 ? Color.green : ((c.signal ?? -100) > -75 ? .orange : .red))
                        }
                        HStack(spacing: 10) {
                            Text(c.mac).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            if let r = c.rxRate { Text("RX \(String(format: "%.0f", r)) Мбит/с") }
                            if let r = c.txRate { Text("TX \(String(format: "%.0f", r)) Мбит/с") }
                            if let t = c.connectedFor { Text("↑ \(Fmt.uptime(t))") }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Wi-Fi")
        .refreshable { await load() }
        .onAppear { if !loaded { loaded = true; Task { await load() } } }
        .sheet(isPresented: $showScan) {
            NavigationStack { WifiScanView(devices: devices) }
        }
    }

    private func load() async {
        if app.conn == .demo {
            devices = ["wlan0", "wlan1"]
            aps = [WifiAp(ssid: "MedveNet", radio: "wlan0", mode: "ap"),
                   WifiAp(ssid: "MedveNet-IoT", radio: "wlan1", mode: "ap")]
            clients = DemoSource.clients()
            return
        }
        devices = await app.run { svc in try await svc.wifiDevices() } ?? []
        aps = await app.run { svc in try await svc.wifiAps() } ?? []
        clients = await app.run { svc in try await svc.wifiClients() } ?? []
    }
}

struct WifiScanView: View {
    @EnvironmentObject var app: AppState
    let devices: [String]
    @State private var device: String = ""
    @State private var results: [ScanResult] = []
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Picker("Радио", selection: $device) {
                    ForEach(devices, id: \.self) { Text($0).tag($0) }
                }
                Button {
                    Task { await scan() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 8) }
                        Text("Сканировать").bold()
                        Spacer()
                    }
                }
                .disabled(busy || device.isEmpty)
            }
            Section("Сети (\(results.count))") {
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(r.ssid).font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(r.signal.map(String.init) ?? "—") dBm")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle((r.signal ?? -100) > -65 ? Color.green : ((r.signal ?? -100) > -75 ? .orange : .red))
                        }
                        HStack(spacing: 8) {
                            Text("ch \(r.channel.map(String.init) ?? "—") (\(r.band) ГГц)")
                            if !r.width.isEmpty { Text(r.width) }
                            Text(r.encryption.isEmpty ? "OPEN" : r.encryption)
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Скан окружения")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if device.isEmpty { device = devices.first ?? "" } }
    }

    private func scan() async {
        busy = true
        defer { busy = false }
        if app.conn == .demo {
            results = DemoSource.scan()
            return
        }
        results = await app.run { svc in try await svc.wifiScan(device) } ?? []
    }
}

// MARK: - VPN (VpnScreen: WireGuard / AmneziaWG)

struct VpnView: View {
    @EnvironmentObject var app: AppState
    @State private var instances: [VpnInstance]?
    @State private var busyName: String?

    var body: some View {
        List {
            if let list = instances {
                if list.isEmpty { Text("WireGuard/AmneziaWG не настроены").foregroundStyle(.secondary) }
                ForEach(list) { inst in
                    Section("wg: \(inst.name) \(inst.kind == "awg" ? "(AmneziaWG)" : "")") {
                        HStack {
                            MmBadge(text: inst.up ? "up" : "down", tone: inst.up ? .ok : .bad)
                            if !inst.address.isEmpty { Text(inst.address).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            if let p = inst.listenPort { Text(":\(p)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                            Spacer()
                            Button {
                                Task { await toggle(inst) }
                            } label: {
                                if busyName == inst.name { ProgressView().controlSize(.small) }
                                else { Text(inst.up ? "ifdown" : "ifup").font(.caption.weight(.semibold)) }
                            }
                            .buttonStyle(.borderless)
                            .disabled(busyName != nil)
                        }
                        ForEach(inst.peers) { peer in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(peer.name.isEmpty ? String(peer.publicKey.prefix(12)) + "…" : peer.name)
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    handshakeBadge(peer.latestHandshake)
                                }
                                if !peer.endpoint.isEmpty { Text("endpoint \(peer.endpoint)").font(.caption2.monospaced()).foregroundStyle(.secondary) }
                                Text("allowed \(peer.allowedIps)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                HStack(spacing: 10) {
                                    Label(Fmt.bytes(peer.rx), systemImage: "arrow.down")
                                    Label(Fmt.bytes(peer.tx), systemImage: "arrow.up")
                                }
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("VPN")
        .refreshable { await load() }
        .onAppear { if instances == nil { Task { await load() } } }
    }

    private func handshakeBadge(_ d: Date?) -> some View {
        guard let d else { return AnyView(MmBadge(text: "не рукопожатался", tone: .bad)) }
        let s = Date().timeIntervalSince(d)
        if s < 180 { return AnyView(MmBadge(text: "живой · \(Int(s)) с", tone: .ok)) }
        return AnyView(MmBadge(text: "давно · \(Fmt.ago(d))", tone: .warn))
    }

    private func toggle(_ inst: VpnInstance) async {
        busyName = inst.name
        defer { busyName = nil }
        await app.run { svc in try await svc.vpnToggle(inst.name, up: !inst.up) }
        await load()
    }

    private func load() async {
        if app.conn == .demo {
            instances = DemoSource.vpn()
            return
        }
        instances = await app.run { svc in try await svc.vpnInstances() }
    }
}
