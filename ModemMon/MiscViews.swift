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
                        Label(L("Установить mmterm на роутер", "Install mmterm on the router"), systemImage: "square.and.arrow.down")
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
                                Text(L("выполняется · cwd \(term.cwd)", "running · cwd \(term.cwd)"))
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
                TextField(L("команда (cwd: \(term.cwd))", "command (cwd: \(term.cwd))"), text: $cmd)
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
                    } label: { Label(L("Редактор файлов", "File editor"), systemImage: "pencil.and.outline") }
                    Button(role: .destructive) {
                        term.clear()
                    } label: { Label(L("Очистить вывод", "Clear output"), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
            .padding(10)
        }
        .navigationTitle(L("Терминал", "Terminal"))
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
            Section(L("Путь", "Path")) {
                TextField("/etc/...", text: $path)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await load() }
                } label: { Label(L("Открыть", "Open"), systemImage: "doc.text.magnifyingglass") }
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
                    HStack { Spacer(); if busy { ProgressView().padding(.trailing, 8) }; Text(L("Сохранить (с .bak-копией)", "Save (with .bak copy)")).bold(); Spacer() }
                }
                .disabled(busy || loadedPath.isEmpty)
            } footer: {
                Text(L("Перед записью на роутере создаётся резервная копия: <файл>.bak-<timestamp>.", "Before writing, a backup is created on the router: <file>.bak-<timestamp>."))
            }
        }
        .navigationTitle(L("Редактор файла", "File editor"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("Закрыть", "Close")) { dismiss() } }
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
                    Text(L("Пусто или нет прав", "Empty or no permission")).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(L("Файлы", "Files"))
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
                    HStack { Spacer(); if busy { ProgressView().padding(.trailing, 8) }; Text(L("Сохранить (с .bak-копией)", "Save (with .bak copy)")); Spacer() }
                }
                .disabled(busy || !loaded)
            }
        }
        .navigationTitle(L("Файл", "File"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L("Закрыть", "Close")) { dismiss() } }
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
                        Label(L("Установить etherwake на роутер", "Install etherwake on the router"), systemImage: "square.and.arrow.down")
                    }
                }
            }
            Section(L("Цели", "Targets")) {
                if targets.isEmpty { Text(L("Добавь компьютер по MAC-адресу", "Add a computer by MAC address")).foregroundStyle(.secondary) }
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
                        } label: { Label(L("Удалить", "Delete"), systemImage: "trash") }
                    }
                }
            }
            Section {
                Button {
                    showAdd = true
                } label: { Label(L("Добавить цель", "Add target"), systemImage: "plus") }
            } footer: {
                Text(L("Цели хранятся на iPhone. MAC-адрес вида AA:BB:CC:DD:EE:FF. Интерфейс — обычно br-lan.", "Targets are stored on the iPhone. MAC like AA:BB:CC:DD:EE:FF. Interface is usually br-lan."))
            }
        }
        .navigationTitle("Wake-on-LAN")
        .onAppear {
            targets = loadTargets()
            if available == nil { Task { await check() } }
        }
        .alert(L("Новая цель", "New target"), isPresented: $showAdd) {
            TextField(L("Имя", "Name"), text: $newName)
            TextField("MAC", text: $newMac)
                .textInputAutocapitalization(.characters)
            TextField(L("Интерфейс", "Interface"), text: $newIface)
                .textInputAutocapitalization(.never)
            Button(L("Добавить", "Add")) {
                let t = WolTarget(name: newName.isEmpty ? L("ПК", "PC") : newName, mac: newMac.uppercased(), iface: newIface)
                targets.append(t)
                saveTargets()
                newName = ""; newMac = ""
            }
            Button(L("Отмена", "Cancel"), role: .cancel) { }
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
    @State private var speedIface = ""
    @State private var speedBusy = false
    @State private var speedPhase = ""
    @State private var speedDown: Double?
    @State private var speedUp: Double?
    @State private var speedPing: Double?
    @State private var speedIfaces: [String] = []
    @State private var speedError: String?

    var body: some View {
        List {
            Section(L("Аплинк", "Uplink")) {
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
                            Text(L("curl 204 через \(f)", "curl 204 via \(f)"))
                            Spacer()
                            Image(systemName: "play")
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section(L("Спидтест (Яндекс)", "Speed test (Yandex)")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach([""] + speedIfaces, id: \.self) { f in
                        Button {
                            speedIface = f
                        } label: {
                            Text(f.isEmpty ? L("Авто", "Auto") : Self.ifaceLabel(f))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(speedIface == f ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    Task { await runSpeedTest() }
                } label: {
                    HStack {
                        if speedBusy { ProgressView().padding(.trailing, 6) }
                        Image(systemName: "speedometer")
                        Text(speedBusy ? speedPhase : L("Запустить спидтест", "Run speed test"))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(speedBusy)
                if speedDown != nil || speedUp != nil || speedPing != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("↓ \(speedDown.map { String(format: "%.1f", $0) } ?? "—") Мбит/с")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.green)
                        Text("↑ \(speedUp.map { String(format: "%.1f", $0) } ?? "—") Мбит/с")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.green)
                        if let p = speedPing {
                            Text("Пинг \(String(format: "%.0f", p)) мс")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }
                }
                if let e = speedError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
            }
            .task {
                guard speedIfaces.isEmpty, app.service != nil else { return }
                let out = (try? await app.service?.execText(
                    "ip -o link show | awk -F': ' '{print $2}' | grep -E '^(pppoe|wwan|usb|qmi|wan)' | grep -v '@'; exit 0"
                )) ?? ""
                let names = out
                    .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                var seen = Set<String>()
                speedIfaces = Array(names.filter { seen.insert($0).inserted }.prefix(4))
            }
            Section(L("Ping с роутера", "Ping from the router")) {
                TextField(L("хост", "host"), text: $host)
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
        .navigationTitle(L("Диагностика", "Diagnostics"))
    }

    private static func ifaceLabel(_ n: String) -> String {
        if n.hasPrefix("wwan") || n.hasPrefix("qmi") { return L("Модем (\(n))", "Modem (\(n))") }
        if n.hasPrefix("usb") || n.hasPrefix("pppoe") || n.contains("wan") { return L("Кабель (\(n))", "Cable (\(n))") }
        return n
    }

    /// Спидтест Яндекс.Интернетометра: замер в фоне на роутере,
    /// приложение опрашивает /tmp/mm_speed_* раз в 2 с (короткие вызовы).
    private func runSpeedTest() async {
        guard let svc = app.service else { return }
        speedBusy = true
        defer { speedBusy = false }
        speedDown = nil; speedUp = nil; speedPing = nil; speedError = nil
        speedPhase = L("Запуск…", "Starting…")
        let safe = speedIface.filter { "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".contains($0) }
        let bind = safe.isEmpty ? "" : "--interface \(safe) "
        let script =
            "rm -f /tmp/mm_speed_phase /tmp/mm_speed_result; { " +
            "echo down > /tmp/mm_speed_phase; " +
            "j=\"$(curl -s -m 8 -H 'Referer: https://yandex.ru/internet/' " +
            "\"https://yandex.ru/internet/api/v0/get-probes?t=$(date +%s000)\")\"; " +
            "durl=\"$(echo \"$j\" | grep -o 'https://[^\"]*probes/50mb[^\"]*' | head -1)\"; " +
            "uurl=\"$(echo \"$j\" | grep -o 'https://[^\"]*upload[^\"]*' | head -1)\"; " +
            "purl=\"$(echo \"$j\" | grep -o 'https://[^\"]*/ping[^\"]*' | head -1)\"; " +
            "if [ -z \"$durl\" ]; then echo err > /tmp/mm_speed_result; exit 0; fi; " +
            // res(): настоящий IPv4 — nslookup, при неудаче DoH 1.1.1.1 (DNS на роутере бывает нестабилен)
            "res() { r=\"$(nslookup \"$1\" 77.88.8.8 2>/dev/null | awk '/Address/{print $NF}' | " +
            "grep -E '^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$' | head -1)\"; " +
            "[ -n \"$r\" ] && { echo \"$r\"; return; }; " +
            "r=\"$(curl -s -m 6 \"https://1.1.1.1/dns-query?name=$1&type=A\" -H 'accept: application/dns-json' | " +
            "grep -o '\"data\":\"[0-9.]*\"' | head -1 | cut -d'\"' -f4)\"; " +
            "[ -n \"$r\" ] && { echo \"$r\"; return; }; }; " +
            "dhost=\"$(echo \"$durl\" | sed -e 's|https://||' -e 's|/.*||')\"; " +
            "uhost=\"$(echo \"$uurl\" | sed -e 's|https://||' -e 's|/.*||')\"; " +
            "phost=\"$(echo \"$purl\" | sed -e 's|https://||' -e 's|/.*||')\"; " +
            "dip=\"$(res \"$dhost\")\"; uip=\"$(res \"$uhost\")\"; pip=\"$(res \"$phost\")\"; " +
            // --resolve только если IP получен; иначе обычный путь (fake-ip через Clash)
            "dargs=\"\"; [ -n \"$dip\" ] && dargs=\"--resolve $dhost:443:$dip\"; " +
            "uargs=\"\"; [ -n \"$uip\" ] && uargs=\"--resolve $uhost:443:$uip\"; " +
            "pargs=\"\"; [ -n \"$pip\" ] && pargs=\"--resolve $phost:443:$pip\"; " +
            "d=\"$(curl -s -o /dev/null --max-time 10 \(bind)$dargs " +
            "-w '%{speed_download}' \"$durl&rid=mm$(date +%s)\" 2>/dev/null)\"; " +
            "echo up > /tmp/mm_speed_phase; " +
            "head -c 10485760 /dev/zero > /tmp/mm_up.bin 2>/dev/null; " +
            "u=\"$(curl -s -o /dev/null --max-time 15 \(bind)$uargs " +
            "-X POST -H 'Content-Type: application/octet-stream' " +
            "--data-binary @/tmp/mm_up.bin -w '%{speed_upload}' \"$uurl&rid=mm$(date +%s)\" 2>/dev/null)\"; " +
            "rm -f /tmp/mm_up.bin; echo ping > /tmp/mm_speed_phase; " +
            "p=\"$(curl -s -o /dev/null -m 3 \(bind)$pargs " +
            "-w '%{time_starttransfer}' \"$purl&rid=mm1\" 2>/dev/null)\"; " +
            "echo \"$d $u $p\" > /tmp/mm_speed_result; " +
            "} >/dev/null 2>&1 </dev/null & echo started"
        do {
            _ = try await svc.execText(script)
            for _ in 0..<25 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let out = (try? await svc.execText(
                    "cat /tmp/mm_speed_phase 2>/dev/null; echo ---; cat /tmp/mm_speed_result 2>/dev/null; exit 0"
                )) ?? ""
                let parts = out.components(separatedBy: "---")
                let ph = (parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let res = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                if !ph.isEmpty {
                    switch ph {
                    case "down": speedPhase = L("Скачивание…", "Downloading…")
                    case "up": speedPhase = L("Отдача…", "Uploading…")
                    case "ping": speedPhase = L("Пинг…", "Ping…")
                    default: speedPhase = ph
                    }
                }
                if !res.isEmpty {
                    if res == "err" {
                        speedError = L("Роутер не получил серверы замера", "The router did not get test servers")
                    } else {
                        let pr = res.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                        speedDown = pr.first.flatMap { Double($0) }.map { $0 * 8 / 1_000_000 }
                        speedUp = pr.dropFirst().first.flatMap { Double($0) }.map { $0 * 8 / 1_000_000 }
                        speedPing = pr.dropFirst(2).first.flatMap { Double($0) }.map { $0 * 1000 }
                    }
                    speedPhase = ""
                    return
                }
            }
            speedError = L("Не дождались результата замера (таймаут)", "Timed out waiting for the test result")
            speedPhase = ""
        } catch {
            speedError = error.localizedDescription
            speedPhase = ""
        }
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
            pingOut = L("PING 8.8.8.8: 56 data bytes\n64 bytes from 8.8.8.8: seq=0 ttl=57 time=41.2 ms (демо)", "PING 8.8.8.8: 56 data bytes\n64 bytes from 8.8.8.8: seq=0 ttl=57 time=41.2 ms (demo)")
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
                        Label(L("LuCI — веб-интерфейс роутера", "LuCI — the router web interface"), systemImage: "safari")
                    }
                    Link(destination: URL(string: "\(p.scheme)://\(p.host)\(p.port == 80 || p.port == 443 ? "" : ":\(p.port)")/cgi-bin/modem-telemetry")!) {
                        Label(L("Телеметрия модема", "Modem telemetry"), systemImage: "chart.line.uptrend.xyaxis")
                    }
                }
            } header: {
                Text(L("Открыть в Safari", "Open in Safari"))
            } footer: {
                Text(L("LuCI сначала покажет страницу входа: логин root, пароль роутера — после входа откроется интерфейс. Страницы открываются, когда iPhone в сети роутера.", "LuCI first shows a login page: login root, router password — the interface opens after login. Pages open while the iPhone is on the router's network."))
            }
        }
        .navigationTitle(L("LuCI и телеметрия", "LuCI & telemetry"))
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
        .navigationTitle(L("Настройка меню", "Menu setup"))
    }
}

// MARK: - Настройки (SettingsScreen)

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            Section {
                Picker("Язык / Language", selection: langBinding) {
                    Text("RU — Русский").tag("ru")
                    Text("EN — English").tag("en")
                }
            } header: {
                Text(L("Язык / Language", "Language / Язык"))
            }
            Section(L("Опрос", "Polling")) {
                Picker(L("Интервал опроса", "Polling interval"), selection: intervalBinding) {
                    Text(L("1 с", "1 s")).tag(1.0)
                    Text(L("2 с", "2 s")).tag(2.0)
                    Text(L("5 с", "5 s")).tag(5.0)
                    Text(L("10 с", "10 s")).tag(10.0)
                }
            }
            Section {
                Toggle(L("Безопасный режим", "Safe mode"), isOn: $app.settings.safeMode)
            } header: {
                Text(L("Безопасность", "Security"))
            } footer: {
                Text(L("Блокирует опасные shell-команды (reboot, sysupgrade, rm -rf / и т.п.), если они встречаются в редактируемых полях.", "Blocks dangerous shell commands (reboot, sysupgrade, rm -rf / etc.) found in editable fields."))
            }
            Section(L("О приложении", "About")) {
                LabeledContent(L("Версия", "Version"), value: "1.0 (iOS)")
                LabeledContent(L("Прототип", "Prototype"), value: "ModemMon 2.6 (Android)")
                LabeledContent(L("Подключение", "Connection"), value: "ubus JSON-RPC + medvemodem CGI")
            }
        }
        .navigationTitle(L("Настройки", "Settings"))
    }

    private var langBinding: Binding<String> {
        Binding(get: { app.settings.pollInterval }, set: { v in
            app.settings.pollInterval = v
            app.startPolling()
        })
    }
}
