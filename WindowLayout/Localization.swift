import Foundation

enum L {

    enum Lang: String, CaseIterable {
        case system, ru, en, zh

        var displayName: String {
            switch self {
            case .system: return L.s("По системе", "System", "跟随系统")
            case .ru:     return "Русский"
            case .en:     return "English"
            case .zh:     return "中文"
            }
        }
    }

    private static let prefKey = "userLanguage"
    // Mutated only from main thread (menu actions, language switcher).
    nonisolated(unsafe) private static var cachedLang: String?

    static var userPreference: Lang {
        get {
            let raw = UserDefaults.standard.string(forKey: prefKey) ?? "system"
            return Lang(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: prefKey)
            cachedLang = nil
        }
    }

    private static var systemLang: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    private static var currentLang: String {
        if let c = cachedLang { return c }
        let pref = userPreference
        let lang: String
        switch pref {
        case .system: lang = systemLang
        case .ru:     lang = "ru"
        case .en:     lang = "en"
        case .zh:     lang = "zh"
        }
        cachedLang = lang
        return lang
    }

    static var isRU: Bool { currentLang == "ru" }
    static var isZH: Bool { currentLang == "zh" || currentLang.hasPrefix("zh") }

    /// Three-way string with optional Chinese. Falls back to English if Chinese missing.
    static func s(_ ru: String, _ en: String, _ zh: String? = nil) -> String {
        if isZH, let zh = zh { return zh }
        if isRU { return ru }
        return en
    }

    static func timeAgo(_ seconds: Int) -> String {
        if isZH {
            if seconds < 60    { return "刚刚" }
            if seconds < 3600  { return "\(seconds / 60) 分钟前" }
            if seconds < 86400 { return "\(seconds / 3600) 小时前" }
            return "\(seconds / 86400) 天前"
        }
        if isRU {
            if seconds < 60    { return "только что" }
            if seconds < 3600  { return "\(seconds / 60) мин назад" }
            if seconds < 86400 { return "\(seconds / 3600) ч назад" }
            return "\(seconds / 86400) дн назад"
        }
        if seconds < 60    { return "just now" }
        if seconds < 3600  { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    static func layoutsCount(_ n: Int) -> String {
        if isZH { return "\(n) 个布局" }
        if isRU {
            let mod10 = n % 10, mod100 = n % 100
            let word: String
            if mod10 == 1 && mod100 != 11 { word = "расположение" }
            else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "расположения" }
            else { word = "расположений" }
            return "\(n) \(word)"
        }
        return n == 1 ? "1 layout" : "\(n) layouts"
    }

    static func displaysCount(_ n: Int) -> String {
        if isZH { return "\(n) 个显示器" }
        if isRU {
            let mod10 = n % 10, mod100 = n % 100
            let word: String
            if mod10 == 1 && mod100 != 11 { word = "дисплей" }
            else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "дисплея" }
            else { word = "дисплеев" }
            return "\(n) \(word)"
        }
        return n == 1 ? "1 display" : "\(n) displays"
    }
}
