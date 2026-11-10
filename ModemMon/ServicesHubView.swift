import SwiftUI

// MARK: - Службы: ключевые сервисы с кнопками + полный список init.d

struct ServicesHubView: View {
    @EnvironmentObject var app: AppState
    @State private var services: [ServiceStatus] = []
    @State private var filter = ""
    @State private var busyName: String?

    static let pinned = ["forkop", "forkop-state", "sing-box", "medvemodem", "dnsmasq", "firewall", "network", "dropbear", "ttyd"]

    var body: some View {
        List {
            if let forkop = services.first(where: { $0.name == "forkop" }) {
                Section("Прокси") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Форкоп (sing-box)").font(.subheadline.weight(.semibold))
                            badges(forkop)
                        }
                        Spacer()
                        NavigationLink { ForkopView() } label: {
                            Text("открыть").font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("Ключевые службы") {
                if services.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                ForEach(services.filter { Self.pinned.contains($0.name) }) { s in
                    ServiceRowView(s: s, busyName: busyName) { a in
                        Task { await action(s.name, a) }
                    }
                }
            }

            Section("Все службы (init.d)") {
                TextField("Фильтр", text: $filter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                ForEach(services.filter {
                    !Self.pinned.contains($0.name) &&
                    (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter))
                }) { s in
                    ServiceRowView(s: s, busyName: busyName) { a in
                        Task { await action(s.name, a) }
                    }
                }
            }
        }
        .navigationTitle("Службы")
        .refreshable { await load() }
        .onAppear { if services.isEmpty { Task { await load() } } }
    }

    @ViewBuilder
    private func badges(_ s: ServiceStatus) -> some View {
        HStack(spacing: 6) {
            MmBadge(text: s.enabled ? "enabled" : "disabled", tone: s.enabled ? .ok : .neutral)
            MmBadge(text: s.running ? "running" : "stopped", tone: s.running ? .ok : .warn)
        }
    }

    private func load() async {
        if app.conn == .demo {
            services = DemoSource.services()
            return
        }
        services = await app.run { svc in try await svc.services() } ?? []
    }

    private func action(_ name: String, _ a: RouterService.SvcAction) async {
        busyName = name
        defer { busyName = nil }
        await app.run { svc in try await svc.serviceAction(name, a) }
        await load()
    }
}

// MARK: - Строка службы с меню действий

struct ServiceRowView: View {
    let s: ServiceStatus
    let busyName: String?
    var onAction: (RouterService.SvcAction) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(.subheadline, design: .monospaced))
                HStack(spacing: 6) {
                    MmBadge(text: s.enabled ? "enabled" : "disabled", tone: s.enabled ? .ok : .neutral)
                    MmBadge(text: s.running ? "running" : "stopped", tone: s.running ? .ok : .warn)
                }
            }
            Spacer()
            if busyName == s.name {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button("start") { onAction(.start) }
                    Button("stop") { onAction(.stop) }
                    Button("restart") { onAction(.restart) }
                    Button(s.enabled ? "disable" : "enable") { onAction(s.enabled ? .disable : .enable) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}
