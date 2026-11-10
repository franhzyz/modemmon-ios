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

    var body: some View {
        List {
            statusSection
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
                Section { ProgressView("Читаем конфиг forkop…").frame(maxWidth: .infinity) }
            }
            logSection
        }
        .navigationTitle("Форкоп")
        .refreshable { await loadAll() }
        .onAppear {
            Task { await loadAll() }
            startLive()
        }
        .onDisappear { liveTask?.cancel() }
    }

    // MARK: Статус

    private var statusSection: some View {
        Section("Статус") {
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
                    Text("Порты: " + s.ports.joined(separator: " · "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    smallAction("Рестарт", .restart)
                    smallAction("Старт", .start)
                    smallAction("Стоп", .stop)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
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
                    Label("Диагностика", systemImage: "stethoscope")
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
                Text("Проверит сервис, конфиг sing-box, Clash API, порты, DNS, прокси-цепочку и свежие ошибки")
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
        Section("Трафик (live)") {
            if let t = traffic {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StatTile(title: "Активные", value: "\(t.active)")
                    StatTile(title: "Скачано", value: Fmt.bytes(t.downTotal))
                    StatTile(title: "Отдано", value: Fmt.bytes(t.upTotal))
                }
            } else {
                Text("Clash API недоступен (sing-box выключен или секрет установлен)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Группы и узлы

    private var groupsSection: some View {
        Section("Группы прокси") {
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
                                        Text(node)
                                            .font(.caption.monospaced())
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
        return Section("Правила (секции)") {
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
                Label("Добавить секцию", systemImage: "plus")
            }
        }
    }

    private func addSection() async {
        await app.run { svc in try await svc.forkopAddSection(label: "Новая секция", lists: []) }
        await loadAll()
    }

    private func toggle(_ id: String, _ on: Bool) async {
        await app.run { svc in try await svc.forkopSet(id, "enabled", on ? "1" : "0") }
        if let c = await app.run({ svc in try await svc.forkopConfig() }) {
            cfg = c
        }
    }

    // MARK: Серверы

    private func serversCard(_ c: UciConfig) -> some View {
        Section("Серверы и клиенты") {
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
        Section("Подписки") {
            ForEach(c.sections.filter { $0.type == "subscription_url" }) { s in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(s.option("tag") ?? s.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        MmBadge(text: (s.option("subscription_update_enabled") ?? "0") == "1" ? "авто" : "вручную", tone: .info)
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
        return Section("Настройки forkop") {
            if let s {
                ForEach(s.options) { o in
                    UciOptionEditor(config: "forkop", section: s.name, option: o) {
                        Task { await loadAll() }
                    }
                }
            } else {
                Text("Секция settings не найдена").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Лог

    private var logSection: some View {
        Section("Лог (forkop / sing-box)") {
            Text(log.isEmpty ? "—" : log)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    // MARK: Логика

    private func loadAll() async {
        if app.conn == .demo { return }
        async let st: RouterService.ForkopStatus? = app.run { svc in try await svc.forkopStatus() }
        async let gr: [RouterService.ClashGroup]? = app.run { svc in try await svc.clashGroups() }
        async let tr: RouterService.ClashTraffic? = app.run { svc in try await svc.clashConnections() }
        async let cf: UciConfig? = app.run { svc in try await svc.forkopConfig() }
        async let lg: String? = app.run { svc in try await svc.forkopLog() }
        status = await st
        groups = await gr ?? []
        traffic = await tr
        cfg = await cf
        log = await lg ?? ""
    }

    private func startLive() {
        liveTask?.cancel()
        liveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                if let t = await app.run({ svc in try await svc.clashConnections() }) {
                    traffic = t
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
        "chatgpt", "claude", "gemini", "openai", "github", "ai", "cloudflare",
        "discord", "facebook", "instagram", "telegram", "tiktok", "youtube",
        "whatsapp", "twitter", "netflix", "spotify", "steam", "rutracker",
    ]

    var body: some View {
        Form {
            Section("Основное") {
                TextField("Название", text: $label)
                Toggle("Включена", isOn: $enabled)
                LabeledContent("Тип", value: section.option("action") ?? "connection")
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
                    TextField("свой список…", text: $customList)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Добавить") {
                        let v = customList.trimmingCharacters(in: .whitespaces)
                        if !v.isEmpty { lists.insert(v); customList = "" }
                    }
                    .disabled(customList.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Списки (community_lists): \(lists.count)")
            } footer: {
                Text("Отмеченные списки будут применены. Галочку можно снять — список уйдёт из секции.")
            }

            Section("Ссылки-подключения (\(links.count))") {
                ForEach(links) { l in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("имя", text: Binding(
                            get: { linkDraftName[l.id] ?? (l.option("name") ?? "") },
                            set: { linkDraftName[l.id] = $0 }
                        ))
                        .font(.subheadline.weight(.medium))
                        TextField("vless://…", text: Binding(
                            get: { linkDraftUri[l.id] ?? (l.option("uri") ?? "") },
                            set: { linkDraftUri[l.id] = $0 }
                        ))
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        HStack {
                            Button("Сохранить") {
                                Task {
                                    await saveLink(l)
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            Spacer()
                            Button(role: .destructive) {
                                Task {
                                    await app.run { svc in try await svc.forkopDeleteLink(id: l.name) }
                                    reload()
                                    dismiss()
                                }
                            } label: {
                                Label("Удалить ссылку", systemImage: "trash")
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
                    Label("Добавить ссылку", systemImage: "plus")
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 8) }
                        Text("Сохранить и применить").bold()
                        Spacer()
                    }
                }
                .disabled(busy || label.isEmpty)
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    HStack { Spacer(); Text("Удалить секцию"); Spacer() }
                }
            } footer: {
                Text("«Сохранить и применить» записывает конфиг и перезапускает forkop — правила подхватятся автоматически.")
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
            Button("Удалить", role: .destructive) {
                Task {
                    await app.run { svc in try await svc.forkopDeleteSection(id: section.name) }
                    reload()
                    dismiss()
                }
            }
            Button("Отмена", role: .cancel) { }
        }
        .alert("Новая ссылка-подключение", isPresented: $showAddLink) {
            TextField("Имя", text: $newLinkName)
            TextField("vless://…", text: $newLinkUri)
            Button("Добавить") {
                Task {
                    await app.run { svc in try await svc.forkopAddLink(section: section.name, name: newLinkName, uri: newLinkUri) }
                    newLinkName = ""; newLinkUri = ""
                    reload()
                }
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("URI целиком: vless://…#имя")
        }
    }

    @State private var linkDraftName: [String: String] = [:]
    @State private var linkDraftUri: [String: String] = [:]

    private func save() async {
        busy = true
        defer { busy = false }
        await app.run { svc in
            try await svc.forkopSaveSection(id: section.name,
                                            label: label,
                                            enabled: enabled,
                                            lists: lists.sorted())
        }
        // применяем: рестарт подхватит новые правила
        await app.run { svc in try await svc.forkopAction(.restart) }
        reload()
        dismiss()
    }

    private func saveLink(_ l: UciSection) async {
        let n = linkDraftName[l.id] ?? (l.option("name") ?? "")
        let u = linkDraftUri[l.id] ?? (l.option("uri") ?? "")
        await app.run { svc in try await svc.forkopSaveLink(id: l.name, name: n.isEmpty ? nil : n, uri: u.isEmpty ? nil : u) }
        reload()
    }
}
