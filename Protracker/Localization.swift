import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", german = "de"
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return L("System default"); case .english: return "English"; case .german: return "Deutsch" }
    }
    var locale: Locale { Locale(identifier: L10n.code(for:self)) }
}

/// Keeps interpolation values separate from translation keys, including saved status messages.
/// Song names, device names, and OS error descriptions can be explicitly kept verbatim.
struct AppText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Equatable, Sendable {
    let key: String
    let arguments: [String]
    let isVerbatim: Bool
    init(stringLiteral value: String) { key = value; arguments = []; isVerbatim = false }
    init(key: String) { self.key = key; arguments = []; isVerbatim = false }
    private init(verbatim value: String) { key = value; arguments = []; isVerbatim = true }
    static func verbatim(_ value: String) -> Self { Self(verbatim:value) }
    init(stringInterpolation: StringInterpolation) { key = stringInterpolation.key; arguments = stringInterpolation.arguments; isVerbatim = false }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount) }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) { key += "{\(arguments.count)}"; arguments.append(String(describing:value)) }
    }
    var resolved: String { L10n.resolve(self) }
}

/// Native .strings resources, with a thread-safe override for AppKit and background errors.
enum L10n {
    static let preferenceKey = "tracker.language"
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var language = AppLanguage(rawValue:UserDefaults.standard.string(forKey:L10n.preferenceKey) ?? "system") ?? .system
        var bundles: [String:Bundle] = [:]
    }
    private static let state = State()
    static var language: AppLanguage {
        state.lock.lock(); defer { state.lock.unlock() }; return state.language
    }
    static func setLanguage(_ language: AppLanguage, persist: Bool = true) {
        state.lock.lock(); state.language = language; state.lock.unlock()
        if persist {
            UserDefaults.standard.set(language.rawValue,forKey:preferenceKey)
            // AppKit's own file-panel controls adopt the same language at the next launch.
            if language == .system { UserDefaults.standard.removeObject(forKey:"AppleLanguages") }
            else { UserDefaults.standard.set([language.rawValue],forKey:"AppleLanguages") }
        }
    }
    static func code(for language: AppLanguage, preferredLanguages: [String]? = nil) -> String {
        guard language == .system else { return language.rawValue }
        // Read the system list, independently of our per-app AppleLanguages override.
        let system = UserDefaults.standard.persistentDomain(forName:UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        let preferred = preferredLanguages ?? system ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from:["en","de"],forPreferences:preferred).first ?? "en"
    }
    static func resolve(_ message: AppText, language: AppLanguage? = nil, resources: URL? = nil) -> String {
        if message.isVerbatim { return message.key }
        let code = code(for:language ?? self.language)
        let root = resources ?? Bundle.main.resourceURL
        let path = root?.appendingPathComponent(code+".lproj").path ?? ""
        state.lock.lock()
        let bundle = state.bundles[path] ?? Bundle(path:path)
        if let bundle { state.bundles[path] = bundle }
        state.lock.unlock()
        let template = bundle?.localizedString(forKey:message.key,value:message.key,table:"Localizable") ?? message.key
        guard !message.arguments.isEmpty else { return template }
        // Replace only placeholders in the template; braces in user content stay untouched.
        let expression = try! NSRegularExpression(pattern:"\\{([0-9]+)\\}")
        let source = template as NSString
        var output = "", cursor = 0
        for match in expression.matches(in:template,range:NSRange(location:0,length:source.length)) {
            output += source.substring(with:NSRange(location:cursor,length:match.range.location-cursor))
            let index = Int(source.substring(with:match.range(at:1)))!
            output += message.arguments.indices.contains(index) ? message.arguments[index] : source.substring(with:match.range)
            cursor = match.range.location+match.range.length
        }
        return output+source.substring(from:cursor)
    }
}

func L(_ message: AppText) -> String { message.resolved }
func LK(_ key: String) -> String { AppText(key:key).resolved }
