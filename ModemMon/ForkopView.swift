import SwiftUI

// MARK: - Форкоп (sing-box менеджер): статус, трафик, узлы, правила, настройки

struct ForkopView: View {
    @EnvironmentObject var app: AppState
    @State private var status: RouterService.ForkopStatus?
    @State private var groups: [RouterService.ClashGroup] = []
    @State private var traffic: RouterService.ClashTraffic?
    @State private var cfg: UciConfig?
    @State private var log: String = ""
    @State private var switching: String?
    @State private var liveTask: Task<Void, Never>?
    @State private var diag: [RouterService.ForkopCheck]?
    @State private var diagBusy = false
    @State private var dash = DashInfo()
    @State private var prevTotals: (Int64, Int64, Date)?
    @State private var nodeDelays: [String: Int] = [:]
    @State private var testing = false
    @State private var updating = false
    @State private var groupTestStatus: [String: String] = [:]

    struct DashInfo {
        var downBps: Double = 0
        var upBps: Double = 0
        var downTotal: Int64 = 0
        var upTotal: Int64 = 0
        var active: Int = 0
        var cpu: Double?
        var memMB: Double?
        var coreUp: Int?
    }

    var body: some View {
        List {
            statusSection
            dashSection
            diagSection
            trafficSection
            if !groups.isEmpty { groupsSection }
            if let c = cfg {
                sectionsCard(c)
                serversCard(c)
                subscriptionsCard(c)
                urltestCard(c)
                settingsCard(c)
            } else {
                Section { ProgressView(L("Читаем конфиг forkop…", "Reading forkop config…")).frame(maxWidth: .infinity) }
            }
            logSection
        }
        .navigationTitle(L("Форкоп", "Forkop"))
        .refreshable { await loadAll() }
        .onAppear {
            Task { await loadAll() }
            startLive()
        }
        .onDisappear { liveTask?.cancel() }
    }

    // MARK: Статус

    private var statusSection: some View {
        Section(L("Статус", "Status")) {
            if let s = status {
                HStack {
                    MmBadge(text: s.service.isEmpty ? "?" : s.service,
                            tone: s.service.contains("running") ? .ok : .bad)
                    if s.clashAlive {
                        MmBadge(text: "clash api", tone: .info)
                    }
                    Spacer()
                    Text(s.clashVersion.isEmpty ? "sing-box" : s.clashVersion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(s.versions, id: \.self) { v in
                    Text(v).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if !s.ports.isEmpty {
                    Text(L("Порты: ", "Ports: ") + s.ports.joined(separator: " · "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    smallAction(L("Рестарт", "Restart"), .restart)
                    smallAction(L("Старт", "Start"), .start)
                    smallAction(L("Стоп", "Stop"), .stop)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Дашборд

    private var dashSection: some View {
        Section(L("Дашборд", "Dashboard")) {
            if let d = status, d.clashAlive {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StatTile(title: L("Скорость ↓", "Speed ↓"), value: Fmt.kbps(dash.downBps))
                    StatTile(title: L("Скорость ↑", "Speed ↑"), value: Fmt.kbps(dash.upBps))
                    StatTile(title: L("Соединения", "Connections"), value: "\(dash.active)")
                    StatTile(title: L("Всего ↓", "Total ↓"), value: Fmt.bytes(dash.downTotal))
                    StatTile(title: L("Всего ↑", "Total ↑"), value: Fmt.bytes(dash.upTotal))
                    StatTile(title: L("Нагрузка", "Load"), value: dash.cpu.map { String(format: "%.0f%%", $0) } ?? "—",
                             sub: dash.memMB.map { String(format: L("%.1f МБ", "%.1f MB"), $0) })
                }
                if let up = dash.coreUp {
                    Text(L("Ядро работает: \(Fmt.uptime(up))", "Core running: \(Fmt.uptime(up))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        Task { await testAllGroups() }
                    } label: {
                        HStack {
                            if testing { ProgressView().controlSize(.small) }
                            Text(L("Тест всех секций", "Test all sections")).font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(testing)
                    Button {
                        Task { await updateLists() }
                    } label: {
                        HStack {
                            if updating { ProgressView().controlSize(.small) }
                            Text(L("Обновить списки", "Refresh lists")).font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(updating)
                }
                if testing || !groupTestStatus.isEmpty {
                    ForEach(groups) { g in
                        HStack {
                            Text(g.name).font(.caption)
                            Spacer()
                            let st = groupTestStatus[g.name]
                            if testing && st == nil {
                                Text("—").font(.caption).foregroundStyle(.secondary)
                            } else if let st {
                                Text(st)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(st.hasPrefix("ok") ? Color.green : (st == L("тестирую…", "testing…") ? .secondary : .orange))
                            } else if let ms = nodeDelays[g.now] {
                                Text(L("\(ms)мс", "\(ms)ms")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text(L("Дашборд появится, когда sing-box запущен (Clash API :9090)", "The dashboard appears when sing-box is running (Clash API :9090)"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func testAllGroups() async {
        testing = true
        defer { testing = false }
        for g in groups {
            groupTestStatus[g.name] = L("тестирую…", "testing…")
            if let d = await app.run({ svc in try await svc.clashTestGroup(g.name) }) {
                for (k, v) in d { nodeDelays[k] = v }
                let mine = d.filter { g.all.contains($0.key) }
                if let best = mine.values.min(), best > 0 {
                    groupTestStatus[g.name] = L("ok · \(best)мс (из \(mine.count))", "ok · \(best)ms (of \(mine.count))")
                } else if let d2 = nodeDelays[g.now] {
                    groupTestStatus[g.name] = L("ok · \(d2)мс", "ok · \(d2)ms")
                } else {
                    groupTestStatus[g.name] = L("нет ответа", "no response")
                }
            } else {
                groupTestStatus[g.name] = L("ошибка", "error")
            }
        }
        if let nd = await app.run({ svc in try await svc.clashNodeDelays() }) {
            for (k, v) in nd { nodeDelays[k] = v }
        }
        // удерживаем итоги пару секунд
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        groupTestStatus = [:]
    }

    private func updateLists() async {
        updating = true
        defer { updating = false }
        await app.run { svc in try await svc.forkopStateRestart() }
    }

    // MARK: Диагностика

    private var diagSection: some View {
        Section {
            Button {
                Task { await runDiagnostics() }
            } label: {
                HStack {
                    Spacer()
                    if diagBusy { ProgressView().padding(.trailing, 8) }
                    Label(L("Диагностика", "Diagnostics"), systemImage: "stethoscope")
                    Spacer()
                }
            }
            .disabled(diagBusy)
            if let d = diag {
                ForEach(d) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(c.ok ? Color.green : .red)
                            Text(c.name).font(.subheadline)
                            Spacer()
                        }
                        if !c.ok || c.detail.count < 80 {
                            Text(c.detail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                Text(L("Проверит сервис, конфиг sing-box, Clash API, порты, DNS, прокси-цепочку и свежие ошибки", "Checks the service, sing-box config, Clash API, ports, DNS, proxy chain and fresh errors"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runDiagnostics() async {
        diagBusy = true
        defer { diagBusy = false }
        diag = await app.run { svc in try await svc.forkopDiagnostics() }
    }

    @ViewBuilder
    private func smallAction(_ title: String, _ action: RouterService.SvcAction) -> some View {
        Button {
            Task {
                await app.run { svc in try await svc.forkopAction(action) }
                await loadAll()
            }
        } label: {
            Text(title).font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .disabled(action == .stop && (status?.service.contains("running") != true))
    }

    // MARK: Живой трафик (Clash API)

    private var trafficSection: some View {
        Section(L("Трафик (live)", "Traffic (live)")) {
            if let t = traffic {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StatTile(title: L("Активные", "Active"), value: "\(t.active)")
                    StatTile(title: L("Скачано", "Downloaded"), value: Fmt.bytes(t.downTotal))
                    StatTile(title: L("Отдано", "Uploaded"), value: Fmt.bytes(t.upTotal))
                }
            } else {
                Text(L("Clash API недоступен (sing-box выключен или секрет установлен)", "Clash API unavailable (sing-box off or a secret is set)"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Группы и узлы

    private var groupsSection: some View {
        Section(L("Группы прокси", "Proxy groups")) {
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(g.name).font(.subheadline.weight(.semibold))
                        MmBadge(text: g.type, tone: .neutral)
                        Spacer()
                        Text(g.now).font(.caption.monospaced()).foregroundStyle(Color.accentColor)
                    }
                    if switching == g.name {
                        ProgressView().controlSize(.small)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(g.all, id: \.self) { node in
                                    Button {
                                        Task { await select(group: g, node: node) }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(node).font(.caption.monospaced())
                                            if let ms = nodeDelays[node] {
                                                Text(L("\(ms)мс", "\(ms)ms")).font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(node == g.now ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05))
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Правила

    private func sectionsCard(_ c: UciConfig) -> some View {
        let secs = c.sections.filter { $0.type == "section" }
        return Section(L("Правила (секции)", "Rules (sections)")) {
            ForEach(secs) { s in
                NavigationLink {
                    ForkopSectionEditor(section: s, links: c.sections.filter {
                        $0.type == "connection_link" && $0.option("section") == s.name
                    }) {
                        Task { await loadAll() }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(s.option("label") ?? s.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            MmBadge(text: (s.option("enabled") ?? "0") == "1" ? "on" : "off",
                                    tone: (s.option("enabled") ?? "0") == "1" ? .ok : .neutral)
                        }
                        let lists = (s.option("community_lists") ?? "").replacingOccurrences(of: "'", with: "")
                        if !lists.isEmpty {
                            Text(lists).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button {
                Task { await addSection() }
            } label: {
                Label(L("Добавить секцию", "Add section"), systemImage: "plus")
            }
        }
    }

    private func addSection() async {
        await app.run { svc in try await svc.forkopAddSection(label: L("Новая секция", "New section"), lists: []) }
        await loadAll()
    }

    // MARK: Серверы

    private func serversCard(_ c: UciConfig) -> some View {
        Section(L("Серверы и клиенты", "Servers and clients")) {
            ForEach(c.sections.filter { $0.type == "server" }) { s in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(s.option("label") ?? s.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        MmBadge(text: (s.option("enabled") ?? "0") == "1" ? "on" : "off",
                                tone: (s.option("enabled") ?? "0") == "1" ? .ok : .neutral)
                    }
                    Text("\(s.option("protocol") ?? "?") \(s.option("listen") ?? ""):\(s.option("listen_port") ?? "") · routing: \(s.option("routing_mode") ?? "?")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                ForEach(c.sections.filter { $0.type == "server_client" && $0.option("server") == s.name }) { cl in
                    HStack {
                        Image(systemName: "person").font(.caption).foregroundStyle(.secondary)
                        Text(cl.option("name") ?? "?").font(.caption)
                        Spacer()
                        Text(maskSecret(cl.option("password") ?? ""))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: Подписки

    private func subscriptionsCard(_ c: UciConfig) -> some View {
        Section(L("Подписки", "Subscriptions")) {
            ForEach(c.sections.filter { $0.type == "subscription_url" }) { s in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(s.option("tag") ?? s.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        MmBadge(text: (s.option("subscription_update_enabled") ?? "0") == "1" ? L("авто", "auto") : L("вручную", "manual"), tone: .info)
                    }
                    Text(maskUrl(s.option("url") ?? ""))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("интервал: \(s.option("subscription_update_interval") ?? "—")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: URLTest

    private func urltestCard(_ c: UciConfig) -> some View {
        let groups = c.sections.filter { $0.type == "urltest" }
        return Section("URLTest") {
            if groups.isEmpty { Text("—").foregroundStyle(.secondary) }
            ForEach(groups) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.option("name") ?? s.name).font(.subheadline.weight(.medium))
                    Text("каждые \(s.option("check_interval") ?? "—") · tolerance \(s.option("tolerance") ?? "—")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Настройки

    private func settingsCard(_ c: UciConfig) -> some View {
        let s = c.sections.first { $0.type == "settings" }
        return Section(L("Настройки forkop", "Forkop settings")) {
            if let s {
                ForEach(s.options) { o in
                    UciOptionEditor(config: "forkop", section: s.name, option: o) {
                        Task { await loadAll() }
                    }
                }
            } else {
                Text(L("Секция settings не найдена", "Section settings not found")).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Лог

    private var logSection: some View {
        Section(L("Лог (forkop / sing-box)", "Log (forkop / sing-box)")) {
            Text(log.isEmpty ? "—" : log)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    // MARK: Логика

    private func loadAll() async {
        if app.conn == .demo { return }
        async let st: RouterService.ForkopStatus? = app.run { svc in try await svc.forkopStatus() }
        async let gr: [RouterService.ClashGroup]? = optionalGroups()
        async let tr: RouterService.ClashTraffic? = optionalTraffic()
        async let nd: [String: Int]? = optionalDelays()
        async let cf: UciConfig? = app.run { svc in try await svc.forkopConfig() }
        async let lg: String? = app.run { svc in try await svc.forkopLog() }
        status = await st
        groups = await gr ?? []
        traffic = await tr
        let delays = await nd
        if let delays {
            for (key, value) in delays { nodeDelays[key] = value }
        }
        cfg = await cf
        log = await lg ?? ""
    }

    // Clash API может быть выключен или доступен только локально на роутере.
    // Фоновые опросы не должны перекрывать сообщения об ошибке сохранения.
    private func optionalGroups() async -> [RouterService.ClashGroup]? {
        guard let svc = app.service else { return nil }
        return try? await svc.clashGroups()
    }
    private func optionalTraffic() async -> RouterService.ClashTraffic? {
        guard let svc = app.service else { return nil }
        return try? await svc.clashConnections()
    }
    private func optionalDelays() async -> [String: Int]? {
        guard let svc = app.service else { return nil }
        return try? await svc.clashNodeDelays()
    }

    private func optionalCoreStats() async -> RouterService.ForkopCoreStats? {
        guard let svc = app.service else { return nil }
        return try? await svc.forkopCoreStats()
    }

    private func startLive() {
        liveTask?.cancel()
        liveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                if let t = await optionalTraffic() {
                    if let prev = prevTotals {
                        let dt = max(0.5, Date().timeIntervalSince(prev.2))
                        dash.downBps = max(0, Double(t.downTotal - prev.0) / dt)
                        dash.upBps = max(0, Double(t.upTotal - prev.1) / dt)
                    }
                    prevTotals = (t.downTotal, t.upTotal, Date())
                    dash.downTotal = t.downTotal
                    dash.upTotal = t.upTotal
                    dash.active = t.active
                }
                if let cs = await optionalCoreStats() {
                    dash.cpu = cs.cpuPercent
                    dash.memMB = cs.memMB
                    dash.coreUp = cs.uptimeSec
                }
            }
        }
    }

    private func select(group: RouterService.ClashGroup, node: String) async {
        guard node != group.now else { return }
        switching = group.name
        defer { switching = nil }
        await app.run { svc in try await svc.clashSelect(group: group.name, node: node) }
        if let gr = await app.run({ svc in try await svc.clashGroups() }) {
            groups = gr
        }
    }

    private func toggle(_ id: String, _ on: Bool) async {
        await app.run { svc in try await svc.forkopSet(id, "enabled", on ? "1" : "0") }
        if let c = await app.run({ svc in try await svc.forkopConfig() }) {
            cfg = c
        }
    }

    private func maskSecret(_ s: String) -> String {
        guard s.count > 8 else { return "••••" }
        return "••••" + String(s.suffix(4))
    }

    private func maskUrl(_ u: String) -> String {
        guard let r = u.range(of: "://") else { return u }
        let rest = u[r.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return u }
        let host = rest[..<slash]
        return String(host) + "/••••••••"
    }
}

// MARK: - Редактор секции forkop

struct ForkopSectionEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let section: UciSection
    let links: [UciSection]
    var reload: () -> Void

    @State private var label: String = ""
    @State private var enabled = true
    @State private var lists: Set<String> = []
    @State private var customList = ""
    @State private var busy = false
    @State private var confirmDelete = false
    @State private var showAddLink = false
    @State private var newLinkName = ""
    @State private var newLinkUri = ""

    static let knownLists = [
        "ai", "chatgpt", "claude", "cloudflare", "gemini", "github",
        "discord", "facebook", "instagram", "telegram", "tiktok", "youtube", "whatsapp",
    ]

    var body: some View {
        Form {
            Section(L("Основное", "Main")) {
                TextField(L("Название", "Name"), text: $label)
                Toggle(L("Включена", "Enabled"), isOn: $enabled)
                LabeledContent(L("Тип", "Type"), value: section.option("action") ?? "connection")
            }

            Section {
                ForEach(Self.knownLists, id: \.self) { l in
                    Button {
                        if lists.contains(l) { lists.remove(l) } else { lists.insert(l) }
                    } label: {
                        HStack {
                            Text(l).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: lists.contains(l) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(lists.contains(l) ? Color.accentColor : .secondary)
                        }
                    }
                }
                HStack {
                    TextField(L("свой список…", "own list…"), text: $customList)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(L("Добавить", "Add")) {
                        let v = customList.trimmingCharacters(in: .whitespaces)
                        if !v.isEmpty { lists.insert(v); customList = "" }
                    }
                    .disabled(customList.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text(L("Списки (community_lists): \(lists.count)", "Lists (community_lists): \(lists.count)"))
            } footer: {
                Text(L("Отмеченные списки будут применены. Галочку можно снять — список уйдёт из секции.", "Checked lists will be applied. Untick a checkbox and the list leaves the section."))
            }

            Section(L("Ссылки-подключения (\(links.count))", "Connection links (\(links.count))")) {
                ForEach(links) { l in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L("имя", "name"), text: linkNameBinding(l))
                            .font(.subheadline.weight(.medium))
                        TextField("vless://…", text: linkUriBinding(l))
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        HStack {
                            Button(L("Сохранить", "Save")) {
                                Task {
                                    await saveLink(l)
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            Spacer()
                            Button(role: .destructive) {
                                Task {
                                    guard let _: Void = await app.run({ svc in try await svc.forkopDeleteLink(id: l.name) }) else { return }
                                    reload()
                                    dismiss()
                                }
                            } label: {
                                Label(L("Удалить ссылку", "Delete link"), systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button {
                    showAddLink = true
                } label: {
                    Label(L("Добавить ссылку", "Add link"), systemImage: "plus")
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 8) }
                        Text(L("Сохранить и применить", "Save and apply")).bold()
                        Spacer()
                    }
                }
                .disabled(busy || label.isEmpty)
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    HStack { Spacer(); Text(L("Удалить секцию", "Delete section")); Spacer() }
                }
            } footer: {
                Text(L("«Сохранить и применить» записывает конфиг и перезапускает forkop — правила подхватятся автоматически.", "“Save and apply” writes the config and restarts forkop — rules are picked up automatically."))
            }
        }
        .navigationTitle(section.option("label") ?? section.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            label = section.option("label") ?? ""
            enabled = (section.option("enabled") ?? "0") == "1"
            let raw = (section.option("community_lists") ?? "").replacingOccurrences(of: "'", with: "")
            lists = Set(raw.split(separator: " ").map(String.init).filter { !$0.isEmpty })
        }
        .alert("Удалить секцию \(section.option("label") ?? section.name)?", isPresented: $confirmDelete) {
            Button(L("Удалить", "Delete"), role: .destructive) {
                Task {
                    guard let _: Void = await app.run({ svc in try await svc.forkopDeleteSection(id: section.name) }) else { return }
                    reload()
                    dismiss()
                }
            }
            Button(L("Отмена", "Cancel"), role: .cancel) { }
        }
        .alert(L("Новая ссылка-подключение", "New connection link"), isPresented: $showAddLink) {
            TextField(L("Имя", "Name"), text: $newLinkName)
            TextField("vless://…", text: $newLinkUri)
            Button(L("Добавить", "Add")) {
                Task {
                    guard let _: Void = await app.run({ svc in try await svc.forkopAddLink(section: section.name, name: newLinkName, uri: newLinkUri) }) else { return }
                    newLinkName = ""; newLinkUri = ""
                    reload()
                }
            }
            Button(L("Отмена", "Cancel"), role: .cancel) { }
        } message: {
            Text(L("URI целиком: vless://…#имя", "Full URI: vless://…#name"))
        }
    }

    @State private var linkDraftName: [String: String] = [:]
    @State private var linkDraftUri: [String: String] = [:]

    private func linkNameBinding(_ l: UciSection) -> Binding<String> {
        Binding(get: { linkDraftName[l.name] ?? (l.option("name") ?? "") },
                set: { linkDraftName[l.name] = $0 })
    }

    private func linkUriBinding(_ l: UciSection) -> Binding<String> {
        Binding(get: { linkDraftUri[l.name] ?? (l.option("uri") ?? "") },
                set: { linkDraftUri[l.name] = $0 })
    }

    private func save() async {
        busy = true
        defer { busy = false }
        guard let _: Void = await app.run({ svc in
            try await svc.forkopSaveSection(id: section.name,
                                            label: label,
                                            enabled: enabled,
                                            lists: lists.sorted())
        }) else { return }
        // Ошибка рестарта не означает, что запись не состоялась.
        guard let _: Void = await app.run({ svc in try await svc.forkopAction(.restart) }) else {
            let detail = app.banner ?? L("Проверьте службу и лог.", "Check the service and the log.")
            app.banner = L("Настройки сохранены, но перезапустить Форкоп не удалось: \(detail)", "Settings saved, but Forkop restart failed: \(detail)")
            return
        }
        reload()
        dismiss()
    }

    private func saveLink(_ l: UciSection) async {
        let n = linkDraftName[l.name] ?? (l.option("name") ?? "")
        let u = linkDraftUri[l.name] ?? (l.option("uri") ?? "")
        guard let _: Void = await app.run({ svc in try await svc.forkopSaveLink(id: l.name, name: n.isEmpty ? nil : n, uri: u.isEmpty ? nil : u) }) else { return }
        reload()
    }
}
