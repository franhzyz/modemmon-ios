import Foundation
import Security

// MARK: - Профиль роутера

struct RouterProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = ""
    var scheme: String = "http"     // http | https
    var host: String = "192.168.2.1"
    var port: Int = 80
    var ubusPath: String = "/ubus"
    var modemPath: String = "/cgi-bin/modem"
    var user: String = "root"
    // nil: настройки профиля из предыдущих версий.
    var savePassword: Bool? = nil

    var baseURL: URL {
        var s = "\(scheme)://\(host)"
        if port != 80 && port != 443 { s += ":\(port)" }
        else if scheme == "https" && port != 443 { s += ":\(port)" }
        if !ubusPath.isEmpty && ubusPath != "/ubus" { s += ubusPath }
        return URL(string: s) ?? URL(string: "http://192.168.2.1")!
    }

    static let `default` = RouterProfile(name: "Роутер", host: "192.168.2.1", port: 80)
}

// MARK: - Настройки

struct MmSettings: Codable, Equatable {
    var pollInterval: Double = 2.0
    var safeMode: Bool = true
    var demo: Bool = false
    var hiddenMenu: Set<String> = []
    var wolIface: String = "br-lan"
    var keepPassword: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pollInterval = try c.decodeIfPresent(Double.self, forKey: .pollInterval) ?? 2.0
        safeMode = try c.decodeIfPresent(Bool.self, forKey: .safeMode) ?? true
        demo = try c.decodeIfPresent(Bool.self, forKey: .demo) ?? false
        hiddenMenu = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenMenu) ?? []
        wolIface = try c.decodeIfPresent(String.self, forKey: .wolIface) ?? "br-lan"
        keepPassword = try c.decodeIfPresent(Bool.self, forKey: .keepPassword) ?? true
    }
}

// MARK: - Keychain (пароли профилей)

enum Keychain {
    private static let service = "ru.franh.modemmon"

    @discardableResult
    static func setPassword(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func password(for account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let d = item as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func deletePassword(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Хранилище профилей/настроек

enum Store {
    private static let profilesKey = "mm.profiles"
    private static let activeKey = "mm.activeProfile"
    private static let settingsKey = "mm.settings"

    static func loadProfiles() -> [RouterProfile] {
        guard let d = UserDefaults.standard.data(forKey: profilesKey),
              let p = try? JSONDecoder().decode([RouterProfile].self, from: d), !p.isEmpty else {
            return [RouterProfile.default]
        }
        return p
    }

    static func saveProfiles(_ p: [RouterProfile]) {
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: profilesKey) }
    }

    static func loadActiveId() -> UUID? {
        guard let s = UserDefaults.standard.string(forKey: activeKey) else { return nil }
        return UUID(uuidString: s)
    }

    static func saveActiveId(_ id: UUID?) {
        UserDefaults.standard.set(id?.uuidString, forKey: activeKey)
    }

    static func loadSettings() -> MmSettings {
        guard let d = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(MmSettings.self, from: d) else { return MmSettings() }
        return s
    }

    static func saveSettings(_ s: MmSettings) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: settingsKey) }
    }
}
