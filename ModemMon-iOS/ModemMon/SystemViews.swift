import SwiftUI

// MARK: - Система (OverviewScreen / CpuScreen / Packages / Services / Processes / Crontab / Backup / Exec)

enum SysRoute: Hashable {
    case cpu, packages, services, processes, crontab, backup, exec, log, leds, reboot
}

struct SystemView: View {
    @EnvironmentObject var app: AppState
    @State private var sys: SysOverview?

    var body: some View {
        List {
            if let s = sys {
                Section("Обзор") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        StatTile(title: "Load 1/5/15", value: String(format: "%.2f", s.load1), sub: String(format: "%.2f / %.2f", s.load5, s.load15))
                        StatTile(title: "Память занято", value: Fmt.bytes((s.memTotalKb - s.memFreeKb) * 1024), sub: "из \(Fmt.bytes(s.memTotalKb * 1024))")
                        StatTile(title: "Uptime", value: Fmt.uptime(s.uptime))
                        StatTile(title: "CPU temp", value: Fmt.temp(s.cpuTemp))
                    }
                    KVRow(key: "Хост", value: s.hostname)
                    KVRow(key: "Модель", value: s.model)
                    KVRow(key: "Прошивка", value: s.firmware)
                    KVRow(key: "Ядро", value: s.kernel)
                }
            } else {
                Section { ProgressView("Читаем систему…").frame(maxWidth: .infinity) }
            }

            Section("Инструменты") {
                NavigationLink(value: SysRoute.cpu) { Label("Процессор и частоты", systemImage: "cpu") }
                NavigationLink(value: SysRoute.packages) { Label("Пакеты (apk/opkg)", systemImage: "shippingbox") }
                NavigationLink(value: SysRoute.services) { Label("Сервисы (init.d)", systemImage: "list.bullet.rectangle") }
                NavigationLink(value: SysRoute.processes) { Label("Процессы", systemImage: "person.3.sequence") }
                NavigationLink(value: SysRoute.crontab) { Label("Crontab", systemImage: "clock") }
                NavigationLink(value: SysRoute.backup) { Label("Бэкапы (sysupgrade)", systemImage: "externaldrive.badge.timemachine") }
                NavigationLink(value: SysRoute.exec) { Label("Быстрые команды", systemImage: "bolt.horizontal") }
                NavigationLink(value: SysRoute.log) { Label("Лог (logread)", systemImage: "doc.plaintext") }
                NavigationLink(value: SysRoute.leds) { Label("LED", systemImage: "lightbulb") }
                NavigationLink(value: SysRoute.reboot) { Label("Перезагрузка роутера", systemImage: "arrow.counterclockwise.circle") }
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Система")
        .navigationDestination(for: SysRoute.self) { r in
            switch r {
            case .cpu: CpuView()
            case .packages: PackagesView()
            case .services: ServicesView()
            case .processes: ProcessesView()
            case .crontab: CrontabView()
            case .backup: BackupView()
            case .exec: ExecView()
            case .log: LogView()
            case .leds: LedsView()
            case .reboot: RebootView()
            }
        }
        .onAppear { if sys == nil { sys = app.sys } }
        .refreshable {
            if let s = await app.run({ svc in try await svc.quickSys() }) { sys = s }
        }
    }
}

struct CpuView: View {
    @EnvironmentObject var app: AppState
    @State private var cores: [CpuCore] = []

    var body: some View {
        List {
            Section("Ядра") {
                if cores.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                ForEach(cores) { c in
                    HStack {
                        Text("cpu\(c.id)").font(.system(.subheadline, design: .monospaced))
                        Spacer()
                        if let f = c.freqMhz { Text("\(f) МГц").monospacedDigit().foregroundStyle(.secondary) }
                        if let l = c.load {
                            Text(String(format: "%.0f%%", l)).monospacedDigit()
                        }
                    }
                }
            }
            Section {
                ProgressRow(label: "Загрузка 1 мин", value: min(1, (app.sys?.load1 ?? 0) / Double(max(1, cores.count))), caption: String(format: "%.2f", app.sys?.load1 ?? 0))
            }
        }
        .navigationTitle("CPU")
        .onAppear {
            if app.conn == .demo { cores = DemoSource.sys().cores; return }
            Task {
                if let s = await app.run({ svc in try await svc.sysOverview() }) {
                    cores = s.cores
                }
            }
        }
    }
}

struct PackagesView: View {
    @EnvironmentObject var app: AppState
    @State private var pkgs: [Package] = []
    @State private var filter = ""
    @State private var busy = false
    @State private var showAdd = false
    @State private var newPkg = ""

    var body: some View {
        List {
            Section {
                TextField("Фильтр", text: $filter)
                Button {
                    showAdd = true
                } label: { Label("Установить пакет", systemImage: "plus") }
            }
            Section("Установлено: \(pkgs.count)") {
                if pkgs.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                ForEach(pkgs.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(.subheadline, design: .monospaced))
                            if !p.version.isEmpty { Text(p.version).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Menu {
                            Button("Обновить") { Task { await action(p.name, .upgrade) } }
                            Button("Удалить", role: .destructive) { Task { await action(p.name, .remove) } }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .navigationTitle("Пакеты")
        .refreshable { await load() }
        .onAppear { if pkgs.isEmpty { Task { await load() } } }
        .alert("Имя пакета", isPresented: $showAdd) {
            TextField("например etherwake", text: $newPkg)
                .textInputAutocapitalization(.never)
            Button("Установить") { Task { await action(newPkg, .install); newPkg = "" } }
            Button("Отмена", role: .cancel) { }
        }
    }

    private func load() async {
        if app.conn == .demo { pkgs = DemoSource.packages(); return }
        pkgs = await app.run { svc in try await svc.packages() } ?? []
    }

    private func action(_ name: String, _ a: RouterService.PkgAction) async {
        busy = true
        defer { busy = false }
        await app.run { svc in try await svc.packageAction(name, a) }
        await load()
    }
}

struct ServicesView: View {
    @EnvironmentObject var app: AppState
    @State private var services: [ServiceStatus] = []
    @State private var busyName: String?

    var body: some View {
        List {
            Section("init.d (\(services.count))") {
                if services.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                ForEach(services) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.system(.subheadline, design: .monospaced))
                            HStack(spacing: 6) {
                                MmBadge(text: s.enabled ? "enabled" : "disabled", tone: s.enabled ? .ok : .neutral)
                                MmBadge(text: s.running ? "running" : "stopped", tone: s.running ? .ok : .warn)
                            }
                        }
                        Spacer()
                        Menu {
                            Button("start") { Task { await action(s.name, .start) } }
                            Button("stop") { Task { await action(s.name, .stop) } }
                            Button("restart") { Task { await action(s.name, .restart) } }
                            Button(s.enabled ? "disable" : "enable") { Task { await action(s.name, s.enabled ? .disable : .enable) } }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .navigationTitle("Сервисы")
        .refreshable { await load() }
        .onAppear { if services.isEmpty { Task { await load() } } }
    }

    private func load() async {
        if app.conn == .demo { services = DemoSource.services(); return }
        services = await app.run { svc in try await svc.services() } ?? []
    }

    private func action(_ name: String, _ a: RouterService.SvcAction) async {
        busyName = name
        defer { busyName = nil }
        await app.run { svc in try await svc.serviceAction(name, a) }
        await load()
    }
}

struct ProcessesView: View {
    @EnvironmentObject var app: AppState
    @State private var procs: [ProcInfo] = []
    @State private var filter = ""

    var body: some View {
        List {
            Section {
                TextField("Фильтр", text: $filter)
            }
            Section("Процессы") {
                if procs.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                ForEach(procs.filter { filter.isEmpty || $0.command.localizedCaseInsensitiveContains(filter) }) { p in
                    HStack {
                        Text("\(p.id)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
                        Text(p.command).font(.system(.caption, design: .monospaced)).lineLimit(2)
                        Spacer()
                        Menu {
                            Button("kill", role: .destructive) {
                                Task { await app.run { svc in try await svc.killProc(pid: p.id) }; await load() }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
        }
        .navigationTitle("Процессы")
        .refreshable { await load() }
        .onAppear { if procs.isEmpty { Task { await load() } } }
    }

    private func load() async {
        if app.conn == .demo { procs = DemoSource.processes(); return }
        procs = await app.run { svc in try await svc.processes() } ?? []
    }
}

struct CrontabView: View {
    @EnvironmentObject var app: AppState
    @State private var text = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .padding(8)
            Divider()
            Button {
                Task { await save() }
            } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView().padding(.trailing, 8) }
                    Text("Сохранить crontab").bold()
                    Spacer()
                }
            }
            .padding(10)
        }
        .navigationTitle("Crontab (/etc/crontabs/root)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if text.isEmpty { Task { await load() } } }
    }

    private func load() async {
        if app.conn == .demo { text = DemoSource.crontab(); return }
        text = await app.run { svc in try await svc.crontabText() } ?? ""
    }

    private func save() async {
        busy = true
        defer { busy = false }
        await app.run { svc in try await svc.saveCrontab(text) }
    }
}

struct BackupView: View {
    @EnvironmentObject var app: AppState
    @State private var backups: [BackupFile] = []
    @State private var busy = false

    var body: some View {
        List {
            Section {
                Button {
                    Task { await create() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 8) }
                        Label("Создать бэкап (sysupgrade -b)", systemImage: "plus.rectangle.on.folder")
                        Spacer()
                    }
                }
                .disabled(busy)
            }
            Section("Бэкапы в /tmp") {
                if backups.isEmpty { Text("Пока нет").foregroundStyle(.secondary) }
                ForEach(backups) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((b.path as NSString).lastPathComponent).font(.caption.monospaced()).lineLimit(1)
                            Text("\(Fmt.bytes(b.size)) · \(Fmt.time(b.mtime))").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task {
                                await app.run { svc in try await svc.deleteBackup(b.path) }
                                await load()
                            }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            } footer: {
                Text("Бэкап лежит в /tmp — после перезагрузки роутера исчезает. Скачайте важное через «Файлы».")
            }
        }
        .navigationTitle("Бэкапы")
        .refreshable { await load() }
        .onAppear { if backups.isEmpty { Task { await load() } } }
    }

    private func load() async {
        if app.conn == .demo { backups = DemoSource.backups(); return }
        backups = await app.run { svc in try await svc.backups() } ?? []
    }

    private func create() async {
        busy = true
        defer { busy = false }
        await app.run { svc in try await svc.createBackup() }
        await load()
    }
}

struct ExecView: View {
    @EnvironmentObject var app: AppState
    @State private var cmd = ""
    @State private var output = ""

    static let presets = [
        "df -h", "free", "cat /proc/loadavg", "uname -a",
        "ubus call system board", "uci show medvemodem", "apk info medvemodem",
        "ls /tmp", "logread | tail -n 20",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(output.isEmpty ? "Вывод появится здесь" : output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Self.presets, id: \.self) { p in
                        Button(p) { cmd = p }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.vertical, 6)
            Divider()
            HStack(spacing: 8) {
                TextField("команда", text: $cmd)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await run() } }
                Button {
                    Task { await run() }
                } label: { Image(systemName: "play.circle.fill").font(.title2) }
                .disabled(cmd.isEmpty)
            }
            .padding(10)
        }
        .navigationTitle("Быстрые команды")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() async {
        guard let svc = app.service else { return }
        let c = cmd
        output += "\n$ \(c)\n"
        if app.conn == .demo {
            output += "(демо-режим)\n"
            return
        }
        do {
            let r = try await svc.exec(c)
            output += r.stdout
            if !r.stderr.isEmpty { output += r.stderr }
        } catch {
            output += "ошибка: \(error.localizedDescription)\n"
        }
        if output.count > 20_000 { output = String(output.suffix(20_000)) }
    }
}

struct LogView: View {
    @EnvironmentObject var app: AppState
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "…" : text)
                .font(.system(.caption2, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .textSelection(.enabled)
        }
        .navigationTitle("logread")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .onAppear { if text.isEmpty { Task { await load() } } }
    }

    private func load() async {
        if app.conn == .demo { text = DemoSource.log(); return }
        text = await app.run { svc in try await svc.logRead(lines: 150) } ?? ""
    }
}

struct LedsView: View {
    @EnvironmentObject var app: AppState
    @State private var leds: [LedInfo] = []

    var body: some View {
        List {
            Section("LED (/sys/class/leds)") {
                if leds.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                ForEach(leds) { l in
                    KVRow(key: l.name, value: "brightness \(l.brightness ?? -1)/\(l.maxBrightness ?? -1) · trigger \(l.trigger)")
                }
            }
        }
        .navigationTitle("LED")
        .refreshable { await load() }
        .onAppear { if leds.isEmpty { Task { await load() } } }
    }

    private func load() async {
        if app.conn == .demo { leds = DemoSource.leds(); return }
        leds = await app.run { svc in try await svc.leds() } ?? []
    }
}

struct RebootView: View {
    @EnvironmentObject var app: AppState
    @State private var confirm = false
    @State private var done = false

    var body: some View {
        Form {
            Section {
                Label("Роутер уйдёт в перезагрузку и будет недоступен ~1-2 минуты.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button(role: .destructive) {
                    confirm = true
                } label: {
                    HStack { Spacer(); Text("Перезагрузить роутер").bold(); Spacer() }
                }
            }
            if done {
                Section { Text("Команда отправлена. Ждём…").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Reboot")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Точно перезагрузить?", isPresented: $confirm) {
            Button("Перезагрузить", role: .destructive) {
                Task {
                    await app.run { svc in try await svc.rebootRouter() }
                    done = true
                }
            }
            Button("Отмена", role: .cancel) { }
        }
    }
}

// MARK: - UCI-конфиг (ConfigScreen)

struct UciRoute: Hashable { let name: String }

struct ConfigView: View {
    @EnvironmentObject var app: AppState
    @State private var configs: [String] = []
    @State private var selected: String?

    var body: some View {
        List {
            Section("Файлы в /etc/config") {
                if configs.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                ForEach(configs, id: \.self) { c in
                    NavigationLink(value: UciRoute(name: c)) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Color.accentColor)
                        Text(c).font(.system(.subheadline, design: .monospaced))
                    }
                }
            }
        }
        .navigationTitle("Конфиг UCI")
        .navigationDestination(for: UciRoute.self) { r in
            UciConfigView(name: r.name)
        }
        .onAppear { if configs.isEmpty { Task { await load() } } }
    }

    private func load() async {
        if app.conn == .demo {
            configs = ["network", "wireless", "firewall", "dhcp", "system", "medvemodem"]
            return
        }
        configs = await app.run { svc in try await svc.uciConfigs() } ?? []
    }
}

struct UciConfigView: View {
    @EnvironmentObject var app: AppState
    let name: String
    @State private var cfg: UciConfig?

    var body: some View {
        List {
            if let c = cfg {
                ForEach(c.sections) { s in
                    Section("\(s.anon ? s.name : "@\(s.type)[\(s.name)]") \(s.type)") {
                        ForEach(s.options) { o in
                            UciOptionEditor(config: name, section: s.name, option: o) { Task { await load() } }
                        }
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .onAppear { if cfg == nil { Task { await load() } } }
    }

    private func load() async {
        if app.conn == .demo { cfg = DemoSource.uciNetwork(); return }
        cfg = await app.run { svc in try await svc.uciShow(name) }
    }
}

/// Редактор одной UCI-опции: тап — правка значения.
struct UciOptionEditor: View {
    @EnvironmentObject var app: AppState
    let config: String
    let section: String
    let option: UciOption
    var saved: () -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var busy = false

    var body: some View {
        HStack {
            Text(option.name).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(option.value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            Image(systemName: "pencil.circle")
                .foregroundStyle(Color.accentColor.opacity(0.6))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            draft = option.value
            editing = true
        }
        .disabled(busy)
        .alert("Изменить \(option.name)", isPresented: $editing) {
            TextField("значение", text: $draft)
                .textInputAutocapitalization(.never)
            Button("Сохранить") { Task { await save() } }
            Button("Отмена", role: .cancel) { }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let v = draft
        await app.run { svc in try await svc.uciSet(config, section, option.name, v) }
        saved()
    }
}
