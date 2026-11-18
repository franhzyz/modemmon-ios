import Foundation

/// Язык интерфейса: «ru» — исходные строки, «en» — английский.
enum L10n {
    static var lang: String {
        get { UserDefaults.standard.string(forKey: "app_lang") ?? "ru" }
        set { UserDefaults.standard.set(newValue, forKey: "app_lang") }
    }
}

/// Перевод: возвращает английский вариант, если выбран EN, иначе исходную строку.
func L(_ ru: String, _ en: String) -> String {
    L10n.lang == "en" ? en : ru
}
