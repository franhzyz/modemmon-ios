import SwiftUI

/// Экран подключения: выбор профиля, host/порт/логин/пароль, демо.
struct ConnectView: View {
    @EnvironmentObject var app: AppState
    @State private var password: String = ""
    @State private var showEditor = false
    @State private var editTarget: RouterProfile?

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Подключение (ubus)", "Connection (ubus)")) {
                    Picker(L("Профиль", "Profile"), selection: profileBinding) {
                        ForEach(app.profiles) { p in
                            Text(p.name.isEmpty ? p.host : p.name).tag(Optional(p.id))
                        }
                    }
                    if let p = activeProfile {
                        LabeledContent(L("Адрес", "Address"), value: "\(p.scheme)://\(p.host):\(p.port)")
                        LabeledContent(L("Пользователь", "Username"), value: p.user)
                        SecureField(L("Пароль", "Password"), text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .onSubmit { Task { await connect() } }
                        Toggle(L("Сохранить пароль", "Save password"), isOn: Binding(
                            get: { app.wantsSavedPassword(p) },
                            set: { app.setSavePassword($0, for: p) }
                        ))
                        .font(.subheadline)
                    }
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if app.conn == .connecting {
                                ProgressView().padding(.trailing, 6)
                                Text(L("Подключение…", "Connecting…"))
                            } else {
                                Text(L("Подключиться", "Connect")).bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(app.conn == .connecting)
                }

                if let err = app.connError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section(L("Профили роутеров", "Router profiles")) {
                    ForEach(app.profiles) { p in
                        Button {
                            editTarget = p
                            showEditor = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name.isEmpty ? p.host : p.name)
                                        .foregroundStyle(.primary)
                                    Text("\(p.scheme)://\(p.host):\(p.port) · \(p.user)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if p.id == app.activeId {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                    .onDelete { idx in
                        for i in idx.sorted(by: >) {
                            guard i < app.profiles.count else { continue }
                            if app.profiles[i].id == app.activeId { continue } // активный не удаляем
                            app.clearStoredPasswords(for: app.profiles[i])
                            app.profiles.remove(at: i)
                        }
                    }
                    Button {
                        editTarget = nil
                        showEditor = true
                    } label: {
                        Label(L("Новый профиль", "New profile"), systemImage: "plus")
                    }
                }

                Section {
                    Button {
                        app.connectDemo()
                    } label: {
                        HStack {
                            Spacer()
                            Label(L("Открыть демо-режим", "Open demo mode"), systemImage: "play.circle")
                            Spacer()
                        }
                    }
                } footer: {
                    Text(L("Демо показывает все экраны на выдуманных данных — удобно посмотреть, как всё выглядит, пока роутера нет под рукой.", "Demo shows all screens with made-up data — handy to see how everything looks while the router is out of reach."))
                }
            }
            .navigationTitle("ModemMon")
            .sheet(isPresented: $showEditor) {
                ProfileEditorView(profile: editTarget ?? RouterProfile(), isNew: editTarget == nil)
            }
            .onAppear {
                if let p = activeProfile {
                    password = app.storedPassword(for: p)
                }
            }
            .onChange(of: app.activeId) { _ in
                password = activeProfile.map { app.storedPassword(for: $0) } ?? ""
            }
        }
    }

    private var activeProfile: RouterProfile? { app.active }

    private var profileBinding: Binding<UUID?> {
        Binding(get: { app.activeId ?? app.profiles.first?.id },
                set: { app.activeId = $0; if let p = app.active { password = app.storedPassword(for: p) } })
    }

    private func connect() async {
        guard let p = activeProfile else { return }
        await app.connect(p, password: password)
        if app.isConnected { password = "" }
    }
}

// MARK: - Редактор профиля

struct ProfileEditorView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State var profile: RouterProfile
    var isNew: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Профиль", "Profile")) {
                    TextField(L("Название", "Name"), text: $profile.name, prompt: Text(L("Дом / Дача / Медведь", "Home / Dacha / Bear")))
                    TextField(L("Хост или IP", "Host or IP"), text: $profile.host, prompt: Text("192.168.2.1"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("Порт", "Port"), value: $profile.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    Picker(L("Схема", "Scheme"), selection: $profile.scheme) {
                        Text("http").tag("http")
                        Text("https").tag("https")
                    }
                    TextField(L("Путь ubus", "ubus path"), text: $profile.ubusPath, prompt: Text("/ubus"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("Путь CGI модема", "Modem CGI path"), text: $profile.modemPath, prompt: Text("/cgi-bin/modem"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section(L("Учётная запись", "Account")) {
                    TextField(L("Пользователь", "Username"), text: $profile.user, prompt: Text("root"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(L("Пароль вводится на экране подключения и сохраняется только при включённом переключателе.", "The password is entered on the connect screen and saved only when the toggle is on."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isNew ? L("Новый профиль", "New profile") : L("Профиль", "Profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Отмена", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Сохранить", "Save")) {
                        profile.name = profile.name.isEmpty ? profile.host : profile.name
                        if let i = app.profiles.firstIndex(where: { $0.id == profile.id }) {
                            app.profiles[i] = profile
                        } else {
                            app.profiles.append(profile)
                            app.activeId = profile.id
                        }
                        dismiss()
                    }
                    .disabled(profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(1...65535).contains(profile.port))
                }
            }
        }
    }
}
