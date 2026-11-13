import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if app.isConnected {
                MainView()
            } else {
                ConnectView()
            }
        }
        .overlay(alignment: .top) {
            if let b = app.banner {
                BannerView(text: b) { app.clearBanner() }
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
        }
    }
}

/// Плавающий баннер ошибки (как snackbar в Android-версии).
struct BannerView: View {
    var text: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 6, y: 2)
        .task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            dismiss()
        }
        .onTapGesture { }
    }
}

// MARK: - Главное меню

struct MainView: View {
    @EnvironmentObject var app: AppState
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                headerSection
                ForEach(app.visibleSections) { s in
                    NavigationLink(value: s.key) {
                        Label {
                            Text(s.title)
                        } icon: {
                            Image(systemName: s.icon)
                                .frame(width: 26)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("ModemMon")
            .navigationDestination(for: String.self) { key in
                sectionView(key)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        NavigationLink(value: "menuconfig") { Label("Настройка меню", systemImage: "slider.horizontal.3") }
                        NavigationLink(value: "settings") { Label("Настройки", systemImage: "gearshape") }
                        Menu("Сменить роутер") {
                            ForEach(app.profiles) { profile in
                                Button(profile.name.isEmpty ? profile.host : profile.name) {
                                    app.disconnect()
                                    app.activeId = profile.id
                                }
                            }
                        }
                        Button(role: .destructive) {
                            app.disconnect()
                        } label: {
                            Label("Отключиться", systemImage: "stop.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    /// Через что реально ходит интернет: модем или провод
    /// Классификация строго по фактическому интерфейсу аплинка:
    /// wwan/usb/qmi/modem — сотовый, всё остальное (eth/wan/br/pppoe/…) — провод.
    /// Пока маршрут неизвестен — нейтральное «Подключено».
    private var viaModem: Bool {
        let p = app.uplink.path.lowercased()
        return p.hasPrefix("wwan") || p.hasPrefix("usb") || p.contains("qmi") || p.contains("modem")
    }

    private var headerTitle: String {
        if app.conn == .demo { return "Демо-режим" }
        if app.uplink.path.isEmpty { return "Подключено" }
        if viaModem {
            return app.modem?.operatorName.isEmpty == false ? app.modem!.operatorName : "Подключено (модем)"
        }
        return "Подключено (кабель)"
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if app.uplink.path.isEmpty {
                        Image(systemName: "network")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 40)
                    } else if viaModem {
                        SignalBars(rsrp: app.modem?.bestRsrp, size: 22)
                    } else {
                        Image(systemName: "cable.connector")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 40)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headerTitle)
                            .font(.headline)
                        Text(statusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        uplinkBadge
                        if viaModem, let r = app.modem?.bestRsrp {
                            Text(Fmt.dbm(r)).font(.caption).monospacedDigit().foregroundStyle(rsrpColor(r))
                        }
                    }
                }
                if let rx = app.ifaceRates.values.max() {
                    HStack {
                        Image(systemName: "arrow.down.arrow.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Fmt.kbps(rx))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if app.modem?.tempModem != nil || app.sys?.cpuTemp != nil {
                    let m = app.modem?.tempModem.map { String(format: "%.0f", $0) }
                    let r = app.sys?.cpuTemp.map { String(format: "%.0f", $0) }
                    HStack(spacing: 4) {
                        Image(systemName: "thermometer.medium")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Модем \(m ?? "—")° · Роутер \(r ?? "—")°")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var statusLine: String {
        var parts: [String] = []
        if !app.uplink.path.isEmpty {
            parts.append(viaModem ? "модем (\(app.uplink.path))" : "кабель (\(app.uplink.path))")
        }
        if viaModem, let m = app.modem {
            if !m.rat.isEmpty { parts.append(m.rat) }
            if !m.band.isEmpty { parts.append(m.band) }
        }
        if let s = app.sys {
            parts.append("↑ \(Fmt.uptime(s.uptime))")
        }
        parts.append(app.activeProfile?.host ?? "")
        return parts.joined(separator: " · ")
    }

    private var uplinkBadge: some View {
        switch app.uplink.st {
        case .ok: return AnyView(MmBadge(text: "интернет", tone: .ok))
        case .fail: return AnyView(MmBadge(text: "нет интернета", tone: .bad))
        case .checking: return AnyView(MmBadge(text: "проверка…", tone: .info))
        case .unknown: return AnyView(MmBadge(text: "аплинк?", tone: .neutral))
        }
    }

    @ViewBuilder
    private func sectionView(_ key: String) -> some View {
        switch key {
        case "overview": OverviewView()
        case "cells": CellsView()
        case "bands": BandsView()
        case "sms": SmsUssdAtView()
        case "network": NetworkView()
        case "wifi": WifiView()
        case "vpn": VpnView()
        case "forkop": ForkopView()
        case "routes": RoutesView()
        case "system": SystemView()
        case "services": ServicesHubView()
        case "config": ConfigView()
        case "terminal": TerminalView()
        case "files": FilesView()
        case "wol": WolView()
        case "diag": DiagnosticsView()
        case "links": LinksView()
        case "menuconfig": MenuConfigView()
        case "settings": SettingsView()
        default: Text("?")
        }
    }
}
