import SwiftUI

// MARK: - Терминал (TermScreen)

struct TerminalView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var term: TerminalSession
    @State private var cmd = ""
    @State private var showEditor = false
    @Environment(\.dismiss) private var dismiss

    init() {
        // StateObject из environment не получить в init — терминал живёт своей жизнью,
        // AppState подтянем позже через onAppear.
        _term = StateObject(wrappedValue: TerminalSession(app: nil))
    }

    var body: some View {
        VStack(spacing: 0) {
            if term.installed == false {
                Button {
                    Task { await term.install() }
                } label: {
                    HStack {
                        Spacer()
                        Label("Установить mmterm на роутер", systemImage: "square.and.arrow.down")
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(10)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(term.lines) { l in
                            Text((l.isCmd ? "" : "  ") + l.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(l.isCmd ? Color.cyan : Color.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        if term.busy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("выполняется · cwd \(term.cwd)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: term.lines.count) { _ in
                    if let last = term.lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(Color.black.opacity(0.85))
            .foregroundStyle(.green)
            Divider()
            HStack(spacing: 8) {
                TextField("команда (cwd: \(term.cwd))", text: $cmd)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit { Task { await run() } }
                if term.busy {
                    Button {
                        Task { await term.stopCurrent() }
                    } label: { Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(.red) }
                } else {
                    Button {
                        Task { await run() }
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(cmd.isEmpty)
                }
                Menu {
                    Button {
                        showEditor = true
                    } label: { Label("Редактор файлов", systemImage: "pencil.and.outline") }
                    Button(role: .destructive) {
                        term.clear()
                    } label: { Label("Очистить вывод", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
            .padding(10)
        }
        .navigationTitle("Терминал")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            term.bind(app)
            if term.installed == nil { Task { await term.checkInstalled() } }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack { FileEditorView() }
        }
    }

    private func run() async {
        let c = cmd
        cmd = ""
        await term.run(c)
    }
}

// MARK: - Редактор файла (FileEditor из TermScreenKt)

struct FileEditorView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var path = "/etc/config/medvemodem"
    @State private var text = ""
    @State private var loadedPath = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("Путь") {
                TextField("/etc/...", text: $path)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await load() }
                } label: { Label("Открыть", systemImage: "doc.text.magnifyingglass") }
            }
            Section("Содержимое \(loadedPath.isEmpty ? "" : "(\(loadedPath))")") {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 300)
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack { Spacer(); if busy { ProgressView().padding(.trailing, 8) }; Text("Сохранить (с .bak-копией)").bold(); Spacer() }
                }
                .disabled(busy || loadedPath.isEmpty)
            } footer: {
                Text("Перед записью на роутере создаётся резервная копия: <файл>.bak-<timestamp>.")
            }
        }
        .navigationTitle("Редактор файла")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
        }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        if app.conn == .demo {
            text = "# demo\nconfig modem 'main'\n\toption device '/dev/cdc-wdm0'\n"
            loadedPath = path
            return
        }
        let p = path
        let content = await app.run { svc in try await svc.readFile(p) }
        if let content { text = content; loadedPath = path }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let p = loadedPath, t = text
        await app.run { svc in try await svc.writeFile(p, t) }
    }
}

// MARK: - Файлы (браузер по файловой системе роутера)

struct FilesView: View {
    @EnvironmentObject var app: AppState
    @State private var entries: [FileEntry] = []
    @State private var path = "/"
    @State private var loading = false

    var body: some View {
        List {
            Section(path) {
                if loading && entries.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                if path != "/" {
                    Button {
                        path = (path as NSString).deletingLastPathComponent
                        if path.isEmpty { path = "/" }
                        Task { await load() }
                    } label: {
                        Label("..", systemImage: "arrowshape.turn.up.left")
                    }
                }
                ForEach(entries) { e in
                    Button {
                        if e.isDir {
                            path = path.hasSuffix("/") ? path + e.name : path + "/" + e.name
                            Task { await load() }
                        } else {
                            openFile = e
                            showEditor = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: e.isDir ? "folder.fill" : "doc")
                                .foregroundStyle(e.isDir ? Color.accentColor : .secondary)
                            Text(e.name).font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer()
                            if !e.isDir { Text(Fmt.bytes(e.size)).font(.caption2).foregroundStyle(.secondary) }
                            if let m = e.mtime { Text(Fmt.time(m)).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                if !loading && entries.isEmpty && path != "/" {
                    Text("Пусто или нет прав").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Файлы")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .onAppear { if entries.isEmpty { Task { await load() } } }
        .sheet(isPresented: $showEditor) {
            if let f = openFile {
                NavigationStack {
                    QuickFileEditor(path: join(path, f.name))
                }
            }
        }
    }

    @State private var openFile: FileEntry?
    @State private var showEditor = false

    private func join(_ a: String, _ b: String) -> String {
        a.hasSuffix("/") ? a + b : a + "/" + b
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if app.conn == .demo {
            entries = [FileEntry(name: "etc", size: nil, isDir: true, mode: "drwxr-xr-x", mtime: Date()),
                       FileEntry(name: "tmp", size: nil, isDir: true, mode: "drwxrwxrwt", mtime: Date())]
            return
        }
        let p = path
        entries = await app.run { svc in try await svc.listDir(p) } ?? []
        entries.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name < b.name
        }
    }
}

struct QuickFileEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State private var text = ""
    @State private var loaded = false
    @State private var busy = false

    var body: some View {
        Form {
            Section(path) {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 320)
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack { Spacer(); if busy { ProgressView().padding(.trailing, 8) }; Text("Сохранить (с .bak-копией)"); Spacer() }
                }
                .disabled(busy || !loaded)
            }
        }
        .navigationTitle("Файл")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
        }
        .onAppear { if !loaded { Task { await load() } } }
    }

    private func load() async {
        if app.conn == .demo { text = "# demo file"; loaded = true; return }
        let content = await app.run { svc in try await svc.readFile(path) }
        if let content { text = content; loaded = true }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let t = text
        await app.run { svc in try await svc.writeFile(path, t) }
    }
}

// MARK: - Wake-on-LAN (WolScreen)

struct WolView: View {
    @EnvironmentObject var app: AppState
    @State private var targets: [WolTarget] = []
    @State private var available: Bool?
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newMac = ""
    @State private var newIface = "br-lan"

    var body: some View {
        List {
            if let a = available, !a {
                Section {
                    Button {
                        Task { await install() }
                    } label: {
                        Label("Установить etherwake на роутер", systemImage: "square.and.arrow.down")
                    }
                }
            }
            Section("Цели") {
                if targets.isEmpty { Text("Добавь компьютер по MAC-адресу").foregroundStyle(.secondary) }
                ForEach(targets) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.subheadline.weight(.medium))
                            Text("\(t.mac) · \(t.iface)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await send(t) }
                        } label: {
                            Image(systemName: "bolt.circle.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            targets.removeAll { $0.id == t.id }
                            saveTargets()
                        } label: { Label("Удалить", systemImage: "trash") }
                    }
                }
            }
            Section {
                Button {
                    showAdd = true
                } label: { Label("Добавить цель", systemImage: "plus") }
            } footer: {
                Text("Цели хранятся на iPhone. MAC-адрес вида AA:BB:CC:DD:EE:FF. Интерфейс — обычно br-lan.")
            }
        }
        .navigationTitle("Wake-on-LAN")
        .onAppear {
            targets = loadTargets()
            if available == nil { Task { await check() } }
        }
        .alert("Новая цель", isPresented: $showAdd) {
            TextField("Имя", text: $newName)
            TextField("MAC", text: $newMac)
                .textInputAutocapitalization(.characters)
            TextField("Интерфейс", text: $newIface)
                .textInputAutocapitalization(.never)
            Button("Добавить") {
                let t = WolTarget(name: newName.isEmpty ? "ПК" : newName, mac: newMac.uppercased(), iface: newIface)
                targets.append(t)
                saveTargets()
                newName = ""; newMac = ""
            }
            Button("Отмена", role: .cancel) { }
        }
    }

    private func loadTargets() -> [WolTarget] {
        guard let d = UserDefaults.standard.data(forKey: "mm.wolTargets"),
              let t = try? JSONDecoder().decode([WolTarget].self, from: d) else { return [] }
        return t
    }

    private func saveTargets() {
        if let d = try? JSONEncoder().encode(targets) { UserDefaults.standard.set(d, forKey: "mm.wolTargets") }
    }

    private func check() async {
        if app.conn == .demo { available = true; return }
        available = await app.service?.wolAvailable() ?? false
    }

    private func install() async {
        await app.run { svc in try await svc.wolInstall() }
        await check()
    }

    private func send(_ t: WolTarget) async {
        if app.conn == .demo {
            app.banner = nil
            return
        }
        await app.run { svc in try await svc.wolSend(mac: t.mac, iface: t.iface) }
    }
}

// MARK: - Диагностика (PingCard + UplinkBanner)

struct DiagnosticsView: View {
    @EnvironmentObject var app: AppState
    @State private var host = "8.8.8.8"
    @State private var pingOut = ""
    @State private var busy = false

    var body: some View {
        List {
            Section("Аплинк") {
                HStack {
                    switch app.uplink.st {
                    case .ok: MmBadge(text: "OK · \(app.uplink.path)", tone: .ok)
                    case .fail: MmBadge(text: "FAIL", tone: .bad)
                    case .checking: MmBadge(text: "…", tone: .info)
                    case .unknown: MmBadge(text: "?", tone: .neutral)
                    }
                    Spacer()
                    Text(app.uplink.detail).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(["wwan0", "eth1", "br-lan"], id: \.self) { f in
                    Button {
                        Task { await probe(f) }
                    } label: {
                        HStack {
                            Text("curl 204 через \(f)")
                            Spacer()
                            Image(systemName: "play")
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section("Ping с роутера") {
                TextField("хост", text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await ping() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 8) }
                        Text("ping -c 4 \(host)")
                        Spacer()
                    }
                }
                .disabled(busy || host.isEmpty)
                if !pingOut.isEmpty {
                    Text(pingOut)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Диагностика")
    }

    private func probe(_ iface: String) async {
        app.uplink.st = .checking
        if app.conn == .demo {
            app.uplink = UplinkState(st: .ok, latencyMs: 41, path: iface, checkedAt: Date(), detail: "demo")
            return
        }
        if let probe = await app.run({ svc in try await svc.uplinkProbe(iface: iface) }) {
            app.uplink = UplinkState(st: probe.ok ? .ok : .fail,
                                     latencyMs: probe.seconds.map { $0 * 1000 },
                                     path: iface,
                                     checkedAt: Date(),
                                     detail: "HTTP \(probe.httpCode ?? 0)")
        }
    }

    private func ping() async {
        busy = true
        defer { busy = false }
        if app.conn == .demo {
            pingOut = "PING 8.8.8.8: 56 data bytes\n64 bytes from 8.8.8.8: seq=0 ttl=57 time=41.2 ms (демо)"
            return
        }
        let h = host
        pingOut = await app.run { svc in try await svc.ping(host: h) } ?? ""
    }
}

// MARK: - LuCI и телеметрия

struct LinksView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        List {
            Section {
                if let p = app.activeProfile {
                    Link(destination: URL(string: "\(p.scheme)://\(p.host)\(p.port == 80 || p.port == 443 ? "" : ":\(p.port)")/cgi-bin/luci/admin")!) {
                        Label("LuCI — веб-интерфейс роутера", systemImage: "safari")
                    }
                    Link(destination: URL(string: "\(p.scheme)://\(p.host)\(p.port == 80 || p.port == 443 ? "" : ":\(p.port)")/cgi-bin/modem-telemetry")!) {
                        Label("Телеметрия модема", systemImage: "chart.line.uptrend.xyaxis")
                    }
                }
            } header: {
                Text("Открыть в Safari")
            } footer: {
                Text("LuCI сначала покажет страницу входа: логин root, пароль роутера — после входа откроется интерфейс. Страницы открываются, когда iPhone в сети роутера.")
            }
        }
        .navigationTitle("LuCI и телеметрия")
    }
}

// MARK: - Настройка меню (MenuConfigScreen)

struct MenuConfigView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        List {
            ForEach(AppState.sections) { s in
                Button {
                    app.toggleMenu(s.key)
                } label: {
                    HStack {
                        Image(systemName: s.icon)
                            .frame(width: 26)
                            .foregroundStyle(Color.accentColor)
                        Text(s.title).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: app.settings.hiddenMenu.contains(s.key) ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(app.settings.hiddenMenu.contains(s.key) ? .secondary : Color.accentColor)
                    }
                }
            }
        }
        .navigationTitle("Настройка меню")
    }
}

// MARK: - Настройки (SettingsScreen)

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            Section("Опрос") {
                Picker("Интервал опроса", selection: intervalBinding) {
                    Text("1 с").tag(1.0)
                    Text("2 с").tag(2.0)
                    Text("5 с").tag(5.0)
                    Text("10 с").tag(10.0)
                }
            }
            Section {
                Toggle("Безопасный режим", isOn: $app.settings.safeMode)
            } header: {
                Text("Безопасность")
            } footer: {
                Text("Блокирует опасные shell-команды (reboot, sysupgrade, rm -rf / и т.п.), если они встречаются в редактируемых полях.")
            }
            Section("О приложении") {
                LabeledContent("Версия", value: "1.0 (iOS)")
                LabeledContent("Прототип", value: "ModemMon 2.6 (Android)")
                LabeledContent("Подключение", value: "ubus JSON-RPC + medvemodem CGI")
            }
        }
        .navigationTitle("Настройки")
    }

    private var intervalBinding: Binding<Double> {
        Binding(get: { app.settings.pollInterval }, set: { v in
            app.settings.pollInterval = v
            app.startPolling()
        })
    }
}
