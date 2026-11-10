import SwiftUI
import Charts

// MARK: - Обзор модема (ModemScreen + MonitorScreen)

struct OverviewView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        List {
            if let m = app.modem {
                statusCard(m)
                signalCard(m)
                qualityCard(m)
                if let s = app.sys { sysCard(s) }
                cellCard(m)
                tempCard(m)
                simCard(m)
            } else {
                Section { ProgressView("Ждём данные…").frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Обзор модема")
        .refreshable { await app.checkUplink() }
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
                Text("Интернет через \(app.uplink.path) · \(app.uplink.latencyMs.map { String(format: "%.0f мс", $0) } ?? "—")")
            case .fail:
                Image(systemName: "icloud.slash").foregroundStyle(.red)
                Text("Интернета нет").foregroundStyle(.red)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Проверяем аплинк…")
            case .unknown:
                Image(systemName: "questionmark.icloud").foregroundStyle(.secondary)
                Text("Аплинк не проверен")
            }
            Spacer()
            Button("Проверить") { Task { await app.checkUplink() } }
                .buttonStyle(.borderless)
                .font(.subheadline)
        }
        .font(.subheadline)
    }

    private func signalCard(_ m: ModemSnapshot) -> some View {
        Section("Сигнал") {
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
                    Text("RSRP, последние \(app.trends.count) замеров")
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
            ProgressRow(label: "Качество сигнала",
                        value: (m.qualityPercent ?? 0) / 100,
                        caption: m.qualityPercent.map { String(format: "%.0f%%", $0) },
                        color: rsrpColor(m.bestRsrp))
        }
    }

    private func sysCard(_ s: SysOverview) -> some View {
        Section("Роутер") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                StatTile(title: "Загрузка (1 мин)", value: String(format: "%.2f", s.load1), sub: String(format: "%.2f / %.2f", s.load5, s.load15))
                StatTile(title: "Память", value: Fmt.bytes((s.memTotalKb - s.memFreeKb) * 1024), sub: "всего \(Fmt.bytes(s.memTotalKb * 1024))")
                StatTile(title: "Uptime", value: Fmt.uptime(s.uptime))
                StatTile(title: "CPU", value: Fmt.temp(s.cpuTemp), sub: "\(s.cores.count) ядер")
            }
            KVRow(key: "Модель", value: s.model)
            KVRow(key: "Прошивка", value: s.firmware)
            KVRow(key: "Ядро", value: s.kernel)
        }
    }

    private func cellCard(_ m: ModemSnapshot) -> some View {
        Section("Сота") {
            KVRow(key: "Cell ID", value: m.cellId.map { String($0) } ?? "—")
            KVRow(key: "EARFCN", value: m.earfcn.map { String($0) } ?? "—")
            KVRow(key: "PCI", value: m.pci.map { String($0) } ?? "—")
            KVRow(key: "Бэнд", value: m.band)
            NavigationLink("Соты вокруг →", value: "cells")
                .font(.subheadline)
        }
    }

    private func tempCard(_ m: ModemSnapshot) -> some View {
        Section("Температуры") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                StatTile(title: "Модем", value: Fmt.temp(m.tempModem), tone: m.tempModem.map { $0 > 65 ? Color.red : ($0 > 55 ? .orange : .green) } ?? .primary)
                StatTile(title: "PA", value: Fmt.temp(m.tempPa))
            }
            if !m.tempSource.isEmpty {
                KVRow(key: "Источник", value: m.tempSource)
            }
        }
    }

    private func simCard(_ m: ModemSnapshot) -> some View {
        Section("SIM / модем") {
            KVRow(key: "Оператор", value: "\(m.operatorName) (\(m.operatorCode))")
            KVRow(key: "IMSI", value: m.sim.imsi)
            KVRow(key: "ICCID", value: m.sim.iccid)
            KVRow(key: "IMEI", value: m.sim.imei)
            KVRow(key: "Модель", value: m.modelName)
            KVRow(key: "Прошивка", value: m.fwVersion)
        }
    }
}

// MARK: - Соты (CellScreen)

struct CellsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        List {
            if let m = app.modem {
                Section("Текущая сота") {
                    KVRow(key: "RAT", value: m.rat)
                    KVRow(key: "Cell ID", value: m.cellId.map { String($0) } ?? "—")
                    KVRow(key: "EARFCN", value: m.earfcn.map { String($0) } ?? "—")
                    KVRow(key: "PCI", value: m.pci.map { String($0) } ?? "—")
                    KVRow(key: "Бэнд", value: m.band)
                    KVRow(key: "RSRP", value: Fmt.dbm(m.bestRsrp), valueTone: rsrpColor(m.bestRsrp))
                    KVRow(key: "SINR", value: m.bestSinr.map { String(format: "%.1f dB", $0) } ?? "—", valueTone: sinrColor(m.bestSinr))
                }
                Section("Соседние соты (\(m.neighbors.count))") {
                    if m.neighbors.isEmpty {
                        Text("Нет данных от medvemodem").foregroundStyle(.secondary)
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
        .navigationTitle("Соты")
    }
}

// MARK: - Бэнды (BandsScreen)

struct BandsView: View {
    @EnvironmentObject var app: AppState
    @State private var supported: [String] = []
    @State private var allowed: [String] = []
    @State private var selected: Set<String> = []
    @State private var backend: RouterService.BandsBackend?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            Section("Сейчас разрешены (allowed)") {
                Text(allowed.isEmpty ? "—" : allowed.joined(separator: ", "))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Section {
                if busy && supported.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let error, supported.isEmpty {
                    Text(error).foregroundStyle(.secondary)
                    Button("Повторить") { Task { await load() } }
                } else if supported.isEmpty {
                    Text("Нет данных о поддерживаемых бэндах")
                    Button("Обновить") { Task { await load() } }
                }
                ForEach(supported, id: \.self) { b in
                    Button {
                        if selected.contains(b) { selected.remove(b) } else { selected.insert(b) }
                    } label: {
                        HStack {
                            Text(b).font(.system(.body, design: .monospaced).weight(.medium)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selected.contains(b) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(b) ? Color.accentColor : .secondary)
                        }
                    }.disabled(busy)
                }
            } header: {
                Text("Лок бэндов (выберите разрешённые)")
            } footer: {
                Text("Пустой выбор = все поддерживаемые бэнды. При применении связь может временно пропасть.")
            }
            Section {
                Button { Task { await apply() } } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 8) }
                        Text("Применить (\(selected.count))").bold()
                        Spacer()
                    }
                }.disabled(busy || supported.isEmpty)
                Button("Разрешить все (сбросить лок)") { selected = Set(supported) }
                    .foregroundStyle(.secondary).disabled(busy || supported.isEmpty)
            }
        }
        .navigationTitle("Бэнды")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        if app.conn == .demo {
            supported = ["B1", "B3", "B7", "B20", "n78"]
            allowed = ["B3", "n78"]
            selected = Set(allowed)
            return
        }
        guard let info = await app.run({ svc in try await svc.bandsInfo() }) else {
            error = "Не удалось загрузить бэнды. Проверьте подключение и повторите."
            return
        }
        install(info)
    }

    private func install(_ info: RouterService.BandsInfo) {
        supported = info.supported
        allowed = info.allowed
        backend = info.backend
        let current = Set(info.allowed.map(BandsCodec.mmName))
        if current.contains("any") {
            selected = Set(info.supported)
        } else {
            selected = Set(info.supported.filter { current.contains(BandsCodec.mmName($0)) })
        }
    }

    private func apply() async {
        guard !busy, !supported.isEmpty else { return }
        if app.conn == .demo {
            allowed = selected.isEmpty ? supported : supported.filter { selected.contains($0) }
            selected = Set(allowed)
            return
        }
        guard let backend else { return }
        busy = true
        defer { busy = false }
        let chosen = supported.filter { selected.contains($0) }
        let all = supported
        guard let _: Void = await app.run({ svc in
            try await svc.applyBands(chosen, supported: all, backend: backend)
        }) else { return }
        if let info = await app.run({ svc in try await svc.bandsInfo() }) {
            install(info)
            let expected = Set((chosen.isEmpty ? all : chosen).map(BandsCodec.mmName))
            let actual = Set(info.allowed.map(BandsCodec.mmName))
            let matches = actual == expected || (actual.contains("any") && expected == Set(all.map(BandsCodec.mmName)))
            if !matches {
                app.banner = "Команда отправлена, но полученный список бэндов не совпадает с выбранным. Проверьте настройки модема."
            }
        } else {
            app.banner = "Команда отправлена, но не удалось проверить бэнды. Обновите список."
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
                    Label("Написать SMS", systemImage: "square.and.pencil")
                }
            }
            Section("Входящие (\(sms.count))") {
                if loading && sms.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if sms.isEmpty {
                    Text("Пусто").foregroundStyle(.secondary)
                }
                ForEach(sms) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(m.number).font(.subheadline.weight(.semibold))
                            if m.isNew { MmBadge(text: "новое", tone: .info) }
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
                        } label: { Label("Удалить", systemImage: "trash") }
                    }
                }
            }
        }
        .refreshable { await load() }
        .onAppear { if sms.isEmpty { Task { await load() } } }
        .alert("Новое SMS", isPresented: $showSend) {
            TextField("Номер", text: $newNumber)
                .keyboardType(.phonePad)
            TextField("Текст", text: $newText)
            Button("Отправить") { Task { await send() } }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("SMS уйдёт через модем роутера")
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
        newNumber = ""; newText = ""
        await app.run { svc in try await svc.smsSend(number: num, text: txt) }
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
            Section("Запрос") {
                TextField("USSD-код", text: $code)
                    .keyboardType(.numbersAndPunctuation)
                    .font(.system(.body, design: .monospaced))
                Button {
                    Task { await start() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 8) }
                        Text("Отправить").bold()
                        Spacer()
                    }
                }
                .disabled(busy)
            }
            if !status.isEmpty {
                Section("Статус") {
                    Text(status).foregroundStyle(.secondary)
                }
            }
            if !reply.isEmpty {
                Section("Ответ") {
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
        status = "отправляем…"
        if app.conn == .demo {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            status = "готово"
            reply = "На счету 312.45 руб. Демо."
            busy = false
            return
        }
        let r = await app.run { svc in try await svc.ussdRun(code: code) }
        busy = false
        if let r {
            status = "готово"
            reply = r
        } else {
            status = "ошибка — см. баннер"
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
                TextField("AT-команда", text: $cmd)
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
        .navigationTitle("AT-консоль")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() async {
        let c = cmd
        cmd = "AT"
        out.append("→ \(c)")
        busy = true
        if app.conn == .demo {
            out.append(c == "AT+CSQ" ? "+CSQ: 21,99" : "OK (демо)")
            busy = false
            return
        }
        let r = await app.run { svc in try await svc.sendAt(c) }
        busy = false
        out.append(r ?? "(ошибка — см. баннер)")
        if out.count > 300 { out.removeFirst(out.count - 300) }
    }
}
