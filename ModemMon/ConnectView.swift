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
                Section("Подключение (ubus)") {
                    Picker("Профиль", selection: profileBinding) {
                        ForEach(app.profiles) { p in
                            Text(p.name.isEmpty ? p.host : p.name).tag(Optional(p.id))
                        }
                    }
                    if let p = activeProfile {
                        LabeledContent("Адрес", value: "\(p.scheme)://\(p.host):\(p.port)")
                        LabeledContent("Пользователь", value: p.user)
                        SecureField("Пароль", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .onSubmit { Task { await connect() } }
                    }
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if app.conn == .connecting {
                                ProgressView().padding(.trailing, 6)
                                Text("Подключение…")
                            } else {
                                Text("Подключиться").bold()
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

                Section("Профили роутеров") {
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
                            Keychain.deletePassword(for: app.profiles[i].id.uuidString)
                            app.profiles.remove(at: i)
                        }
                    }
                    Button {
                        editTarget = nil
                        showEditor = true
                    } label: {
                        Label("Новый профиль", systemImage: "plus")
                    }
                }

                Section {
                    Button {
                        app.connectDemo()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Открыть демо-режим", systemImage: "play.circle")
                            Spacer()
                        }
                    }
                } footer: {
                    Text("Демо показывает все экраны на выдуманных данных — удобно посмотреть, как всё выглядит, пока роутера нет под рукой.")
                }
            }
            .navigationTitle("ModemMon")
            .sheet(isPresented: $showEditor) {
                ProfileEditorView(profile: editTarget ?? RouterProfile.default, isNew: editTarget == nil)
            }
            .onAppear {
                if let p = activeProfile {
                    password = app.password(for: p)
                }
            }
        }
    }

    private var activeProfile: RouterProfile? { app.active }

    private var profileBinding: Binding<UUID?> {
        Binding(get: { app.activeId ?? app.profiles.first?.id },
                set: { app.activeId = $0; if let p = app.active { password = app.password(for: p) } })
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
                Section("Профиль") {
                    TextField("Название", text: $profile.name, prompt: Text("Дом / Дача / Медведь"))
                    TextField("Хост или IP", text: $profile.host, prompt: Text("192.168.2.1"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Порт", value: $profile.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    Picker("Схема", selection: $profile.scheme) {
                        Text("http").tag("http")
                        Text("https").tag("https")
                    }
                    TextField("Путь ubus", text: $profile.ubusPath, prompt: Text("/ubus"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Путь CGI модема", text: $profile.modemPath, prompt: Text("/cgi-bin/modem"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Учётная запись") {
                    TextField("Пользователь", text: $profile.user, prompt: Text("root"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Пароль", text: Binding(
                        get: { app.password(for: profile) },
                        set: { app.savePassword($0, for: profile) }))
                        .textContentType(.password)
                }
            }
            .navigationTitle(isNew ? "Новый профиль" : "Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        profile.name = profile.name.isEmpty ? profile.host : profile.name
                        if let i = app.profiles.firstIndex(where: { $0.id == profile.id }) {
                            app.profiles[i] = profile
                        } else {
                            app.profiles.append(profile)
                            app.activeId = profile.id
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}
