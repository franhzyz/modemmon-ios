import Foundation

/// Сессия терминала поверх /usr/bin/mmterm (start/poll/stop, как в Android-версии).
@MainActor
final class TerminalSession: ObservableObject {
    @Published var lines: [TermLine] = []
    @Published var busy = false
    @Published var cwd: String = "/"
    @Published var installed: Bool?

    private var pollTask: Task<Void, Never>?
    private weak var app: AppState?

    init(app: AppState? = nil) { self.app = app }

    func bind(_ a: AppState) { app = a }

    func checkInstalled() async {
        guard let app, var svc = app.service else { return }
        if app.conn == .demo {
            installed = true
            return
        }
        let ok = await Install.mmtermInstalled(svc.ubus)
        installed = ok
    }

    func install() async {
        guard let app, var svc = app.service, app.conn != .demo else { return }
        do {
            try await Install.installMmterm(svc.ubus)
            installed = true
            lines.append(TermLine(text: "mmterm установлен на роутер", isCmd: false))
        } catch {
            installed = false
            app.banner = "mmterm: \(error.localizedDescription)"
        }
    }

    /// Выполнить команду: ставит её в очередь на роутере и поллит вывод.
    func run(_ command: String) async {
        guard let app, var svc = app.service else { return }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard busy == false else { return }

        if app.conn == .demo {
            lines.append(TermLine(text: "$ " + command, isCmd: true))
            lines.append(TermLine(text: "(демо-режим: команда не выполняется)", isCmd: false))
            return
        }

        busy = true
        lines.append(TermLine(text: "$ " + command, isCmd: true))

        do {
            let b64 = Data(command.utf8).base64EncodedString()
            _ = try await svc.ubus.fileExec("/usr/bin/mmterm start \(b64)")
        } catch {
            busy = false
            app.banner = "mmterm start: \(error.localizedDescription)"
            return
        }

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    private func pollLoop() async {
        guard let app else { return }
        var attempt = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            attempt += 1
            if attempt > 600 { break } // ~5 минут максимум
            guard var svc = app.service else { break }
            guard let out = try? await svc.ubus.fileExec("/usr/bin/mmterm poll") else { continue }
            await consume(out.stdout)
            if out.stdout.contains("__MMTERM done") {
                busy = false
                return
            }
        }
        busy = false
    }

    private func consume(_ text: String) async {
        var cwdFound = ""
        var body: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("__MMTERM done") || line.hasPrefix("__MMTERM running") {
                for tok in line.split(separator: " ") where tok.hasPrefix("cwd=") {
                    cwdFound = String(tok.dropFirst(4))
                }
            } else {
                body.append(line)
            }
        }
        let clean = body.joined(separator: "\n")
        if !clean.isEmpty {
            lines.append(TermLine(text: clean, isCmd: false))
            if lines.count > 800 { lines.removeFirst(lines.count - 800) }
        }
        if !cwdFound.isEmpty {
            cwd = cwdFound
        }
    }

    func stopCurrent() async {
        pollTask?.cancel()
        pollTask = nil
        busy = false
        guard let app, var svc = app.service, app.conn != .demo else { return }
        _ = try? await svc.ubus.fileExec("/usr/bin/mmterm stop")
        lines.append(TermLine(text: "— прервано —", isCmd: false))
    }

    func clear() { lines = [] }
}
