import Foundation

/// Разбирает только секцию Bands: поля supported/current встречаются и в других секциях mmcli.
enum BandsCodec {
    static func parse(_ text: String) -> (supported: [String], current: [String]) {
        var supported: [String] = [], current: [String] = []
        var inBands = false
        var target: String?

        for line in text.components(separatedBy: .newlines) {
            guard let pipe = line.firstIndex(of: "|") else {
                if inBands && line.contains("---") { break }
                continue
            }
            let section = line[..<pipe].trimmingCharacters(in: .whitespaces)
            if !section.isEmpty {
                if inBands { break }
                guard section.lowercased() == "bands" else { continue }
                inBands = true
            }
            guard inBands else { continue }
            var value = String(line[line.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
            if let colon = value.firstIndex(of: ":") {
                let key = value[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard key == "supported" || key == "current" else { target = nil; continue }
                target = key
                value = String(value[value.index(after: colon)...])
            }
            guard let target else { continue }
            let names = value.split(whereSeparator: { $0 == "," || $0 == "|" || $0.isWhitespace })
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
                .filter { isSafeName($0) && $0 != "--" && $0.lowercased() != "unknown" }
            if target == "supported" { supported.append(contentsOf: names) }
            else { current.append(contentsOf: names) }
        }
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        return (unique(supported), unique(current))
    }

    static func mmName(_ band: String) -> String {
        let s = band.lowercased().replacingOccurrences(of: " ", with: "")
        if s.hasPrefix("b"), let n = Int(s.dropFirst()) { return "eutran-\(n)" }
        if s.hasPrefix("n"), let n = Int(s.dropFirst()) { return "ngran-\(n)" }
        if s.hasPrefix("w"), let n = Int(s.dropFirst()) { return "utran-\(n)" }
        return s
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
        }
    }
}
